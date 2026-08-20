# Loopback smoke test for net.TCPListener/TCPStream.
# Single-threaded: relies on kernel socket buffers to hold the small
# payloads while we alternate between the two ends.

from std.testing import assert_equal, assert_true

from net import IPv4Address, TCPListener, TCPStream


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


def main() raises:
    test_address_roundtrip()
    test_address_invalid()
    test_loopback_echo()
    print("test_tcp: all tests passed")
