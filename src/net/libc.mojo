# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""Socket bindings to libc for Mojo 1.0 via `std.ffi.external_call`.

Mojo 1.0 has no socket API in its standard library. This module is the
gap-filler and a candidate for upstreaming (see docs/PRIMITIVES.md).
Supports macOS and Linux; constants whose values differ between the two are
exposed as functions that select the right value at compile time. The
`sockaddr_in` layout difference (BSD `sin_len` byte) is handled in
address.mojo and sockaddr.mojo.

The `c_*` functions are thin syscall wrappers: they return the raw libc
result and never raise; callers check the result and raise via `os_error()`.
Constant values were verified against the macOS and Linux system headers.
"""

from std.ffi import external_call, c_int, c_ssize_t, get_errno
from std.sys import CompilationTarget


# --- Constants (verified against macOS and Linux headers) ---

comptime AF_INET = 2
"""Address family for IPv4 (same value on macOS and Linux)."""
comptime AF_UNIX = 1
"""Address family for Unix domain sockets (same value on macOS and Linux)."""
comptime AF_UNSPEC = 0
"""Unspecified address family; lets `getaddrinfo` return both v4 and v6."""
comptime SOCK_STREAM = 1
"""Stream socket type (TCP)."""
comptime SOCK_DGRAM = 2
"""Datagram socket type (UDP)."""
comptime SHUT_WR = 1
"""`shutdown(2)` mode that closes the write half of a connection."""


def af_inet6() -> Int:
    """Returns the platform's AF_INET6 address family value.

    The value differs by platform: 30 on macOS, 10 on Linux.

    Returns:
        The AF_INET6 constant for the compilation target.
    """
    comptime if CompilationTarget.is_macos():
        return 30
    else:
        return 10


def sol_socket() -> c_int:
    """Returns the platform's SOL_SOCKET option level for `setsockopt(2)`.

    Returns:
        0xFFFF on macOS, 1 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return c_int(0xFFFF)
    else:
        return c_int(1)


def so_reuseaddr() -> c_int:
    """Returns the platform's SO_REUSEADDR socket option name.

    Returns:
        0x0004 on macOS, 2 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return c_int(0x0004)
    else:
        return c_int(2)


def so_nosigpipe() -> c_int:
    """Returns the SO_NOSIGPIPE socket option name (macOS only).

    Suppresses SIGPIPE on writes to a closed peer. Linux has no such
    option and uses the MSG_NOSIGNAL send flag instead (see
    `msg_nosignal()`).

    Returns:
        The macOS SO_NOSIGPIPE value (0x1022).
    """
    return c_int(0x1022)


def msg_nosignal() -> c_int:
    """Returns the MSG_NOSIGNAL send flag, or 0 where it does not exist.

    On Linux this flag suppresses SIGPIPE when sending on a closed peer;
    macOS achieves the same via the SO_NOSIGPIPE socket option, so the
    flag is 0 there.

    Returns:
        0x4000 on Linux, 0 elsewhere.
    """
    comptime if CompilationTarget.is_linux():
        return c_int(0x4000)
    else:
        return c_int(0)


def so_rcvtimeo() -> c_int:
    """Returns the platform's SO_RCVTIMEO (receive timeout) option name.

    Returns:
        0x1006 on macOS, 20 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return c_int(0x1006)
    else:
        return c_int(20)


def so_sndtimeo() -> c_int:
    """Returns the platform's SO_SNDTIMEO (send timeout) option name.

    Returns:
        0x1005 on macOS, 21 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return c_int(0x1005)
    else:
        return c_int(21)


comptime IPPROTO_TCP = 6
"""Protocol level for TCP socket options (same value on macOS and Linux)."""
comptime TCP_NODELAY = 1
"""TCP option that disables Nagle's algorithm (same value on both OSes)."""
comptime F_GETFL = 3
"""`fcntl(2)` command that reads a descriptor's status flags."""
comptime F_SETFL = 4
"""`fcntl(2)` command that writes a descriptor's status flags."""
comptime F_SETFD = 2
"""`fcntl(2)` command that writes a descriptor's file-descriptor flags."""
comptime FD_CLOEXEC = 1
"""File-descriptor flag that closes the fd across `exec(2)`."""


