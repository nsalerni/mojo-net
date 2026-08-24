# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

# Edge-case and error-path tests for mojo-net: address parsing failures,
# sockaddr coding boundaries, typed timeouts, zero-length I/O, lifecycle
# (double close, deinit-based fd release), and platform behaviors like
# SIGPIPE suppression. Complements the happy-path tests in test_tcp.mojo
# and test_net2.mojo.

from std.sys import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true
from std.time import sleep

from net import (
    IPv4Address,
    SocketAddress,
    TCPListener,
    TCPStream,
    UDPSocket,
    is_timeout_error,
    resolve,
)
from net.libc import (
    AF_INET,
    SOCK_DGRAM,
    _checked_sockaddr_len,
    af_inet6,
)


def expect_raises[F: def() raises](f: F, why: StringSpan) raises -> String:
    """Runs f, asserting it raises; returns the error text for inspection."""
    try:
        f()
    except e:
        return String(e)
    raise Error("expected a raise: " + String(why))


# --- SocketAddress construction and comparison ---


def test_v4_constructor() raises:
    var a = SocketAddress.v4(10, 20, 30, 40, 8080)
    var b = SocketAddress.parse("10.20.30.40", 8080)
    assert_true(a == b, "v4() must equal parse() of the same address")
    assert_false(a.is_v6)
    assert_equal(a.scope_id, 0)
    # Unused v6 tail bytes are zero-filled.
    for i in range(4, 16):
        assert_equal(a.addr[i], 0)


def test_eq_negative_cases() raises:
    var base = SocketAddress.parse("10.0.0.1", 80)
    assert_false(base == SocketAddress.parse("10.0.0.2", 80), "addr differs")
    assert_false(base == SocketAddress.parse("10.0.0.1", 81), "port differs")
    assert_false(base == SocketAddress.parse("::1", 80), "family differs")
    # scope_id is documented as not participating in equality.
    var s1 = SocketAddress.parse("fe80::1", 80)
    var s2 = SocketAddress(is_v6=True, addr=s1.addr.copy(), port=80, scope_id=7)
    assert_true(s1 == s2, "scope_id must not affect equality")


def test_v6_formatting() raises:
    var a = SocketAddress.parse("2001:db8::42", 9999)
    assert_equal(String(a), "[2001:db8:0:0:0:0:0:42]:9999")
    var lo = SocketAddress.parse("::1", 1)
    assert_equal(String(lo), "[0:0:0:0:0:0:0:1]:1")


# --- sockaddr byte-level coding ---


def test_checked_sockaddr_lengths() raises:
    assert_equal(_checked_sockaddr_len(16, 16, 28, "test"), 16)

    def negative() raises:
        _ = _checked_sockaddr_len(-1, 2, 110, "test")

    def short() raises:
        _ = _checked_sockaddr_len(15, 16, 28, "test")

    def oversized() raises:
        _ = _checked_sockaddr_len(29, 16, 28, "test")

    assert_true("short socket address" in expect_raises(negative, "negative"))
    assert_true("short socket address" in expect_raises(short, "short"))
    assert_true("exceeded" in expect_raises(oversized, "oversized"))


def test_sockaddr_v4_layout() raises:
    var a = SocketAddress.v4(192, 168, 1, 2, 0x1234)
    var packed = a.to_sockaddr()
    assert_equal(packed[1], 16, "sockaddr_in length")
    var buf = packed[0].copy()
    comptime if CompilationTarget.is_macos():
        assert_equal(buf[0], 16, "sin_len on macOS")
        assert_equal(Int(buf[1]), AF_INET)
    else:
        assert_equal(Int(buf[0]), AF_INET)
        assert_equal(buf[1], 0)
    # Port is big-endian at offset 2; address bytes at offset 4.
    assert_equal(buf[2], 0x12)
    assert_equal(buf[3], 0x34)
    assert_equal(buf[4], 192)
    assert_equal(buf[7], 2)


def test_sockaddr_v6_scope_roundtrip() raises:
    var src = SocketAddress.parse("fe80::abcd", 443)
    var scoped = SocketAddress(
        is_v6=True, addr=src.addr.copy(), port=443, scope_id=7
    )
    var packed = scoped.to_sockaddr()
    assert_equal(packed[1], 28, "sockaddr_in6 length")
    var back = SocketAddress.from_sockaddr(Span(packed[0])[0:28])
    assert_true(back.is_v6)
    assert_equal(back.port, 443)
    assert_equal(back.scope_id, 7, "scope_id must survive the roundtrip")
    assert_true(back == scoped)


