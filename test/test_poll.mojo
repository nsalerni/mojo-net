# Non-blocking I/O and Poller tests: typed would-block errors, readiness
# for accept/read/write, hangup delivery, interest changes, wait timeouts,
# and non-blocking connect on both the success and refusal paths.

from std.testing import assert_equal, assert_true

from net import (
    PollEvent,
    Poller,
    SocketAddress,
    TCPListener,
    TCPStream,
    is_would_block,
)
from net.libc import F_GETFL, c_fcntl, o_nonblock


def flags_for(
    events: List[PollEvent], fd: Int
) -> Tuple[Bool, Bool, Bool, Bool]:
    # Merges kqueue's per-filter events and epoll's single event into one
    # (readable, writable, hangup, error) view for a descriptor.
    var r = False
    var w = False
    var h = False
    var e = False
    for ev in events:
        if Int(ev.fd) != fd:
            continue
        r = r or ev.readable
        w = w or ev.writable
        h = h or ev.hangup
        e = e or ev.error
    return (r, w, h, e)


def test_would_block_read() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.set_nonblocking(True)
    var raised = False
    try:
        _ = client.read_exact(1)
    except e:
        raised = True
        assert_true(is_would_block(e), "empty non-blocking read: " + String(e))
    assert_true(raised)
    # Blocking mode restores the old behavior.
    client.set_nonblocking(False)
    server_side.write_all("x".as_bytes())
    assert_equal(String(from_utf8=client.read_exact(1)), "x")
    client.close()
    server_side.close()
    listener.close()


def test_accept_and_read_readiness() raises:
    var poller = Poller()
    var listener = TCPListener("127.0.0.1", 0)
    poller.register(listener.fd, readable=True, writable=False)

    # Nothing pending: a short wait comes back empty.
    assert_equal(len(poller.wait(50)), 0)

    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var events = poller.wait(2000)
    var got = flags_for(events, Int(listener.fd))
    assert_true(got[0], "listener readable once a connection is pending")

    var server_side = listener.accept()
    server_side.set_nonblocking(True)
    poller.register(server_side.fd, readable=True, writable=False)
    assert_equal(len(poller.wait(50)), 0)

    client.write_all("ping".as_bytes())
    events = poller.wait(2000)
    got = flags_for(events, Int(server_side.fd))
    assert_true(got[0], "connected socket readable once data arrives")
    assert_equal(String(from_utf8=server_side.read_exact(4)), "ping")

    # Peer hangup surfaces as readable and/or hangup; a read then sees EOF.
    client.close()
    events = poller.wait(2000)
    got = flags_for(events, Int(server_side.fd))
    assert_true(got[0] or got[2], "hangup must wake the poller")
    var buf = List[Byte]()
    buf.resize(8, 0)
    assert_equal(server_side.read(buf), 0)

    server_side.close()
    listener.close()
    poller.close()


def test_nonblocking_accept_drains_burst() raises:
    var poller = Poller()
    var listener = TCPListener("127.0.0.1", 0)
    assert_equal(
        Int(listener.descriptor()), Int(listener.fd), "listener descriptor"
    )
    assert_true(not listener.nonblocking, "listeners are blocking by default")
    listener.set_nonblocking(True)
    assert_true(listener.nonblocking, "listener entered non-blocking mode")
    poller.register(listener.descriptor(), readable=True, writable=False)

    var client_count = 8
    var clients = List[TCPStream]()
    for _ in range(client_count):
        clients.append(TCPStream.connect("127.0.0.1", listener.local_port))

    var got = flags_for(poller.wait(2000), Int(listener.descriptor()))
    assert_true(got[0], "listener readable for a connection burst")

    var accepted = List[TCPStream]()
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


def test_accepted_stream_inherits_listener_mode() raises:
    var listener = TCPListener("127.0.0.1", 0)

    var blocking_client = TCPStream.connect(
        "127.0.0.1", listener.local_port
    )
    var blocking_child = listener.accept()
    var flags = c_fcntl(blocking_child.fd, F_GETFL, 0)
    assert_true(flags >= 0, "read blocking child flags")
    assert_true(not blocking_child.nonblocking, "blocking wrapper state")
    assert_equal(Int(flags & o_nonblock()), 0, "blocking descriptor flags")

    listener.set_nonblocking(True)
    var accept_poller = Poller()
    accept_poller.register(
        listener.descriptor(), readable=True, writable=False
    )
    var nonblocking_client = TCPStream.connect(
        "127.0.0.1", listener.local_port
    )
    var ready = flags_for(
        accept_poller.wait(2000), Int(listener.descriptor())
    )
    assert_true(ready[0], "non-blocking listener became readable")
    var nonblocking_child = listener.accept()
    flags = c_fcntl(nonblocking_child.fd, F_GETFL, 0)
    assert_true(flags >= 0, "read non-blocking child flags")
    assert_true(nonblocking_child.nonblocking, "non-blocking wrapper state")
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


