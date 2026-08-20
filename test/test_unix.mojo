# Unix domain socket tests: echo roundtrip and EOF, timeouts, bind and
# connect failure paths, path-length limits, lifecycle, and the Linux
# abstract namespace.

from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_true

from net import UnixListener, UnixStream, is_timeout_error


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


def main() raises:
    test_echo_and_eof()
    test_large_transfer()
    test_read_timeout_is_typed()
    test_connect_failures()
    test_bind_semantics()
    test_path_too_long()
    test_into_stream()
    test_double_close()
    test_abstract_namespace()
    print("test_unix: all tests passed")