def o_nonblock() -> c_int:
    """Returns the platform's O_NONBLOCK status flag.

    Returns:
        0x0004 on macOS, 0x800 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return c_int(0x0004)
    else:
        return c_int(0x800)


def so_error() -> c_int:
    """Returns the platform's SO_ERROR socket option name.

    Reading it fetches and clears a socket's pending error. This is how a
    non-blocking `connect(2)` reports its outcome once the socket polls
    writable.

    Returns:
        0x1007 on macOS, 4 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return c_int(0x1007)
    else:
        return c_int(4)


def einprogress() -> Int:
    """Returns the platform's EINPROGRESS errno value.

    A non-blocking `connect(2)` fails with this errno while the handshake
    is still underway; the socket becomes writable when it completes.

    Returns:
        36 on macOS, 115 on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return 36
    else:
        return 115


# --- errno ---


comptime TIMEOUT_ERROR = "net: timeout"
"""Message carried by every timeout `Error` raised in this package.

Raised when a blocking call exceeds a timeout set via SO_RCVTIMEO or
SO_SNDTIMEO. Check with `is_timeout_error()` rather than comparing strings
directly.
"""


comptime CONNECTION_REFUSED_ERROR = "net: connection refused"
"""Message carried when the peer has nothing listening.

Raised from `connect` when errno is `ECONNREFUSED`. Check with
`is_connection_refused()` rather than parsing "errno N".
"""


comptime CONNECTION_RESET_ERROR = "net: connection reset"
"""Message carried when the peer reset or closed the connection.

Raised when errno is `ECONNRESET` or `EPIPE`. Check with
`is_connection_reset()` rather than parsing "errno 104".
"""


def os_error(var context: String) -> Error:
    """Builds an `Error` from the current errno, mapping common cases.

    Timeouts (`EAGAIN`/`EWOULDBLOCK` after `SO_RCVTIMEO`/`SO_SNDTIMEO`)
    become `TIMEOUT_ERROR`. `ECONNREFUSED` becomes
    `CONNECTION_REFUSED_ERROR`. `ECONNRESET` and `EPIPE` become
    `CONNECTION_RESET_ERROR`. All other errno values produce
    "context: errno N".

    Call this immediately after the failing libc call, before anything else
    can overwrite errno.

    Args:
        context: Label for the failing operation, e.g. "recv" or "bind".

    Returns:
        An `Error` describing the failure.
    """
    var e = get_errno()
    var code = e.value
    comptime if CompilationTarget.is_macos():
        if code == 35:  # EAGAIN == EWOULDBLOCK
            return Error(TIMEOUT_ERROR)
        if code == 61:  # ECONNREFUSED
            return Error(CONNECTION_REFUSED_ERROR)
        if code == 54 or code == 32:  # ECONNRESET, EPIPE
            return Error(CONNECTION_RESET_ERROR)
    else:
        if code == 11:  # EAGAIN/EWOULDBLOCK
            return Error(TIMEOUT_ERROR)
        if code == 111:  # ECONNREFUSED
            return Error(CONNECTION_REFUSED_ERROR)
        if code == 104 or code == 32:  # ECONNRESET, EPIPE
            return Error(CONNECTION_RESET_ERROR)
    return Error(context + ": errno " + String(code))


comptime WOULD_BLOCK_ERROR = "net: would block"
"""Message carried by every would-block `Error` raised in this package.