def test_from_sockaddr_errors() raises:
    def short_buf() raises:
        var raw = List[Byte]()
        raw.resize(4, 0)
        _ = SocketAddress.from_sockaddr(Span(raw))

    var msg = expect_raises(short_buf, "short sockaddr")
    assert_true("short sockaddr" in msg, msg)

    def short_v6() raises:
        # A valid v6 sockaddr truncated below the 28-byte minimum.
        var packed = SocketAddress.parse("::1", 1).to_sockaddr()
        _ = SocketAddress.from_sockaddr(Span(packed[0])[0:20])

    msg = expect_raises(short_v6, "short sockaddr_in6")
    assert_true("short sockaddr_in6" in msg, msg)

    def bad_family() raises:
        # Family byte 1 (AF_UNIX) on macOS; 1|256 on Linux is unsupported
        # either way.
        var raw = List[Byte]()
        raw.resize(16, 0)
        raw[0] = 1
        raw[1] = 1
        _ = SocketAddress.from_sockaddr(Span(raw))

    msg = expect_raises(bad_family, "unsupported family")
    assert_true("unsupported address family" in msg, msg)


# --- IPv4Address parse edges ---


def test_ipv4_parse_edges() raises:
    def too_few() raises:
        _ = IPv4Address("1.2.3", 1)

    def too_many() raises:
        _ = IPv4Address("1.2.3.4.5", 1)

    def empty() raises:
        _ = IPv4Address("", 1)

    def negative() raises:
        _ = IPv4Address("-1.0.0.1", 1)

    _ = expect_raises(too_few, "3 octets")
    _ = expect_raises(too_many, "5 octets")
    _ = expect_raises(empty, "empty host")
    _ = expect_raises(negative, "negative octet")
    # Boundary values must be accepted.
    assert_equal(String(IPv4Address("0.0.0.0", 0)), "0.0.0.0:0")
    assert_equal(
        String(IPv4Address("255.255.255.255", 65535)), "255.255.255.255:65535"
    )


# --- resolve() hints and failures ---


def test_resolve_variants() raises:
    # Numeric literal: exactly one v4 address back.
    var lit = resolve("127.0.0.1", 80)
    assert_equal(len(lit), 1)
    assert_false(lit[0].is_v6)
    assert_equal(lit[0].port, 80)

    # family filter: v4-only results.
    var v4only = resolve("localhost", 80, family=AF_INET)
    for a in v4only:
        assert_false(a.is_v6, "family=AF_INET must exclude v6")

    # socktype hint accepted for datagram lookups.
    var dgram = resolve("localhost", 80, socktype=SOCK_DGRAM)
    assert_true(len(dgram) >= 1)

    def nxdomain() raises:
        # RFC 2606 reserves .invalid: guaranteed to never resolve.
        _ = resolve("host.invalid", 80)

    var msg = expect_raises(nxdomain, "NXDOMAIN")
    assert_true("getaddrinfo failed" in msg, msg)


# --- TCP connection error paths and typed timeouts ---


def closed_port() raises -> UInt16:
    """Returns a port that was just bound and released (nothing listens)."""
    var probe = TCPListener("127.0.0.1", 0)
    var port = probe.local_port
    probe.close()
    return port


def test_connect_refused() raises:
    var port = closed_port()
    var msg = String("")
    try:
        _ = TCPStream.connect("127.0.0.1", port)
    except e:
        msg = String(e)
    assert_true("connect" in msg and "errno" in msg, msg)
    assert_false(is_timeout_error(Error(msg)), "refusal is not a timeout")


def test_connect_addr() raises:
    # Success path against a live listener.
    var listener = TCPListener("127.0.0.1", 0)
    var addr = SocketAddress.parse("127.0.0.1", listener.local_port)
    var client = TCPStream.connect_addr(addr)
    var server_side = listener.accept()
    client.write_all("ping".as_bytes())
    assert_equal(String(from_utf8=server_side.read_exact(4)), "ping")
    client.close()
    server_side.close()
    listener.close()

    # Failure path: same address after the listener is gone.
    var msg = String("")
    try:
        _ = TCPStream.connect_addr(SocketAddress.parse("127.0.0.1", addr.port))
    except e:
        msg = String(e)
    assert_true("connect" in msg, msg)


