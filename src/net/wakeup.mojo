# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""A self-pipe that can wake a blocked `Poller.wait`.

Mojo 1.0 has no threads and no public async runtime, so an event loop that
sits in `Poller.wait` has no other way to notice an out-of-band stop
request. `Wakeup` is the POSIX self-pipe pattern: `notify()` writes one
byte with `write(2)`, and the read end is registered with `Poller`. A C
`sigaction` handler can call `write(2)` on `write_fd` because that syscall
is async-signal-safe. This is not an async runtime and is not safe to
drive from another Mojo thread, because there is no thread API.
"""

from std.ffi import c_int

from .libc import (
    FD_CLOEXEC,
    F_GETFL,
    F_SETFD,
    F_SETFL,
    c_close,
    c_fcntl,
    c_pipe,
    c_read,
    c_write,
    errno_is_eagain,
    o_nonblock,
    os_error,
)


def _set_cloexec_nonblock(fd: c_int) raises:
    if c_fcntl(fd, F_SETFD, FD_CLOEXEC) < 0:
        raise os_error("fcntl")
    var flags = c_fcntl(fd, F_GETFL, 0)
    if flags < 0:
        raise os_error("fcntl")
    if c_fcntl(fd, F_SETFL, Int(flags) | Int(o_nonblock())) < 0:
        raise os_error("fcntl")


struct Wakeup(Movable):
    """A pipe whose read end can wake a `Poller`.

    Create one, register `descriptor()` for readability, then call
    `notify()` (or `write(2)` on `write_fd` from a C signal handler).
    `drain()` consumes pending bytes so the next wait blocks again.
    """

    var read_fd: c_int
    """The pipe's read end; register this with `Poller`."""
    var write_fd: c_int
    """The pipe's write end; `notify()` and signal handlers write here."""
    var closed: Bool
    """True once both ends have been closed via `close()`."""

    def __init__(out self) raises:
        """Creates a non-blocking, close-on-exec pipe.

        Raises:
            If `pipe(2)` or the subsequent `fcntl` calls fail.
        """
        var fds = Array[c_int, 2](fill=c_int(-1))
        if c_pipe(fds.unsafe_ptr()) < 0:
            raise os_error("pipe")
        self.read_fd = fds[0]
        self.write_fd = fds[1]
        self.closed = False
        try:
            _set_cloexec_nonblock(self.read_fd)
            _set_cloexec_nonblock(self.write_fd)
        except e:
            _ = c_close(self.read_fd)
            _ = c_close(self.write_fd)
            self.closed = True
            raise e

    def descriptor(self) -> c_int:
        """Returns the read end to register with `Poller`.

        Returns:
            The owned pipe read descriptor.
        """
        return self.read_fd

    def notify(self):
        """Writes one byte to wake a waiter.

        Uses only `write(2)`. Failures, including `EAGAIN` when the pipe
        is already full of pending wakeups, are ignored so a signal
        handler can call this without recovering from errors. A closed
        wakeup is a no-op.
        """
        if self.closed:
            return
        var buf = Array[UInt8, 1](fill=1)
        _ = c_write(self.write_fd, buf.unsafe_ptr(), 1)

    def drain(self) raises:
        """Reads pending wakeup bytes until the pipe is empty.

        Call this after `Poller.wait` reports the read end readable, so
        the next wait can block again.

        Raises:
            If `read(2)` fails for a reason other than `EAGAIN`, or if the
            write end has been closed.
        """
        if self.closed:
            raise Error("net: wakeup is closed")
        var buf = Array[UInt8, 64](fill=0)
        while True:
            var n = c_read(self.read_fd, buf.unsafe_ptr(), 64)
            if n > 0:
                continue
            if n == 0:
                raise Error("net: wakeup pipe closed")
            if errno_is_eagain():
                return
            raise os_error("read")

    def close(mut self):
        """Closes both pipe ends; safe to call more than once."""
        if not self.closed:
            _ = c_close(self.read_fd)
            _ = c_close(self.write_fd)
            self.closed = True

    def __deinit__(deinit self):
        """Closes both pipe ends if `close()` was never called."""
        if not self.closed:
            _ = c_close(self.read_fd)
            _ = c_close(self.write_fd)