Raised when an operation on a socket in non-blocking mode cannot proceed
without waiting. Check with `is_would_block()` rather than comparing
strings directly, and use a `Poller` to learn when to retry.
"""


def is_would_block(e: Error) -> Bool:
    """Reports whether an error means "retry when the socket is ready".

    True exactly when a read or write on a socket placed in non-blocking
    mode (`set_nonblocking(True)`) could not proceed immediately.

    Args:
        e: The error to inspect.

    Returns:
        True if the error is the typed `WOULD_BLOCK_ERROR`.
    """
    return String(e) == WOULD_BLOCK_ERROR


def is_timeout_error(e: Error) -> Bool:
    """Reports whether an error is a socket timeout.

    True exactly when the error was produced by `os_error()` for an
    EAGAIN/EWOULDBLOCK failure, i.e. a read or write deadline set with
    `set_read_timeout`/`set_write_timeout` expired.

    Args:
        e: The error to inspect.

    Returns:
        True if the error is the typed `TIMEOUT_ERROR`.
    """
    return String(e) == TIMEOUT_ERROR


def is_connection_refused(e: Error) -> Bool:
    """Reports whether an error is a refused TCP or Unix connect.

    Args:
        e: The error to inspect.

    Returns:
        True if the error is the typed `CONNECTION_REFUSED_ERROR`.
    """
    return String(e) == CONNECTION_REFUSED_ERROR


def is_connection_reset(e: Error) -> Bool:
    """Reports whether an error is a peer reset or broken pipe.

    Args:
        e: The error to inspect.

    Returns:
        True if the error is the typed `CONNECTION_RESET_ERROR`.
    """
    return String(e) == CONNECTION_RESET_ERROR


# --- Thin syscall wrappers (return raw results; callers check and raise) ---


def c_socket(domain: Int, sock_type: Int, protocol: Int) -> c_int:
    """Calls `socket(2)` to create an unbound socket.

    Args:
        domain: Address family, e.g. `AF_INET` or `af_inet6()`.
        sock_type: Socket type, `SOCK_STREAM` or `SOCK_DGRAM`.
        protocol: Protocol number; 0 selects the type's default.

    Returns:
        A file descriptor on success, or a negative value on failure
        (errno is set).
    """
    return external_call["socket", c_int](
        c_int(domain), c_int(sock_type), c_int(protocol)
    )


def c_bind(fd: c_int, addr: ImmPointer[UInt8, _], addr_len: Int) -> c_int:
    """Calls `bind(2)` to assign a local address to a socket.

    Args:
        fd: The socket file descriptor.
        addr: Pointer to a packed `sockaddr` buffer.
        addr_len: Length in bytes of the sockaddr data.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["bind", c_int](fd, addr, c_int(addr_len))


def c_listen(fd: c_int, backlog: Int) -> c_int:
    """Calls `listen(2)` to mark a socket as accepting connections.

    Args:
        fd: The socket file descriptor.
        backlog: Maximum length of the pending-connection queue.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["listen", c_int](fd, c_int(backlog))


def c_accept(
    fd: c_int, addr: MutPointer[UInt8, _], addr_len: MutPointer[c_int, _]
) -> c_int:
    """Calls `accept(2)` to take the next connection off the listen queue.

    Blocks until a connection arrives.

    Args:
        fd: The listening socket file descriptor.
        addr: Output buffer that receives the peer's sockaddr.
        addr_len: In: capacity of `addr`; out: actual sockaddr length.

    Returns:
        The connected socket's file descriptor, or a negative value on
        failure (errno is set).
    """
    return external_call["accept", c_int](fd, addr, addr_len)


def c_connect(fd: c_int, addr: ImmPointer[UInt8, _], addr_len: Int) -> c_int:
    """Calls `connect(2)` to establish a connection on a socket.

    Blocks until the connection completes or fails.

    Args:
        fd: The socket file descriptor.
        addr: Pointer to the peer's packed `sockaddr` buffer.
        addr_len: Length in bytes of the sockaddr data.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["connect", c_int](fd, addr, c_int(addr_len))


def c_send(
    fd: c_int, buf: ImmPointer[UInt8, _], length: Int, flags: c_int
) -> Int:
    """Calls `send(2)` to transmit bytes on a connected socket.

    May send fewer than `length` bytes; callers loop (see
    `TCPStream.write_all`).

    Args:
        fd: The socket file descriptor.
        buf: Pointer to the bytes to send.
        length: Number of bytes to send.
        flags: Send flags, e.g. `msg_nosignal()`.

    Returns:
        The number of bytes sent, or a negative value on failure
        (errno is set).
    """
    return Int(external_call["send", Int](fd, buf, length, flags))


