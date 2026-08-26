# Unix domain socket tests: echo roundtrip and EOF, timeouts, bind and
# connect failure paths, path-length limits, lifecycle, and the Linux
# abstract namespace.

from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_true

from net import (
    PollEvent,
    Poller,
    TCPStream,
    UnixListener,
    UnixStream,
    is_timeout_error,
    is_would_block,
)
from net.libc import AF_UNIX, F_GETFL, SOCK_STREAM, c_fcntl, o_nonblock


def sock_path(tag: StringSpan) -> String:
    var pid = external_call["getpid", c_int]()
    return (
        String("/tmp/mojo-net-")
        + String(tag)
        + "-"
        + String(Int(pid))
        + ".sock"
    )


def cleanup(var path: String):
    _ = external_call["unlink", c_int](path.as_c_string_slice())


def test_echo_and_eof() raises:
    var path = sock_path("echo")
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server_side = listener.accept()

    client.write_all("over the socket file".as_bytes())
    var got = server_side.read_exact(20)
    assert_equal(String(from_utf8=got), "over the socket file")
    server_side.write_all(Span(got))
    assert_equal(
        String(from_utf8=client.read_exact(20)), "over the socket file"
    )

    # EOF propagation through shutdown of the write half.
    client.shutdown_write()
    var buf = List[Byte]()
    buf.resize(16, 0)
    assert_equal(server_side.read(buf), 0)

    client.close()
    server_side.close()
    listener.close()
    cleanup(path^)


def test_connection_paths() raises:
    var path = sock_path("names")
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server_side = listener.accept()

    assert_equal(client.local_path(), "")
    assert_equal(client.peer_path(), path)
    assert_equal(server_side.local_path(), path)
    assert_equal(server_side.peer_path(), "")

    var closed_fd = client.stream.fd
    client.close()
    var replacement_path = sock_path("names-reuse")
    var replacement = UnixListener(replacement_path, remove_existing=True)
    assert_equal(
        Int(replacement.fd), Int(closed_fd), "kernel reused the closed fd"
    )
    var failed = False
    try:
        _ = client.local_path()
    except:
        failed = True
    assert_true(failed, "closed unix socket has no local path")
    failed = False
    try:
        _ = client.peer_path()
    except:
        failed = True
    assert_true(failed, "closed unix socket has no peer path")
    replacement.close()
    server_side.close()
    listener.close()
    cleanup(replacement_path^)
    cleanup(path^)


def test_unnamed_and_unconnected_paths() raises:
    var pair = Array[c_int, 2](fill=0)
    var rc = external_call["socketpair", c_int](
        c_int(AF_UNIX), c_int(SOCK_STREAM), c_int(0), pair.unsafe_ptr()
    )
    assert_equal(Int(rc), 0, "socketpair")
    var left = UnixStream(stream=TCPStream(pair[0]))
    var right = UnixStream(stream=TCPStream(pair[1]))
    assert_equal(left.local_path(), "")
    assert_equal(left.peer_path(), "")
    assert_equal(right.local_path(), "")
    assert_equal(right.peer_path(), "")
    left.close()
    right.close()

    var fd = external_call["socket", c_int](
        c_int(AF_UNIX), c_int(SOCK_STREAM), c_int(0)
    )
    assert_true(fd >= 0, "unconnected unix socket")
    var unconnected = UnixStream(stream=TCPStream(fd))
    var failed = False
    try:
        _ = unconnected.peer_path()
    except e:
        failed = True
        assert_true("getpeername" in String(e), String(e))
    assert_true(failed, "unconnected unix peer lookup must fail")
    unconnected.close()


