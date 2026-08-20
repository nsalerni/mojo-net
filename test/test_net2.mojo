# Tests for the mojo-net publish prerequisites: DNS, IPv6, UDP, timeouts.

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from net import SocketAddress, TCPListener, TCPStream, UDPSocket, resolve


def test_parse_literals() raises:
    var v4 = SocketAddress.parse("192.168.1.7", 8080)
    assert_true(not v4.is_v6, "v4 literal")
    assert_equal(String(v4), "192.168.1.7:8080")

    var v6 = SocketAddress.parse("::1", 443)
    assert_true(v6.is_v6, "v6 literal")
    assert_equal(v6.addr[15], 1)
    assert_equal(v6.port, 443)

    var full = SocketAddress.parse("fe80::abcd", 1)
    assert_equal(full.addr[0], 0xFE)
    assert_equal(full.addr[1], 0x80)
    assert_equal(full.addr[14], 0xAB)
    assert_equal(full.addr[15], 0xCD)

    var failed = False
    try:
        _ = SocketAddress.parse("not-an-ip", 1)
    except:
        failed = True
    assert_true(failed, "hostname must not parse as literal")


def test_sockaddr_roundtrip() raises:
    var v4 = SocketAddress.parse("10.1.2.3", 50051)
    var p4 = v4.to_sockaddr()
    assert_equal(p4[1], 16)
    var back4 = SocketAddress.from_sockaddr(Span(p4[0])[0:16])
    assert_true(back4 == v4, "v4 sockaddr roundtrip")

    var v6 = SocketAddress.parse("2001:db8::42", 9999)
    var p6 = v6.to_sockaddr()
    assert_equal(p6[1], 28)
    var back6 = SocketAddress.from_sockaddr(Span(p6[0])[0:28])
    assert_true(back6 == v6, "v6 sockaddr roundtrip")


def test_resolve_localhost() raises:
    var addrs = resolve("localhost", 80)
    assert_true(len(addrs) >= 1, "localhost resolves")
    var found_loopback = False
    for a in addrs:
        if not a.is_v6 and a.addr[0] == 127:
            found_loopback = True
        if a.is_v6 and a.addr[15] == 1:
            found_loopback = True
        assert_equal(a.port, 80)
    assert_true(found_loopback, "resolved to a loopback address")


def test_connect_by_hostname() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("localhost", listener.local_port)
    var server_side = listener.accept()
    var msg = String("via dns")
    client.write_all(msg.as_bytes())
    var got = server_side.read_exact(msg.byte_length())
    assert_equal(String(from_utf8=got), msg)
    client.close()
    server_side.close()
    listener.close()


def test_ipv6_loopback() raises:
    var listener = TCPListener("::1", 0)
    var client = TCPStream.connect("::1", listener.local_port)
    var server_side = listener.accept()
    var msg = String("over v6")
    client.write_all(msg.as_bytes())
    var got = server_side.read_exact(msg.byte_length())
    assert_equal(String(from_utf8=got), msg)
    client.close()
    server_side.close()
    listener.close()


def test_read_timeout() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.set_read_timeout(100_000_000)  # 100ms
    var start = perf_counter_ns()
    var timed_out = False
    try:
        _ = client.read_exact(1)  # nothing will arrive
    except:
        timed_out = True
    var elapsed = perf_counter_ns() - start
    assert_true(timed_out, "read must time out")
    assert_true(elapsed >= 80_000_000, "waited at least ~100ms")
    assert_true(elapsed < 2_000_000_000, "did not hang")
    # Clearing the timeout restores blocking reads.
    client.set_read_timeout(0)
    server_side.write_all(String("x").as_bytes())
    var got = client.read_exact(1)
    assert_equal(Int(got[0]), ord("x"))
    client.close()
    server_side.close()
    listener.close()


def test_udp_roundtrip() raises:
    var a = UDPSocket("127.0.0.1", 0)
    var b = UDPSocket("127.0.0.1", 0)
    var dest = SocketAddress.parse("127.0.0.1", b.local_port)
    var payload = String("datagram!")
    a.send_to(payload.as_bytes(), dest)

    var buf = List[Byte]()
    buf.resize(1500, 0)
    var r = b.recv_from(buf)
    assert_equal(r[0], payload.byte_length())
    assert_equal(String(from_utf8=buf), payload)
    assert_equal(r[1].port, a.local_port)

    # Reply goes back to the sender address recv_from reported.
    b.send_to(String("pong").as_bytes(), r[1])
    var buf2 = List[Byte]()
    buf2.resize(1500, 0)
    var r2 = a.recv_from(buf2)
    assert_equal(String(from_utf8=buf2), "pong")
    _ = r2

    # UDP read timeout
    a.set_read_timeout(50_000_000)
    var timed_out = False
    var buf3 = List[Byte]()
    buf3.resize(16, 0)
    try:
        _ = a.recv_from(buf3)
    except:
        timed_out = True
    assert_true(timed_out, "udp recv times out")
    a.close()
    b.close()


def main() raises:
    test_parse_literals()
    test_sockaddr_roundtrip()
    test_resolve_localhost()
    test_connect_by_hostname()
    test_ipv6_loopback()
    test_read_timeout()
    test_udp_roundtrip()
    print("test_net2: all tests passed")