def c_recv(
    fd: c_int, buf: MutPointer[UInt8, _], length: Int, flags: c_int
) -> Int:
    """Calls `recv(2)` to receive bytes from a connected socket.

    Blocks until data is available (or a configured receive timeout
    expires).

    Args:
        fd: The socket file descriptor.
        buf: Output buffer for the received bytes.
        length: Capacity of `buf` in bytes.
        flags: Receive flags (normally 0).

    Returns:
        The number of bytes received, 0 on orderly EOF, or a negative
        value on failure (errno is set).
    """
    return Int(external_call["recv", Int](fd, buf, length, flags))


def c_ioctl_fionread(fd: c_int) -> Int:
    """Reports the bytes available to read without blocking (ioctl FIONREAD).

    The FIONREAD request code differs by platform (0x4004667F on macOS,
    0x541B on Linux).

    Args:
        fd: The socket file descriptor.

    Returns:
        The number of readable bytes, or 0 if the ioctl fails.
    """
    var n = c_int(0)
    var fionread: UInt64
    comptime if CompilationTarget.is_macos():
        fionread = 0x4004667F
    else:
        fionread = 0x541B
    var rc = external_call["ioctl", c_int, num_fixed_args=2](
        fd, fionread, Pointer(to=n)
    )
    if rc != 0:
        return 0
    return Int(n)


def c_close(fd: c_int) -> c_int:
    """Calls `close(2)` to release a file descriptor.

    Args:
        fd: The file descriptor to close.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["close", c_int](fd)


def c_shutdown(fd: c_int, how: Int) -> c_int:
    """Calls `shutdown(2)` to disable sends and/or receives on a socket.

    Args:
        fd: The socket file descriptor.
        how: Which half to shut down, e.g. `SHUT_WR`.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["shutdown", c_int](fd, c_int(how))


def c_setsockopt_int(fd: c_int, level: c_int, name: c_int, value: Int) -> c_int:
    """Calls `setsockopt(2)` with a 4-byte integer option value.

    Args:
        fd: The socket file descriptor.
        level: Option level, e.g. `sol_socket()` or `IPPROTO_TCP`.
        name: Option name, e.g. `so_reuseaddr()` or `TCP_NODELAY`.
        value: The integer option value (passed as a C int).

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    var v = c_int(value)
    return external_call["setsockopt", c_int](
        fd, level, name, Pointer(to=v), c_int(4)
    )


def c_getsockname(
    fd: c_int, addr: MutPointer[UInt8, _], addr_len: MutPointer[c_int, _]
) -> c_int:
    """Calls `getsockname(2)` to read a socket's bound local address.

    Useful for recovering the actual port after binding to port 0.

    Args:
        fd: The socket file descriptor.
        addr: Output buffer that receives the local sockaddr.
        addr_len: In: capacity of `addr`; out: actual sockaddr length.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["getsockname", c_int](fd, addr, addr_len)


