# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""Unix domain stream sockets (`AF_UNIX`).

`UnixListener` binds a filesystem path (or, on Linux, an abstract-namespace
name given with a leading NUL byte); `UnixStream` is one connected socket.
Once connected, a Unix stream behaves exactly like a TCP stream at the fd
level, so `UnixStream` delegates its I/O to the same machinery and can be
converted into a `TCPStream` with `into_stream()` for APIs written against
that type.

The `sockaddr_un` layout differs between the platforms: macOS/BSD packs a
`sun_len` byte, a one-byte family, then 104 path bytes; Linux packs a
16-bit family then 108 path bytes. Both are handled here.

Socket files are not removed automatically: binding an existing path fails
(like CPython) unless `remove_existing=True`, and `close()` leaves the
file for the owner to unlink.
"""

from std.ffi import c_int
from std.sys import CompilationTarget

from .libc import (
    AF_UNIX,
    SOCK_STREAM,
    c_accept,
    c_bind,
    c_close,
    c_connect,
    c_getpeername,
    c_getsockname,
    c_listen,
    c_unlink,
    _checked_sockaddr_len,
    os_error,
)
from .sockaddr import SOCKADDR_STORAGE_LEN
from .stream import ReadinessStream
from .tcp import TCPStream, _new_tcp_socket

comptime _SOCKADDR_UN_LEN = 110
"""Buffer size covering sockaddr_un on both platforms (Linux is largest)."""


def _sun_path_capacity() -> Int:
    """Returns the platform's sun_path capacity (104 macOS, 108 Linux)."""
    comptime if CompilationTarget.is_macos():
        return 104
    else:
        return 108


def _pack_sockaddr_un(
    path: StringSpan,
) raises -> Tuple[Array[UInt8, _SOCKADDR_UN_LEN], Int]:
    """Encodes a socket path as a platform sockaddr_un.

    A leading NUL byte selects the Linux abstract namespace (no filesystem
    entry, address length excludes the trailing NUL); such names are
    rejected on macOS, which has no abstract namespace.

    Args:
        path: The socket path, or a NUL-prefixed abstract name on Linux.

    Returns:
        A (buffer, length) tuple where length is the exact byte count to
        pass to bind/connect.

    Raises:
        If the path is empty, too long for the platform's sun_path field,
        or abstract on a platform without an abstract namespace.
    """
    var bytes = path.as_bytes()
    if len(bytes) == 0:
        raise Error("net: empty unix socket path")
    var abstract = bytes[0] == 0
    comptime if CompilationTarget.is_macos():
        if abstract:
            raise Error("net: abstract unix sockets are Linux-only")
    var cap = _sun_path_capacity()
    # A filesystem path needs its trailing NUL inside sun_path.
    var needed = len(bytes) if abstract else len(bytes) + 1
    if needed > cap:
        raise Error("net: unix socket path too long")

    var buf = Array[UInt8, _SOCKADDR_UN_LEN](fill=0)
    var addr_len = 2 + needed
    comptime if CompilationTarget.is_macos():
        buf[0] = UInt8(addr_len)  # sun_len
        buf[1] = UInt8(AF_UNIX)
    else:
        buf[0] = UInt8(AF_UNIX)
        buf[1] = 0
    for i in range(len(bytes)):
        buf[2 + i] = bytes[i]
    return (buf^, addr_len)


def _unpack_sockaddr_un(raw: Span[Byte, _]) raises -> String:
    """Decodes a Unix sockaddr path, preserving Linux abstract names."""
    if len(raw) < 2:
        raise Error("net: short unix socket address")
    var family: Int
    comptime if CompilationTarget.is_macos():
        family = Int(raw[1])
    else:
        family = Int(raw[0]) | (Int(raw[1]) << 8)
    if family != AF_UNIX:
        raise Error("net: expected unix socket address")
    if len(raw) == 2:
        return String("")

    var end = len(raw)
    var abstract = False
    comptime if CompilationTarget.is_linux():
        abstract = raw[2] == 0
    if not abstract:
        while end > 2 and raw[end - 1] == 0:
            end -= 1
    var path = List[Byte](capacity=end - 2)
    for i in range(2, end):
        path.append(raw[i])
    return String(from_utf8=path)