def test_writable_and_interest_changes() raises:
    var poller = Poller()
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()

    poller.register(client.fd, readable=False, writable=True)
    var got = flags_for(poller.wait(2000), Int(client.fd))
    assert_true(got[1], "an idle connected socket is writable")

    # Dropping write interest silences the events.
    poller.modify(client.fd, readable=True, writable=False)
    assert_equal(len(poller.wait(50)), 0)

    # And unregistering silences the descriptor entirely.
    server_side.write_all("x".as_bytes())
    poller.unregister(client.fd)
    assert_equal(len(poller.wait(50)), 0)

    client.close()
    server_side.close()
    listener.close()
    poller.close()


def test_would_block_write_and_recovery() raises:
    # Fill the send path against a non-reading peer until the typed
    # would-block error surfaces, then drain and confirm writability.
    var poller = Poller()
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.set_nonblocking(True)

    var chunk = List[Byte]()
    chunk.resize(65536, 0x42)
    var sent_chunks = 0
    var blocked = False
    for _ in range(1024):
        try:
            client.write_all(Span(chunk))
            sent_chunks += 1
        except e:
            assert_true(is_would_block(e), String(e))
            blocked = True
            break
    assert_true(blocked, "kernel buffers must fill eventually")

    # Drain until the pipe stays quiet; bytes can still be in flight
    # between the two kernel buffers, so a single would-block is not
    # "empty". The property that matters: after draining, the writer
    # polls writable again.
    _ = sent_chunks
    var drained = 0
    server_side.set_nonblocking(True)
    var drain_poller = Poller()
    drain_poller.register(server_side.fd, readable=True, writable=False)
    while True:
        var quiet = len(drain_poller.wait(200)) == 0
        if quiet:
            break
        while True:
            var buf = List[Byte]()
            buf.resize(65536, 0)
            try:
                var n = server_side.read(buf)
                if n == 0:
                    break
                drained += n
            except e:
                assert_true(is_would_block(e), String(e))
                break
    drain_poller.close()
    assert_true(drained > 0, "peer sees the sent bytes")
    poller.register(client.fd, readable=False, writable=True)
    var got = flags_for(poller.wait(2000), Int(client.fd))
    assert_true(got[1], "drained socket polls writable again")

    client.close()
    server_side.close()
    listener.close()
    poller.close()


def test_nonblocking_connect_success() raises:
    var poller = Poller()
    var listener = TCPListener("127.0.0.1", 0)
    var addr = SocketAddress.parse("127.0.0.1", listener.local_port)
    var client = TCPStream.connect_addr_nonblocking(addr)
    poller.register(client.fd, readable=False, writable=True)
    var got = flags_for(poller.wait(2000), Int(client.fd))
    assert_true(got[1], "completing connect polls writable")
    assert_equal(client.connect_error(), 0, "handshake succeeded")

    var server_side = listener.accept()
    client.write_all("hello".as_bytes())
    assert_equal(String(from_utf8=server_side.read_exact(5)), "hello")
    client.close()
    server_side.close()
    listener.close()
    poller.close()


def test_nonblocking_connect_refused() raises:
    var probe = TCPListener("127.0.0.1", 0)
    var dead_port = probe.local_port
    probe.close()

    var poller = Poller()
    var addr = SocketAddress.parse("127.0.0.1", dead_port)
    var client = TCPStream.connect_addr_nonblocking(addr)
    poller.register(client.fd, readable=False, writable=True)
    var events = poller.wait(2000)
    var got = flags_for(events, Int(client.fd))
    assert_true(
        got[1] or got[2] or got[3], "failed connect must wake the poller"
    )
    assert_true(client.connect_error() != 0, "refusal is reported")
    client.close()
    poller.close()


def main() raises:
    test_would_block_read()
    test_accept_and_read_readiness()
    test_nonblocking_accept_drains_burst()
    test_accepted_stream_inherits_listener_mode()
    test_writable_and_interest_changes()
    test_would_block_write_and_recovery()
    test_nonblocking_connect_success()
    test_nonblocking_connect_refused()
    print("test_poll: all tests passed")
