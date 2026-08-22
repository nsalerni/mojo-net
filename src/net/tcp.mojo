# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""TCP streams and listeners over the libc bindings.

`TCPListener` accepts connections; `TCPStream` is one connected socket.
Both are blocking by default and can be switched to non-blocking mode for
use with `Poller`. Bound blocking stream waits with `set_read_timeout` /
`set_write_timeout`, which surface expiry as the typed `TIMEOUT_ERROR`
(check with `is_timeout_error()`). SIGPIPE on writes to a closed peer is
suppressed on both platforms (SO_NOSIGPIPE on macOS, MSG_NOSIGNAL on Linux).
"""

from std.ffi import c_int, get_errno
from std.sys import CompilationTarget

from .address import IPv4Address
from .resolver import resolve
from .sockaddr import SOCKADDR_STORAGE_LEN, SocketAddress
from .stream import ReadinessStream
from .libc import (
    AF_INET,
    F_GETFL,
    F_SETFL,
    SHUT_WR,
    WOULD_BLOCK_ERROR,
    SOCK_STREAM,
    TCP_NODELAY,
    IPPROTO_TCP,
    c_setsockopt_timeval,
    so_rcvtimeo,
    so_sndtimeo,
    c_accept,
    c_bind,
    c_close,
    c_connect,
    c_getsockname,
    c_ioctl_fionread,
    c_listen,
    c_recv,
    c_send,
    c_setsockopt_int,
    c_shutdown,
    c_fcntl,
    c_getsockopt_int,
    c_socket,
    einprogress,
    is_timeout_error,
    msg_nosignal,
    o_nonblock,
    os_error,
    so_error,
    so_nosigpipe,
    so_reuseaddr,
    sol_socket,
)


def _new_tcp_socket(family: Int = AF_INET) raises -> c_int:
    """Creates a TCP socket with SIGPIPE suppression configured."""
    var fd = c_socket(family, SOCK_STREAM, 0)
    if fd < 0:
        raise os_error("socket")
    comptime if CompilationTarget.is_macos():
        # Suppress SIGPIPE on writes to closed peers (Linux: MSG_NOSIGNAL).
        _ = c_setsockopt_int(fd, sol_socket(), so_nosigpipe(), 1)
    return fd


struct TCPStream(ReadinessStream):
    """A connected, blocking TCP stream.

    Obtained from `connect()`/`connect_addr()` on the client side or
    `TCPListener.accept()` on the server side. Closes its file
    descriptor on destruction; call `close()` to release it earlier.
    """

    var fd: c_int
    """The underlying socket file descriptor."""
    var closed: Bool
    """True once the descriptor has been closed via `close()`."""
    var nonblocking: Bool
    """True while the descriptor is in non-blocking mode."""

    def __init__(out self, fd: c_int):
        """Wraps an already-connected socket file descriptor.

        Takes ownership: the descriptor is closed when the stream is
        destroyed.

        Args:
            fd: A connected TCP socket file descriptor.
        """
        self.fd = fd
        self.closed = False
        self.nonblocking = False

    def _io_error(self, var context: String) -> Error:
        # EAGAIN means "timeout expired" on a blocking socket but "retry
        # when ready" on a non-blocking one; pick the right typed error.
        var err = os_error(context^)
        if self.nonblocking and is_timeout_error(err):
            return Error(WOULD_BLOCK_ERROR)
        return err

    def descriptor(self) -> c_int:
        """Returns the connected socket descriptor for `Poller`.

        Returns:
            The owned socket descriptor.
        """
        return self.fd

    @staticmethod
    def connect(host: StringSpan, port: UInt16) raises -> TCPStream:
        """Connects to a hostname or numeric IPv4/IPv6 literal.

        Numeric literals are used directly; hostnames resolve via DNS
        and each returned address is tried in the resolver's preference
        order until one connects.

        Args:
            host: Hostname or numeric IP literal.
            port: Destination port.

        Returns:
            A connected stream.

        Raises:
            If resolution fails or no address accepts the connection
            (the error reflects the last attempt).
        """
        var addrs: List[SocketAddress]
        try:
            addrs = [SocketAddress.parse(host, port)]
        except:
            addrs = resolve(host, port)
        var last_err = Error("net: no addresses to try")
        for a in addrs:
            var fd = _new_tcp_socket(a.family())
            var packed = a.to_sockaddr()
            if c_connect(fd, packed[0].unsafe_ptr(), packed[1]) == 0:
                return TCPStream(fd)
            last_err = os_error("connect " + String(a))
            _ = c_close(fd)
        raise last_err

    @staticmethod
    def connect_addr(addr: SocketAddress) raises -> TCPStream:
        """Connects to a single already-resolved socket address.

        Args:
            addr: The destination address and port.

        Returns:
            A connected stream.

        Raises:
            If socket creation or the connection fails.
        """
        var fd = _new_tcp_socket(addr.family())
        var packed = addr.to_sockaddr()
        if c_connect(fd, packed[0].unsafe_ptr(), packed[1]) != 0:
            var err = os_error("connect " + String(addr))
            _ = c_close(fd)
            raise err
        return TCPStream(fd)

    @staticmethod
    def connect_addr_nonblocking(addr: SocketAddress) raises -> TCPStream:
        """Starts a non-blocking connect to an already-resolved address.

        The returned stream is in non-blocking mode and the handshake may
        still be in flight: poll the descriptor for writability, then call
        `connect_error()` to learn the outcome.

        Args:
            addr: The destination address and port.

        Returns:
            A stream whose connection may still be in progress.

        Raises:
            If socket creation fails, or the connect fails immediately
            with anything other than in-progress.
        """
        var fd = _new_tcp_socket(addr.family())
        var flags = c_fcntl(fd, F_GETFL, 0)
        if flags < 0 or c_fcntl(fd, F_SETFL, Int(flags | o_nonblock())) < 0:
            var ferr = os_error("fcntl(O_NONBLOCK)")
            _ = c_close(fd)
            raise ferr
        var packed = addr.to_sockaddr()
        if c_connect(fd, packed[0].unsafe_ptr(), packed[1]) != 0:
            var e = get_errno()
            if Int(e.value) != einprogress():
                var err = Error(
                    "connect " + String(addr) + ": errno " + String(e.value)
                )
                _ = c_close(fd)
                raise err
        var stream = TCPStream(fd)
        stream.nonblocking = True
        return stream^

    def set_read_timeout(self, nanos: Int64) raises:
        """Sets SO_RCVTIMEO so blocking reads fail after this long.

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

    def set_write_timeout(self, nanos: Int64) raises:
        """Sets SO_SNDTIMEO so blocking writes fail after this long.

        An expired timeout surfaces as the typed `TIMEOUT_ERROR`
        (check with `is_timeout_error()`).

        Args:
            nanos: Timeout in nanoseconds (microsecond resolution);
                0 clears the timeout.

        Raises:
            If the setsockopt call fails.
        """
        if (
            c_setsockopt_timeval(self.fd, sol_socket(), so_sndtimeo(), nanos)
            != 0
        ):
            raise os_error("setsockopt(SO_SNDTIMEO)")

    def set_nodelay(self, enabled: Bool) raises:
        """Enables or disables TCP_NODELAY (Nagle's algorithm).

        Args:
            enabled: True to send small writes immediately, False to
                let the kernel coalesce them.

        Raises:
            If the setsockopt call fails.
        """
        if (
            c_setsockopt_int(
                self.fd,
                c_int(IPPROTO_TCP),
                c_int(TCP_NODELAY),
                1 if enabled else 0,
            )
            != 0
        ):
            raise os_error("setsockopt(TCP_NODELAY)")

    def set_nonblocking(mut self, enabled: Bool) raises:
        """Switches the socket between blocking and non-blocking mode.

        In non-blocking mode, reads and writes that cannot proceed raise
        the typed `WOULD_BLOCK_ERROR` (check with `is_would_block()`)
        instead of waiting; use a `Poller` to learn when to retry.

        Args:
            enabled: True for non-blocking mode, False for blocking.

        Raises:
            If the fcntl calls fail.
        """
        var flags = c_fcntl(self.fd, F_GETFL, 0)
        if flags < 0:
            raise os_error("fcntl(F_GETFL)")
        var updated: c_int
        if enabled:
            updated = flags | o_nonblock()
        else:
            updated = flags & ~o_nonblock()
        if c_fcntl(self.fd, F_SETFL, Int(updated)) < 0:
            raise os_error("fcntl(F_SETFL)")
        self.nonblocking = enabled

    def connect_error(self) raises -> Int:
        """Reads and clears the socket's pending error (SO_ERROR).

        After a non-blocking connect reports the socket writable, this
        tells whether the handshake succeeded (0) or the errno it failed
        with (e.g. 61/111 for a refused connection).

        Returns:
            0 if the connection succeeded, the failure errno otherwise.

        Raises:
            If the getsockopt call fails.
        """
        var value = c_int(0)
        if (
            c_getsockopt_int(
                self.fd, sol_socket(), so_error(), Pointer(to=value)
            )
            != 0
        ):
            raise os_error("getsockopt(SO_ERROR)")
        return Int(value)

    def read(self, mut buf: List[Byte]) raises -> Int:
        """Reads up to len(buf) bytes; resizes buf to what was read.

        Blocks until at least one byte is available, EOF, or a
        configured read timeout expires. buf must have been sized
        (resize) to the maximum read length before the call.

        Args:
            buf: Buffer to read into; shrunk to the bytes actually read.

        Returns:
            The number of bytes read; 0 on orderly EOF (peer closed).

        Raises:
            On socket errors, including the typed `TIMEOUT_ERROR` when a
            read timeout expires.
        """
        # recv(fd, _, 0) is platform-dependent (Linux can block, macOS
        # returns 0); make the zero-sized case uniformly a no-op.
        if len(buf) == 0:
            return 0
        var n = c_recv(self.fd, buf.unsafe_ptr(), len(buf), c_int(0))
        if n < 0:
            raise self._io_error("recv")
        buf.shrink(n)
        return n

    def read_exact(self, n: Int) raises -> List[Byte]:
        """Reads exactly n bytes, looping over short reads.

        Unlike `read()`, EOF is an error here: a peer that closes the
        connection before n bytes arrive causes a raise.

        Args:
            n: The exact number of bytes to read.

        Returns:
            A list of exactly n bytes.

        Raises:
            On EOF before n bytes arrive, on socket errors, or with the
            typed `TIMEOUT_ERROR` when a read timeout expires.
        """
        var out = List[Byte](capacity=n)
        var chunk = List[Byte]()
        while len(out) < n:
            chunk.resize(n - len(out), 0)
            var got = c_recv(self.fd, chunk.unsafe_ptr(), len(chunk), c_int(0))
            if got < 0:
                raise self._io_error("recv")
            if got == 0:
                raise Error("connection closed mid-read (EOF)")
            out.extend(chunk[:got])
        return out^

    def write_all(self, data: Span[Byte, _]) raises:
        """Writes the entire span, looping until every byte is sent.

        Args:
            data: The bytes to send.

        Raises:
            On socket errors, including the typed `TIMEOUT_ERROR` when a
            write timeout expires.
        """
        var sent = 0
        while sent < len(data):
            var n = c_send(
                self.fd,
                data.unsafe_ptr().unsafe_offset(sent),
                len(data) - sent,
                msg_nosignal(),
            )
            if n < 0:
                raise self._io_error("send")
            sent += n

    def write_some(self, data: Span[Byte, _]) raises -> Int:
        """Writes as much of the span as fits right now, without looping.

        The partial-write primitive for non-blocking sockets: where
        `write_all` loops until everything is sent (and so cannot report
        progress when a non-blocking write stalls midway), this performs a
        single send and returns how many bytes the kernel accepted.

        Args:
            data: The bytes to offer.

        Returns:
            The number of bytes accepted (at least 1 for non-empty data).

        Raises:
            The typed `WOULD_BLOCK_ERROR` when a non-blocking socket
            cannot accept any bytes, or other socket errors.
        """
        if len(data) == 0:
            return 0
        var n = c_send(self.fd, data.unsafe_ptr(), len(data), msg_nosignal())
        if n < 0:
            raise self._io_error("send")
        return n

    def bytes_available(self) -> Int:
        """Reports the bytes readable right now without blocking.

        Uses ioctl(FIONREAD); returns 0 both when nothing is buffered
        and when the query itself fails.

        Returns:
            The number of bytes a `read()` could return immediately.
        """
        return c_ioctl_fionread(self.fd)

    def shutdown_write(self):
        """Closes the write half of the connection (shutdown SHUT_WR).

        The peer's next read observes EOF; this stream can still read.
        Failures are ignored.
        """
        _ = c_shutdown(self.fd, SHUT_WR)

    def close(mut self):
        """Closes the socket; safe to call more than once."""
        if not self.closed:
            _ = c_close(self.fd)
            self.closed = True

    def __deinit__(deinit self):
        """Closes the socket if `close()` was never called."""
        if not self.closed:
            _ = c_close(self.fd)