@fieldwise_init
struct UnixStream(ReadinessStream):
    """A connected Unix domain stream socket.

    Obtained from `connect()` or `UnixListener.accept()`. I/O behaves
    exactly like `TCPStream` (same read/write/timeout semantics), because
    at the fd level it is the same machinery.
    """

    var stream: TCPStream
    """The underlying fd stream; Unix and TCP fds share their I/O paths."""

    def descriptor(self) -> c_int:
        """Returns the connected socket descriptor for `Poller`.

        Returns:
            The owned Unix socket descriptor.
        """
        return self.stream.descriptor()

    def local_path(self) raises -> String:
        """Returns this connection's bound Unix socket path.

        An unbound endpoint, normally the connecting client, returns an
        empty string. Linux abstract names retain their leading NUL byte.
        The path is decoded as UTF-8 because this API returns `String`.
        Non-UTF-8 path bytes raise an error.

        Returns:
            The local filesystem path, abstract name, or an empty string.

        Raises:
            If the descriptor is closed or the kernel query fails.
        """
        if self.stream.closed:
            raise Error("net: socket is closed")
        var raw = Array[UInt8, _SOCKADDR_UN_LEN](fill=0)
        var raw_len = c_int(_SOCKADDR_UN_LEN)
        if (
            c_getsockname(
                self.stream.fd, raw.unsafe_ptr(), Pointer(to=raw_len)
            )
            != 0
        ):
            raise os_error("getsockname")
        var length = _checked_sockaddr_len(
            Int(raw_len), 2, _SOCKADDR_UN_LEN, "getsockname"
        )
        return _unpack_sockaddr_un(Span(raw)[0:length])

    def peer_path(self) raises -> String:
        """Returns the connected peer's Unix socket path.

        An unbound peer, normally the client accepted by a server, returns
        an empty string. Linux abstract names retain their leading NUL byte.
        The path is decoded as UTF-8 because this API returns `String`.
        Non-UTF-8 path bytes raise an error.

        Returns:
            The peer filesystem path, abstract name, or an empty string.

        Raises:
            If the descriptor is closed or unconnected, or the kernel query
            fails.
        """
        if self.stream.closed:
            raise Error("net: socket is closed")
        var raw = Array[UInt8, _SOCKADDR_UN_LEN](fill=0)
        var raw_len = c_int(_SOCKADDR_UN_LEN)
        if (
            c_getpeername(
                self.stream.fd, raw.unsafe_ptr(), Pointer(to=raw_len)
            )
            != 0
        ):
            raise os_error("getpeername")
        var length = _checked_sockaddr_len(
            Int(raw_len), 2, _SOCKADDR_UN_LEN, "getpeername"
        )
        return _unpack_sockaddr_un(Span(raw)[0:length])

    @staticmethod
    def connect(path: StringSpan) raises -> UnixStream:
        """Connects to a Unix domain socket at a filesystem path.

        On Linux, a NUL-prefixed name connects to the abstract namespace.

        Args:
            path: The socket path to connect to.

        Returns:
            A connected stream.

        Raises:
            If the path is invalid or nothing is listening there.
        """
        var packed = _pack_sockaddr_un(path)
        var fd = _new_tcp_socket(AF_UNIX)
        if c_connect(fd, packed[0].unsafe_ptr(), packed[1]) != 0:
            var err = os_error("connect " + String(path))
            _ = c_close(fd)
            raise err
        return UnixStream(stream=TCPStream(fd))

    def read(self, mut buf: List[Byte]) raises -> Int:
        """Reads up to len(buf) bytes; see `TCPStream.read`.

        Args:
            buf: Buffer to read into; shrunk to the bytes actually read.

        Returns:
            The number of bytes read; 0 on orderly EOF.

        Raises:
            On socket errors, including the typed timeout error.
        """
        return self.stream.read(buf)

    def read_exact(self, n: Int) raises -> List[Byte]:
        """Reads exactly n bytes; see `TCPStream.read_exact`.

        Args:
            n: The exact number of bytes to read.

        Returns:
            A list of exactly n bytes.

        Raises:
            On EOF before n bytes, socket errors, or the typed timeout
            error.
        """
        return self.stream.read_exact(n)

    def write_all(self, data: Span[Byte, _]) raises:
        """Writes the entire span; see `TCPStream.write_all`.

        Args:
            data: The bytes to send.

        Raises:
            On socket errors, including the typed timeout error.
        """
        self.stream.write_all(data)

    def write_some(self, data: Span[Byte, _]) raises -> Int:
        """Performs one partial write; see `TCPStream.write_some`.

        Args:
            data: Bytes to offer to the socket.

        Returns:
            The number of bytes accepted, or zero for empty input.

        Raises:
            The typed would-block error or another socket error.
        """
        return self.stream.write_some(data)

    def set_read_timeout(self, nanos: Int64) raises:
        """Bounds blocking reads; see `TCPStream.set_read_timeout`.

        Args:
            nanos: Timeout in nanoseconds; 0 clears it.

        Raises:
            If the setsockopt call fails.
        """
        self.stream.set_read_timeout(nanos)

    def set_write_timeout(self, nanos: Int64) raises:
        """Bounds blocking writes; see `TCPStream.set_write_timeout`.

        Args:
            nanos: Timeout in nanoseconds; 0 clears it.

        Raises:
            If the setsockopt call fails.
        """
        self.stream.set_write_timeout(nanos)

    def set_nodelay(self, enabled: Bool) raises:
        """Accepts the latency hint as a no-op.

        Nagle's algorithm is a TCP concept; Unix domain sockets deliver
        writes immediately already.

        Args:
            enabled: Ignored.

        Raises:
            Never; declared raising only to satisfy the `IOStream` trait.
        """
        _ = enabled

    def set_nonblocking(mut self, enabled: Bool) raises:
        """Switches the socket's blocking mode; see `TCPStream`.

        Args:
            enabled: True for non-blocking mode, False for blocking.

        Raises:
            If the fcntl calls fail.
        """
        self.stream.set_nonblocking(enabled)

    def bytes_available(self) -> Int:
        """Reports bytes readable without blocking; see `TCPStream`.

        Returns:
            The number of bytes a `read()` could return immediately.
        """
        return self.stream.bytes_available()

    def shutdown_write(self):
        """Closes the write half; the peer's next read observes EOF."""
        self.stream.shutdown_write()

    def close(mut self):
        """Closes the socket; safe to call more than once."""
        self.stream.close()

    def into_stream(deinit self) -> TCPStream:
        """Converts into a `TCPStream` for APIs written against that type.

        The fd-level behavior is identical; only the static type changes.

        Returns:
            The underlying stream, transferring fd ownership.
        """
        return self.stream^


