# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""UDP datagram sockets.

`UDPSocket` is a bound, blocking datagram socket with `send_to` /
`recv_from` and an optional read timeout that surfaces as the typed
`TIMEOUT_ERROR` (check with `is_timeout_error()`).
"""

from std.ffi import c_int

from .libc import (
    SOCK_DGRAM,
    c_close,
    c_getsockname,
    c_recvfrom,
    c_sendto,
    c_setsockopt_timeval,
    c_socket,
    c_bind,
    os_error,
    so_rcvtimeo,
    sol_socket,
)
from .sockaddr import SOCKADDR_STORAGE_LEN, SocketAddress


struct UDPSocket(Movable):
    """A bound, blocking UDP socket.

    Binding port 0 picks a free port; read the actual port from
    `local_port`. Closes its file descriptor on destruction; call
    `close()` to release it earlier.
    """

    var fd: c_int
    """The underlying socket file descriptor."""
    var local_port: UInt16
    """The bound port, recovered via getsockname (useful with port 0)."""
    var closed: Bool
    """True once the descriptor has been closed via `close()`."""

    def __init__(out self, host: StringSpan, port: UInt16) raises:
        """Creates a datagram socket bound to a numeric IP literal and port.

        Args:
            host: Numeric IPv4/IPv6 literal to bind, e.g. "127.0.0.1"
                (hostnames are not resolved here).
            port: Port to bind; 0 lets the kernel pick a free port
                (see `local_port`).

        Raises:
            If the host is not a numeric literal or socket creation or
            bind fails.
        """
        var addr = SocketAddress.parse(host, port)
        self.fd = c_socket(addr.family(), SOCK_DGRAM, 0)
        self.closed = False
        if self.fd < 0:
            raise os_error("socket(SOCK_DGRAM)")
        var packed = addr.to_sockaddr()
        if c_bind(self.fd, packed[0].unsafe_ptr(), packed[1]) != 0:
            var err = os_error("bind")
            _ = c_close(self.fd)
            self.closed = True
            raise err
        var out_sa = Array[UInt8, SOCKADDR_STORAGE_LEN](fill=0)
        var out_len = c_int(SOCKADDR_STORAGE_LEN)
        _ = c_getsockname(self.fd, out_sa.unsafe_ptr(), Pointer(to=out_len))
        var span = Span(out_sa)[0 : Int(out_len)]
        self.local_port = SocketAddress.from_sockaddr(span).port

    def send_to(self, data: Span[Byte, _], dest: SocketAddress) raises:
        """Sends one datagram to a destination address.

        Args:
            data: The datagram payload; sent as a single datagram.
            dest: The destination address and port.

        Raises:
            If the send fails or fewer bytes than len(data) were sent
            ("net: short datagram send").
        """
        var packed = dest.to_sockaddr()
        var n = c_sendto(
            self.fd,
            data.unsafe_ptr(),
            len(data),
            c_int(0),
            packed[0].unsafe_ptr(),
            packed[1],
        )
        if n < 0:
            raise os_error("sendto")
        if n != len(data):
            raise Error("net: short datagram send")

    def recv_from(
        self, mut buf: List[Byte]
    ) raises -> Tuple[Int, SocketAddress]:
        """Receives one datagram and the sender's address.

        Blocks until a datagram arrives (or a configured read timeout
        expires). buf must be sized to the maximum expected datagram
        length before the call; a larger datagram is truncated to
        len(buf).

        Args:
            buf: Buffer to receive into; shrunk to the datagram size.

        Returns:
            A (bytes_received, sender) tuple.

        Raises:
            On socket errors, including the typed `TIMEOUT_ERROR` when a
            read timeout expires, or if the sender's address family is
            unsupported.
        """
        var sa = Array[UInt8, SOCKADDR_STORAGE_LEN](fill=0)
        var sa_len = c_int(SOCKADDR_STORAGE_LEN)
        var n = c_recvfrom(
            self.fd,
            buf.unsafe_ptr(),
            len(buf),
            c_int(0),
            sa.unsafe_ptr(),
            Pointer(to=sa_len),
        )
        if n < 0:
            raise os_error("recvfrom")
        buf.shrink(n)
        var span = Span(sa)[0 : Int(sa_len)]
        return (n, SocketAddress.from_sockaddr(span))

    def set_read_timeout(self, nanos: Int64) raises:
        """Sets SO_RCVTIMEO so blocking receives fail after this long.

        An expired timeout surfaces as the typed `TIMEOUT_ERROR`
        (check with `is_timeout_error()`).

        Args:
            nanos: Timeout in nanoseconds (microsecond resolution);
                0 clears the timeout.

        Raises:
            If the setsockopt call fails.
        """
        if (
            c_setsockopt_timeval(self.fd, sol_socket(), so_rcvtimeo(), nanos)
            != 0
        ):
            raise os_error("setsockopt(SO_RCVTIMEO)")

    def close(mut self):
        """Closes the socket; safe to call more than once."""
        if not self.closed:
            _ = c_close(self.fd)
            self.closed = True

    def __deinit__(deinit self):
        """Closes the socket if `close()` was never called."""
        if not self.closed:
            _ = c_close(self.fd)