struct TCPListener(Movable):
    """A listening TCP socket bound to a local address.

    Binds with SO_REUSEADDR, listens with a backlog of 128, and closes
    its file descriptor on destruction. Binding port 0 picks a free
    port; read the actual port from `local_port`.
    """

    var fd: c_int
    """The listening socket file descriptor."""
    var local_port: UInt16
    """The bound port, recovered via getsockname (useful with port 0)."""
    var closed: Bool
    """True once the descriptor has been closed via `close()`."""
    var nonblocking: Bool
    """True while the listening descriptor is in non-blocking mode."""

    def __init__(out self, host: StringSpan, port: UInt16) raises:
        """Binds and listens on a numeric IPv4/IPv6 literal and port.

        Args:
            host: Numeric IP literal to bind, e.g. "127.0.0.1" or "::1"
                (hostnames are not resolved here).
            port: Port to bind; 0 lets the kernel pick a free port
                (see `local_port`).

        Raises:
            If the host is not a numeric literal or socket creation,
            bind, or listen fails.
        """
        var addr = SocketAddress.parse(host, port)
        self.fd = _new_tcp_socket(addr.family())
        self.closed = False
        self.nonblocking = False
        _ = c_setsockopt_int(self.fd, sol_socket(), so_reuseaddr(), 1)
        var packed = addr.to_sockaddr()
        if c_bind(self.fd, packed[0].unsafe_ptr(), packed[1]) != 0:
            var err = os_error("bind")
            _ = c_close(self.fd)
            self.closed = True
            raise err
        if c_listen(self.fd, 128) != 0:
            var err = os_error("listen")
            _ = c_close(self.fd)
            self.closed = True
            raise err
        # Recover the actual port (useful when binding port 0).
        var out_sa = Array[UInt8, SOCKADDR_STORAGE_LEN](fill=0)
        var out_len = c_int(SOCKADDR_STORAGE_LEN)
        _ = c_getsockname(self.fd, out_sa.unsafe_ptr(), Pointer(to=out_len))
        var span = Span(out_sa)[0 : Int(out_len)]
        self.local_port = SocketAddress.from_sockaddr(span).port

    def descriptor(self) -> c_int:
        """Returns the listening socket descriptor for `Poller`.

        Returns:
            The owned listening socket descriptor.
        """
        return self.fd

    def set_nonblocking(mut self, enabled: Bool) raises:
        """Switches the listener between blocking and non-blocking mode.

        In non-blocking mode, `accept()` raises the typed
        `WOULD_BLOCK_ERROR` when the pending connection queue is empty.
        Wait for readable readiness with `Poller` before trying again.

        Args:
            enabled: True for non-blocking mode, False for blocking.

        Raises:
            If the fcntl calls fail.
        """
        var flags = c_fcntl(self.fd, F_GETFL, 0)
        if flags < 0:
            raise os_error("fcntl(F_GETFL)")
        var updated: c_int
        if enabled:
            updated = flags | o_nonblock()
        else:
            updated = flags & ~o_nonblock()
        if c_fcntl(self.fd, F_SETFL, Int(updated)) < 0:
            raise os_error("fcntl(F_SETFL)")
        self.nonblocking = enabled

    def accept(self) raises -> TCPStream:
        """Accepts one pending connection and returns its stream.

        Blocks by default. In non-blocking mode, an empty pending queue
        raises the typed `WOULD_BLOCK_ERROR`.

        Returns:
            The accepted connection as a `TCPStream`.

        Raises:
            If the accept call fails.
        """
        var sa = Array[UInt8, SOCKADDR_STORAGE_LEN](fill=0)
        var sa_len = c_int(SOCKADDR_STORAGE_LEN)
        var fd = c_accept(self.fd, sa.unsafe_ptr(), Pointer(to=sa_len))
        if fd < 0:
            var err = os_error("accept")
            if self.nonblocking and is_timeout_error(err):
                raise Error(WOULD_BLOCK_ERROR)
            raise err
        return TCPStream(fd)

    def close(mut self):
        """Closes the listening socket; safe to call more than once."""
        if not self.closed:
            _ = c_close(self.fd)
            self.closed = True

    def __deinit__(deinit self):
        """Closes the listening socket if `close()` was never called."""
        if not self.closed:
            _ = c_close(self.fd)