def c_getpeername(
    fd: c_int, addr: MutPointer[UInt8, _], addr_len: MutPointer[c_int, _]
) -> c_int:
    """Calls `getpeername(2)` to read a connected socket's peer address.

    Args:
        fd: The connected socket file descriptor.
        addr: Output buffer that receives the peer sockaddr.
        addr_len: In: capacity of `addr`; out: actual sockaddr length.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["getpeername", c_int](fd, addr, addr_len)


def _checked_sockaddr_len(
    length: Int, minimum: Int, capacity: Int, context: StringSpan
) raises -> Int:
    """Validates a sockaddr length returned by the kernel."""
    if length < minimum:
        raise Error(
            "net: " + String(context) + " returned a short socket address"
        )
    if length > capacity:
        raise Error(
            "net: " + String(context) + " exceeded the address buffer"
        )
    return length


def c_setsockopt_timeval(
    fd: c_int, level: c_int, name: c_int, nanos: Int64
) -> c_int:
    """Calls `setsockopt(2)` with a `struct timeval` payload.

    Used for SO_RCVTIMEO/SO_SNDTIMEO. The struct is 16 bytes on both
    supported OSes but laid out differently: macOS packs i64 tv_sec +
    i32 tv_usec + 4 bytes padding; Linux packs i64 tv_sec + i64 tv_usec.
    Both are little-endian on the supported targets.

    Args:
        fd: The socket file descriptor.
        level: Option level, normally `sol_socket()`.
        name: Option name, `so_rcvtimeo()` or `so_sndtimeo()`.
        nanos: Timeout in nanoseconds; truncated to microsecond
            resolution. 0 clears the timeout.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    var buf = Array[UInt8, 16](fill=0)
    var secs = UInt64(nanos // 1_000_000_000)
    var usecs = UInt64((nanos % 1_000_000_000) // 1000)
    for i in range(8):
        buf[i] = UInt8((secs >> UInt64(8 * i)) & 0xFF)
    comptime if CompilationTarget.is_macos():
        for i in range(4):
            buf[8 + i] = UInt8((usecs >> UInt64(8 * i)) & 0xFF)
    else:
        for i in range(8):
            buf[8 + i] = UInt8((usecs >> UInt64(8 * i)) & 0xFF)
    return external_call["setsockopt", c_int](
        fd, level, name, buf.unsafe_ptr(), c_int(16)
    )


def c_sendto(
    fd: c_int,
    buf: ImmPointer[UInt8, _],
    length: Int,
    flags: c_int,
    addr: ImmPointer[UInt8, _],
    addr_len: Int,
) -> Int:
    """Calls `sendto(2)` to transmit one datagram to an explicit address.

    Args:
        fd: The socket file descriptor.
        buf: Pointer to the datagram payload.
        length: Payload length in bytes.
        flags: Send flags (normally 0).
        addr: Pointer to the destination's packed `sockaddr` buffer.
        addr_len: Length in bytes of the sockaddr data.

    Returns:
        The number of bytes sent, or a negative value on failure
        (errno is set).
    """
    return Int(
        external_call["sendto", Int](
            fd, buf, length, flags, addr, c_int(addr_len)
        )
    )


def c_recvfrom(
    fd: c_int,
    buf: MutPointer[UInt8, _],
    length: Int,
    flags: c_int,
    addr: MutPointer[UInt8, _],
    addr_len: MutPointer[c_int, _],
) -> Int:
    """Calls `recvfrom(2)` to receive one datagram and its sender address.

    Blocks until a datagram arrives (or a configured receive timeout
    expires). A datagram larger than `length` is truncated.

    Args:
        fd: The socket file descriptor.
        buf: Output buffer for the datagram payload.
        length: Capacity of `buf` in bytes.
        flags: Receive flags (normally 0).
        addr: Output buffer that receives the sender's sockaddr.
        addr_len: In: capacity of `addr`; out: actual sockaddr length.

    Returns:
        The number of bytes received, or a negative value on failure
        (errno is set).
    """
    return Int(
        external_call["recvfrom", Int](fd, buf, length, flags, addr, addr_len)
    )


def c_pipe(fds: MutPointer[c_int, _]) -> c_int:
    """Calls `pipe(2)` to create a connected pair of file descriptors.

    `fds` must point at two contiguous `c_int` values. On success they
    receive the read end and the write end, in that order.

    Args:
        fds: Output array of two integers.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["pipe", c_int](fds)


def c_read(fd: c_int, buf: MutPointer[UInt8, _], length: Int) -> Int:
    """Calls `read(2)` to receive bytes from a descriptor.

    Args:
        fd: The file descriptor.
        buf: Output buffer for the received bytes.
        length: Capacity of `buf` in bytes.

    Returns:
        The number of bytes read, 0 on orderly EOF, or a negative value
        on failure (errno is set).
    """
    return Int(
        external_call["read", c_ssize_t](Int(fd), buf, length)
    )


def c_write(fd: c_int, buf: ImmPointer[UInt8, _], length: Int) -> Int:
    """Calls `write(2)` to send bytes to a descriptor.

    This is the POSIX `write`, not `send(2)`. Use it on pipes; it is the
    only I/O call that is async-signal-safe.

    Args:
        fd: The file descriptor.
        buf: Pointer to the bytes to send.
        length: Number of bytes to send.

    Returns:
        The number of bytes written, or a negative value on failure
        (errno is set).
    """
    return Int(
        external_call["write", c_ssize_t](Int(fd), buf, length)
    )


def errno_is_eagain() -> Bool:
    """Reports whether the current errno is `EAGAIN`/`EWOULDBLOCK`.

    Call immediately after a failing libc operation, before anything else
    can overwrite errno.

    Returns:
        True when a non-blocking operation would have blocked.
    """
    var code = get_errno().value
    comptime if CompilationTarget.is_macos():
        return code == 35
    else:
        return code == 11


def c_fcntl(fd: c_int, cmd: Int, arg: Int) -> c_int:
    """Calls `fcntl(2)` with an integer argument.

    Args:
        fd: The file descriptor.
        cmd: The fcntl command, e.g. `F_GETFL` or `F_SETFL`.
        arg: The command's integer argument (0 for F_GETFL).

    Returns:
        The command's result (the flags for F_GETFL, 0 for F_SETFL), or a
        negative value on failure (errno is set).
    """
    return external_call["fcntl", c_int, num_fixed_args=2](
        fd, c_int(cmd), c_int(arg)
    )


def c_getsockopt_int(
    fd: c_int, level: c_int, name: c_int, value: MutPointer[c_int, _]
) -> c_int:
    """Calls `getsockopt(2)` for a 4-byte integer option value.

    Args:
        fd: The socket file descriptor.
        level: Option level, e.g. `sol_socket()`.
        name: Option name, e.g. `so_error()`.
        value: Output location for the option value.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    var optlen = c_int(4)
    return external_call["getsockopt", c_int](
        fd, level, name, value, Pointer(to=optlen)
    )


def c_unlink(mut path: String) -> c_int:
    """Calls `unlink(2)` to remove a filesystem entry (e.g. a socket file).

    Args:
        path: The path to remove. Mutable only because passing a C string
            requires it.

    Returns:
        0 on success, -1 on failure (errno is set).
    """
    return external_call["unlink", c_int](path.as_c_string_slice())


comptime S_IFMT = 0xF000
"""`stat(2)` file-type mask. Same value on macOS and Linux."""
comptime S_IFSOCK = 0xC000
"""`stat(2)` socket file type. Same value on macOS and Linux."""
comptime ENOENT = 2
"""`errno` for a missing path. Same value on macOS and Linux."""


def c_lstat_is_socket(mut path: String) -> c_int:
    """Calls `lstat(2)` and reports whether `path` is a Unix socket.

    `struct stat` is large and platform-specific; only `st_mode` is read.
    On macOS it is a 16-bit field at offset 4. On Linux it is a 32-bit
    field at offset 24.

    Args:
        path: Filesystem path to inspect. Mutable only because passing a
            C string requires it.

    Returns:
        1 if the path is a socket, 0 if it exists and is not a socket,
        -1 if the path does not exist, -2 if `lstat` failed for another
        reason (errno is set).
    """
    var buf = Array[UInt8, 256](fill=0)
    if (
        external_call["lstat", c_int](path.as_c_string_slice(), buf.unsafe_ptr())
        != 0
    ):
        if get_errno().value == ENOENT:
            return -1
        return -2
    comptime if CompilationTarget.is_macos():
        var mode = UInt32(buf[4]) | (UInt32(buf[5]) << 8)
        if (mode & UInt32(S_IFMT)) == UInt32(S_IFSOCK):
            return 1
        return 0
    else:
        var mode = (
            UInt32(buf[24])
            | (UInt32(buf[25]) << 8)
            | (UInt32(buf[26]) << 16)
            | (UInt32(buf[27]) << 24)
        )
        if (mode & UInt32(S_IFMT)) == UInt32(S_IFSOCK):
            return 1
        return 0


def c_inet_pton(af: Int, mut src: String, dst: MutPointer[UInt8, _]) -> c_int:
    """Calls `inet_pton(3)` to parse a numeric IP literal into binary form.

    Args:
        af: Address family, `AF_INET` or `af_inet6()`.
        src: The numeric address string, e.g. "127.0.0.1" or "::1".
            Mutable only because passing a C string requires it.
        dst: Output buffer for the binary address (4 bytes for v4,
            16 for v6).

    Returns:
        1 if the string parsed, 0 if it is not a valid literal for the
        family, -1 if the family is unsupported.
    """
    return external_call["inet_pton", c_int](
        c_int(af), src.as_c_string_slice(), dst
    )