struct UnixListener(Movable):
    """A listening Unix domain socket bound to a path.

    Binding a path that already exists fails, matching CPython; pass
    `remove_existing=True` to unlink a stale socket file first. `close()`
    releases the descriptor but leaves the socket file in place. Remove
    it with the path's owner when the service is done.
    """

    var fd: c_int
    """The listening socket file descriptor."""
    var path: String
    """The bound socket path (or abstract name on Linux)."""
    var closed: Bool
    """True once the descriptor has been closed via `close()`."""

    def __init__(
        out self, path: StringSpan, *, remove_existing: Bool = False
    ) raises:
        """Binds and listens on a Unix domain socket path.

        Args:
            path: Filesystem path to bind; on Linux a NUL-prefixed name
                binds the abstract namespace instead.
            remove_existing: Unlink an existing socket file at `path`
                before binding (has no effect on abstract names).

        Raises:
            If the path is invalid, already bound, or socket creation,
            bind, or listen fails.
        """
        var packed = _pack_sockaddr_un(path)
        self.path = String(path)
        self.closed = False
        if remove_existing and not path.startswith(String(chr(0))):
            var p = self.path.copy()
            _ = c_unlink(p)
        self.fd = _new_tcp_socket(AF_UNIX)
        if c_bind(self.fd, packed[0].unsafe_ptr(), packed[1]) != 0:
            var err = os_error("bind " + self.path)
            _ = c_close(self.fd)
            self.closed = True
            raise err
        if c_listen(self.fd, 128) != 0:
            var err = os_error("listen")
            _ = c_close(self.fd)
            self.closed = True
            raise err

    def accept(self) raises -> UnixStream:
        """Blocks until a client connects, then returns its stream.

        Returns:
            The accepted connection as a `UnixStream`.

        Raises:
            If the accept call fails.
        """
        var sa = Array[UInt8, SOCKADDR_STORAGE_LEN](fill=0)
        var sa_len = c_int(SOCKADDR_STORAGE_LEN)
        var fd = c_accept(self.fd, sa.unsafe_ptr(), Pointer(to=sa_len))
        if fd < 0:
            raise os_error("accept")
        return UnixStream(stream=TCPStream(fd))

    def close(mut self):
        """Closes the listening socket; safe to call more than once.

        The socket file at `path` is left in place.
        """
        if not self.closed:
            _ = c_close(self.fd)
            self.closed = True

    def __deinit__(deinit self):
        """Closes the listening socket if `close()` was never called."""
        if not self.closed:
            _ = c_close(self.fd)