def test_large_transfer() raises:
    # 1 MiB in 4 KiB chunks, drained by the peer in-loop. Chunks must stay
    # under the platform's AF_UNIX in-flight buffer (macOS caps it around
    # 8 KiB, far below TCP loopback) or a same-thread write blocks.
    var path = sock_path("bulk")
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server_side = listener.accept()
    var chunk = List[Byte]()
    chunk.resize(4096, 0xA5)
    var total = 0
    for _ in range(256):
        client.write_all(Span(chunk))
        var got = server_side.read_exact(4096)
        assert_equal(got[0], 0xA5)
        total += len(got)
    assert_equal(total, 1_048_576)
    client.close()
    server_side.close()
    listener.close()
    cleanup(path^)


def test_read_timeout_is_typed() raises:
    var path = sock_path("timeout")
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server_side = listener.accept()
    client.set_read_timeout(50_000_000)
    var timed_out = False
    try:
        _ = client.read_exact(1)
    except e:
        timed_out = True
        assert_true(is_timeout_error(e), "must be the typed timeout error")
    assert_true(timed_out)
    client.set_read_timeout(0)
    server_side.write_all("x".as_bytes())
    assert_equal(String(from_utf8=client.read_exact(1)), "x")
    client.close()
    server_side.close()
    listener.close()
    cleanup(path^)


def test_connect_failures() raises:
    var missing = sock_path("missing")
    cleanup(missing.copy())
    var raised = False
    try:
        _ = UnixStream.connect(missing)
    except e:
        raised = True
        assert_true("connect" in String(e), String(e))
    assert_true(raised, "connect to a missing path must raise")

    raised = False
    try:
        _ = UnixStream.connect("")
    except e:
        raised = True
        assert_true("empty" in String(e), String(e))
    assert_true(raised, "empty path must raise")


def test_bind_semantics() raises:
    var path = sock_path("bind")
    var first = UnixListener(path, remove_existing=True)
    # A second bind on the same live path fails, like CPython.
    var raised = False
    try:
        _ = UnixListener(path)
    except e:
        raised = True
        assert_true("bind" in String(e), String(e))
    assert_true(raised, "rebinding a bound path must raise")
    first.close()
    # The socket file survives close(); remove_existing lets us rebind.
    var second = UnixListener(path, remove_existing=True)
    var probe = UnixStream.connect(path)
    var accepted = second.accept()
    probe.write_all("ok".as_bytes())
    assert_equal(String(from_utf8=accepted.read_exact(2)), "ok")
    probe.close()
    accepted.close()
    second.close()
    cleanup(path^)


def test_path_too_long() raises:
    var long_path = String("/tmp/")
    for _ in range(120):
        long_path += "x"
    var raised = False
    try:
        _ = UnixListener(long_path)
    except e:
        raised = True
        assert_true("too long" in String(e), String(e))
    assert_true(raised, "over-length path must raise")


def test_into_stream() raises:
    # The converted TCPStream carries the same fd and keeps working.
    var path = sock_path("into")
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server_side = listener.accept()
    var tcp_view = client^.into_stream()
    tcp_view.write_all("via tcp api".as_bytes())
    assert_equal(String(from_utf8=server_side.read_exact(11)), "via tcp api")
    tcp_view.close()
    server_side.close()
    listener.close()
    cleanup(path^)


def test_double_close() raises:
    var path = sock_path("close")
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server_side = listener.accept()
    client.close()
    client.close()
    server_side.close()
    listener.close()
    listener.close()
    cleanup(path^)


def test_abstract_namespace() raises:
    # Linux only: a NUL-prefixed name lives in the abstract namespace and
    # creates no filesystem entry. macOS must reject it.
    var name = String(chr(0)) + "mojo-net-abstract-test"
    comptime if CompilationTarget.is_linux():
        var listener = UnixListener(name)
        var client = UnixStream.connect(name)
        var server_side = listener.accept()
        assert_equal(client.local_path(), "")
        assert_equal(client.peer_path(), name)
        assert_equal(server_side.local_path(), name)
        assert_equal(server_side.peer_path(), "")
        client.write_all("abstract".as_bytes())
        assert_equal(String(from_utf8=server_side.read_exact(8)), "abstract")
        client.close()
        server_side.close()
        listener.close()
    else:
        var raised = False
        try:
            _ = UnixListener(name)
        except e:
            raised = True
            assert_true("Linux-only" in String(e), String(e))
        assert_true(raised, "abstract names must be rejected on macOS")