def test_read_timeout_is_typed() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.set_read_timeout(50_000_000)  # 50ms
    var timed_out = False
    try:
        _ = client.read_exact(1)
    except e:
        timed_out = True
        assert_true(is_timeout_error(e), "must be the typed TIMEOUT_ERROR")
    assert_true(timed_out)
    # Clearing the timeout must not raise; data still flows afterwards.
    client.set_read_timeout(0)
    server_side.write_all("x".as_bytes())
    assert_equal(String(from_utf8=client.read_exact(1)), "x")
    client.close()
    server_side.close()
    listener.close()


def test_write_timeout_set_clear() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    client.set_write_timeout(100_000_000)
    client.set_write_timeout(0)
    client.close()
    listener.close()


def test_nodelay_toggle() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.set_nodelay(True)
    client.write_all("a".as_bytes())
    assert_equal(String(from_utf8=server_side.read_exact(1)), "a")
    client.set_nodelay(False)
    client.write_all("b".as_bytes())
    assert_equal(String(from_utf8=server_side.read_exact(1)), "b")
    client.close()
    server_side.close()
    listener.close()


def test_bytes_available() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    assert_equal(client.bytes_available(), 0, "idle socket")
    server_side.write_all("hello".as_bytes())
    # Loopback delivery is fast but not instant; poll briefly.
    var avail = 0
    for _ in range(100):
        avail = client.bytes_available()
        if avail == 5:
            break
        sleep(0.01)
    assert_equal(avail, 5, "FIONREAD after peer write")
    _ = client.read_exact(5)
    assert_equal(client.bytes_available(), 0, "drained")
    var fd_probe = client.fd
    client.close()
    server_side.close()
    listener.close()
    # Query on a closed fd reports 0 rather than raising.
    assert_equal(TCPStream(fd_probe).bytes_available(), 0)


# --- zero-length I/O ---


def test_zero_length_io() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()

    # Empty write is a no-op.
    var empty = List[Byte]()
    client.write_all(Span(empty))

    # read_exact(0) returns an empty list without touching the socket.
    var none = client.read_exact(0)
    assert_equal(len(none), 0)

    # read() into a zero-sized buffer returns 0. This is indistinguishable
    # from EOF, so callers must size the buffer before reading.
    var buf = List[Byte]()
    assert_equal(client.read(buf), 0)

    client.close()
    server_side.close()
    listener.close()


# --- UDP edges ---


def test_udp_zero_length_datagram() raises:
    var a = UDPSocket("127.0.0.1", 0)
    var b = UDPSocket("127.0.0.1", 0)
    var empty = List[Byte]()
    a.send_to(Span(empty), SocketAddress.parse("127.0.0.1", b.local_port))
    b.set_read_timeout(2_000_000_000)
    var buf = List[Byte]()
    buf.resize(16, 0)
    var got = b.recv_from(buf)
    assert_equal(got[0], 0, "empty datagram received as 0 bytes")
    a.close()
    b.close()


def test_udp_truncation() raises:
    var a = UDPSocket("127.0.0.1", 0)
    var b = UDPSocket("127.0.0.1", 0)
    var big = List[Byte]()
    big.resize(300, 0x5A)
    a.send_to(Span(big), SocketAddress.parse("127.0.0.1", b.local_port))
    b.set_read_timeout(2_000_000_000)
    var buf = List[Byte]()
    buf.resize(100, 0)
    var got = b.recv_from(buf)
    assert_equal(got[0], 100, "datagram truncated to the buffer size")
    assert_equal(len(buf), 100)
    assert_equal(buf[99], 0x5A)
    a.close()
    b.close()


def test_udp_ipv6_roundtrip() raises:
    var a = UDPSocket("::1", 0)
    var b = UDPSocket("::1", 0)
    a.send_to(
        "v6 datagram".as_bytes(), SocketAddress.parse("::1", b.local_port)
    )
    b.set_read_timeout(2_000_000_000)
    var buf = List[Byte]()
    buf.resize(64, 0)
    var got = b.recv_from(buf)
    assert_equal(got[0], 11)
    assert_equal(String(from_utf8=buf), "v6 datagram")
    assert_true(got[1].is_v6, "sender address decodes as v6")
    a.close()
    b.close()


def test_udp_timeout_is_typed() raises:
    var s = UDPSocket("127.0.0.1", 0)
    s.set_read_timeout(50_000_000)
    var timed_out = False
    try:
        var buf = List[Byte]()
        buf.resize(8, 0)
        _ = s.recv_from(buf)
    except e:
        timed_out = True
        assert_true(is_timeout_error(e), "must be the typed TIMEOUT_ERROR")
    assert_true(timed_out)
    s.close()


# --- lifecycle ---


def test_double_close() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var u = UDPSocket("127.0.0.1", 0)
    client.close()
    client.close()
    listener.close()
    listener.close()
    u.close()
    u.close()


