# Loopback smoke test for net.TCPListener/TCPStream.
# Single-threaded: relies on kernel socket buffers to hold the small
# payloads while we alternate between the two ends.

from std.testing import assert_equal, assert_true

from net import IPv4Address, SocketAddress, TCPListener, TCPStream


def test_address_roundtrip() raises:
    var a = IPv4Address("127.0.0.1", 50051)
    var sa = a.to_sockaddr()
    var b = IPv4Address.from_sockaddr(sa)
    assert_equal(String(b), "127.0.0.1:50051")


def test_address_invalid() raises:
    var failed = False
    try:
        _ = IPv4Address("300.0.0.1", 1)
    except:
        failed = True
    assert_true(failed, "expected parse failure")


def test_loopback_echo() raises:
    var listener = TCPListener("127.0.0.1", 0)
    assert_true(listener.local_port != 0, "ephemeral port assigned")

    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()

    var msg = String("hello grpc-mojo")
    client.write_all(msg.as_bytes())
    var got = server_side.read_exact(msg.byte_length())
    assert_equal(String(from_utf8=got), msg)

    # echo back
    server_side.write_all(Span(got))
    var back = client.read_exact(msg.byte_length())
    assert_equal(String(from_utf8=back), msg)

    # EOF propagation
    client.shutdown_write()
    var buf = List[Byte]()
    buf.resize(16, 0)
    var n = server_side.read(buf)
    assert_equal(n, 0)

    client.close()
    server_side.close()
    listener.close()


def check_connection_addresses(host: StringSpan, expect_v6: Bool) raises:
    var listener = TCPListener(host, 0)
    var client = TCPStream.connect(host, listener.local_port)
    var server_side = listener.accept()

    var client_local = client.local_address()
    var client_peer = client.peer_address()
    var server_local = server_side.local_address()
    var server_peer = server_side.peer_address()
    var listener_address = SocketAddress.parse(host, listener.local_port)

    assert_equal(client_local.is_v6, expect_v6)
    assert_equal(client_peer.is_v6, expect_v6)
    assert_true(client_local.port != 0, "client has an ephemeral port")
    assert_true(client_peer == listener_address, "client sees listener")
    assert_true(server_local == listener_address, "accepted local address")
    assert_true(server_peer == client_local, "accepted peer matches client")
    assert_equal(client_local.scope_id, server_peer.scope_id)
    assert_equal(client_peer.scope_id, server_local.scope_id)

    client.close()
    server_side.close()
    listener.close()


def test_connection_addresses() raises:
    check_connection_addresses("127.0.0.1", False)
    check_connection_addresses("::1", True)

    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    var closed_fd = client.fd
    client.close()
    var replacement = TCPListener("127.0.0.1", 0)
    assert_equal(
        Int(replacement.fd), Int(closed_fd), "kernel reused the closed fd"
    )
    var local_failed = False
    try:
        _ = client.local_address()
    except:
        local_failed = True
    assert_true(local_failed, "closed socket has no local address")
    var peer_failed = False
    try:
        _ = client.peer_address()
    except:
        peer_failed = True
    assert_true(peer_failed, "closed socket has no peer address")
    replacement.close()
    server_side.close()
    listener.close()


def main() raises:
    test_address_roundtrip()
    test_address_invalid()
    test_loopback_echo()
    test_connection_addresses()
    print("test_tcp: all tests passed")