def _readable(events: List[PollEvent], fd: Int) -> Bool:
    for ev in events:
        if Int(ev.fd) == fd and ev.readable:
            return True
    return False


def test_nonblocking_accept_drains_burst() raises:
    var path = sock_path("nb-accept")
    var poller = Poller()
    var listener = UnixListener(path, remove_existing=True)
    assert_equal(
        Int(listener.descriptor()), Int(listener.fd), "listener descriptor"
    )
    assert_true(not listener.nonblocking, "listeners are blocking by default")
    listener.set_nonblocking(True)
    assert_true(listener.nonblocking, "listener entered non-blocking mode")
    poller.register(listener.descriptor(), readable=True, writable=False)

    var client_count = 8
    var clients = List[UnixStream]()
    for _ in range(client_count):
        clients.append(UnixStream.connect(path))

    assert_true(
        _readable(poller.wait(2000), Int(listener.descriptor())),
        "listener readable for a connection burst",
    )

    var accepted = List[UnixStream]()
    while True:
        try:
            accepted.append(listener.accept())
        except e:
            assert_true(is_would_block(e), "drained accept queue: " + String(e))
            break
    assert_equal(len(accepted), client_count, "all burst connections accepted")

    listener.set_nonblocking(False)
    assert_true(not listener.nonblocking, "listener restored blocking mode")
    for i in range(len(clients)):
        clients[i].close()
    for i in range(len(accepted)):
        accepted[i].close()
    listener.close()
    poller.close()
    cleanup(path)


def test_accepted_stream_inherits_listener_mode() raises:
    var path = sock_path("nb-inherit")
    var listener = UnixListener(path, remove_existing=True)

    var blocking_client = UnixStream.connect(path)
    var blocking_child = listener.accept()
    var flags = c_fcntl(blocking_child.stream.fd, F_GETFL, 0)
    assert_true(flags >= 0, "read blocking child flags")
    assert_true(
        not blocking_child.stream.nonblocking, "blocking wrapper state"
    )
    assert_equal(Int(flags & o_nonblock()), 0, "blocking descriptor flags")

    listener.set_nonblocking(True)
    var accept_poller = Poller()
    accept_poller.register(
        listener.descriptor(), readable=True, writable=False
    )
    var nonblocking_client = UnixStream.connect(path)
    assert_true(
        _readable(accept_poller.wait(2000), Int(listener.descriptor())),
        "non-blocking listener became readable",
    )
    var nonblocking_child = listener.accept()
    flags = c_fcntl(nonblocking_child.stream.fd, F_GETFL, 0)
    assert_true(flags >= 0, "read non-blocking child flags")
    assert_true(
        nonblocking_child.stream.nonblocking, "non-blocking wrapper state"
    )
    assert_true(
        (flags & o_nonblock()) != 0, "non-blocking descriptor flags"
    )

    var blocked = False
    try:
        _ = nonblocking_child.read_exact(1)
    except e:
        blocked = True
        assert_true(is_would_block(e), "empty accepted stream: " + String(e))
    assert_true(blocked, "empty accepted stream must not block")

    blocking_client.close()
    blocking_child.close()
    nonblocking_client.close()
    nonblocking_child.close()
    accept_poller.close()
    listener.close()
    cleanup(path)


def main() raises:
    test_echo_and_eof()
    test_connection_paths()
    test_unnamed_and_unconnected_paths()
    test_large_transfer()
    test_read_timeout_is_typed()
    test_connect_failures()
    test_bind_semantics()
    test_path_too_long()
    test_into_stream()
    test_double_close()
    test_abstract_namespace()
    test_nonblocking_accept_drains_burst()
    test_accepted_stream_inherits_listener_mode()
    print("test_unix: all tests passed")