def test_constructor_failures() raises:
    def hostname_listener() raises:
        _ = TCPListener("not-an-ip.example", 0)

    def hostname_udp() raises:
        _ = UDPSocket("not-an-ip.example", 0)

    def unbindable() raises:
        # TEST-NET-3 (RFC 5737): never a local interface address.
        _ = TCPListener("203.0.113.7", 0)

    _ = expect_raises(hostname_listener, "hostnames not resolved here")
    _ = expect_raises(hostname_udp, "hostnames not resolved here")
    var msg = expect_raises(unbindable, "bind must fail")
    assert_true("bind" in msg, msg)


def test_accept_after_close() raises:
    var listener = TCPListener("127.0.0.1", 0)
    listener.close()
    var raised = False
    try:
        _ = listener.accept()
    except e:
        raised = True
        assert_true("accept" in String(e), String(e))
    assert_true(raised, "accept on a closed listener must raise")


def test_deinit_releases_fds() raises:
    # Create and drop listeners without close(); if __deinit__ leaked the
    # fd this would exhaust the default descriptor limit (256 on macOS,
    # 1024 on typical Linux) long before 600 iterations complete.
    for _ in range(600):
        var l = TCPListener("127.0.0.1", 0)
        var c = TCPStream.connect("127.0.0.1", l.local_port)
        var u = UDPSocket("127.0.0.1", 0)
        # Reference every socket after the connect so Mojo's eager (ASAP)
        # destruction doesn't close the listener before the dial lands.
        _ = c.fd
        _ = u.local_port
        _ = l.fd
    # Still able to open sockets afterwards.
    var survivor = TCPListener("127.0.0.1", 0)
    assert_true(survivor.local_port != 0)
    survivor.close()


def test_sigpipe_suppressed() raises:
    # Writing to a peer that fully closed must raise a normal error, not
    # kill the process with SIGPIPE (SO_NOSIGPIPE on macOS, MSG_NOSIGNAL
    # on Linux).
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    server_side.close()
    sleep(0.05)
    # Bound the writes: if the platform keeps buffering instead of
    # surfacing the reset, the typed write timeout still raises.
    client.set_write_timeout(2_000_000_000)
    var chunk = List[Byte]()
    chunk.resize(65536, 0)
    var raised = False
    try:
        # First writes may land in the kernel buffer before the RST is
        # processed; keep writing until the failure surfaces.
        for _ in range(50):
            client.write_all(Span(chunk))
            sleep(0.01)
    except:
        raised = True
    assert_true(raised, "write to a closed peer must raise (not SIGPIPE)")
    client.close()
    listener.close()


def main() raises:
    test_checked_sockaddr_lengths()
    print("... test_v4_constructor")
    test_v4_constructor()
    print("... test_eq_negative_cases")
    test_eq_negative_cases()
    print("... test_v6_formatting")
    test_v6_formatting()
    print("... test_sockaddr_v4_layout")
    test_sockaddr_v4_layout()
    print("... test_sockaddr_v6_scope_roundtrip")
    test_sockaddr_v6_scope_roundtrip()
    print("... test_from_sockaddr_errors")
    test_from_sockaddr_errors()
    print("... test_ipv4_parse_edges")
    test_ipv4_parse_edges()
    print("... test_resolve_variants")
    test_resolve_variants()
    print("... test_connect_refused")
    test_connect_refused()
    print("... test_connect_addr")
    test_connect_addr()
    print("... test_read_timeout_is_typed")
    test_read_timeout_is_typed()
    print("... test_write_timeout_set_clear")
    test_write_timeout_set_clear()
    print("... test_nodelay_toggle")
    test_nodelay_toggle()
    print("... test_bytes_available")
    test_bytes_available()
    print("... test_zero_length_io")
    test_zero_length_io()
    print("... test_udp_zero_length_datagram")
    test_udp_zero_length_datagram()
    print("... test_udp_truncation")
    test_udp_truncation()
    print("... test_udp_ipv6_roundtrip")
    test_udp_ipv6_roundtrip()
    print("... test_udp_timeout_is_typed")
    test_udp_timeout_is_typed()
    print("... test_double_close")
    test_double_close()
    print("... test_constructor_failures")
    test_constructor_failures()
    print("... test_accept_after_close")
    test_accept_after_close()
    print("... test_deinit_releases_fds")
    test_deinit_releases_fds()
    print("... test_sigpipe_suppressed")
    test_sigpipe_suppressed()
    print("test_net_edges: all tests passed")
