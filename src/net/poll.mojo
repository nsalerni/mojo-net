# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""Readiness polling over kqueue (macOS) and epoll (Linux).

`Poller` watches file descriptors for readability and writability so a
single thread can serve many non-blocking sockets: register descriptors,
call `wait()`, act on the returned events, repeat. Mojo 1.0 has `async def`
syntax but no public async I/O runtime (`std.runtime._asyncrt` is private)
and no `std.thread`. `Poller` is a caller-driven event loop and needs
neither.

Platform notes handled here: kqueue reports read and write interest as two
separate filters (a descriptor registered for both can produce two events
per wait), while epoll merges them into one event; `struct epoll_event` is
packed to 12 bytes on x86-64 but padded to 16 bytes on other Linux
architectures; kqueue signals peer hangup with EV_EOF on the read filter,
epoll with EPOLLHUP/EPOLLRDHUP.
"""

from std.ffi import c_int, external_call
from std.sys import CompilationTarget

from .libc import c_close, os_error

# kqueue constants (macOS).
comptime _EVFILT_READ = -1
comptime _EVFILT_WRITE = -2
comptime _EV_ADD = 0x0001
comptime _EV_DELETE = 0x0002
comptime _EV_EOF = 0x8000
comptime _EV_ERROR = 0x4000
comptime _KEVENT_LEN = 32

# epoll constants (Linux).
comptime _EPOLL_CTL_ADD = 1
comptime _EPOLL_CTL_DEL = 2
comptime _EPOLL_CTL_MOD = 3
comptime _EPOLLIN = 0x001
comptime _EPOLLOUT = 0x004
comptime _EPOLLERR = 0x008
comptime _EPOLLHUP = 0x010
comptime _EPOLLRDHUP = 0x2000

comptime _MAX_EVENTS = 64


def _epoll_event_len() -> Int:
    """Returns sizeof(struct epoll_event) for the target (12 or 16)."""
    comptime if CompilationTarget.is_x86():
        return 12  # __attribute__((packed)) on x86-64
    else:
        return 16  # u32 events, 4 bytes padding, u64 data


@fieldwise_init
struct PollEvent(Copyable, Movable):
    """One readiness notification from `Poller.wait`.

    On kqueue a descriptor watched for both directions can appear in two
    events per wait (one per filter); on epoll it appears once with both
    flags set. Consumers should handle either shape.
    """

    var fd: c_int
    """The file descriptor the event is about."""
    var readable: Bool
    """A read (or accept) can make progress without blocking."""
    var writable: Bool
    """A write can make progress without blocking."""
    var hangup: Bool
    """The peer closed its end (EV_EOF / EPOLLHUP / EPOLLRDHUP)."""
    var error: Bool
    """The descriptor is in an error state; read/write to collect it."""


struct Poller(Movable):
    """An OS readiness queue: kqueue on macOS, epoll on Linux.

    Register descriptors with the interest you care about, then loop on
    `wait()`. Closing a registered descriptor removes it from the queue
    automatically on both platforms; `unregister` exists for removing
    interest in a descriptor that stays open.
    """

    var fd: c_int
    """The kqueue/epoll file descriptor."""
    var closed: Bool
    """True once the descriptor has been closed via `close()`."""

    def __init__(out self) raises:
        """Creates the readiness queue.

        Raises:
            If the kqueue/epoll_create1 call fails.
        """
        self.closed = False
        comptime if CompilationTarget.is_macos():
            self.fd = external_call["kqueue", c_int]()
            if self.fd < 0:
                raise os_error("kqueue")
        else:
            self.fd = external_call["epoll_create1", c_int](c_int(0))
            if self.fd < 0:
                raise os_error("epoll_create1")

    def _kevent_change(
        self, fd: c_int, filter: Int, flags: Int, tolerate_missing: Bool
    ) raises:
        # Applies one kqueue change; ENOENT on delete is tolerated so
        # interest toggles don't need to track prior state.
        var buf = Array[UInt8, _KEVENT_LEN](fill=0)
        var ident = UInt64(Int(fd))
        for i in range(8):
            buf[i] = UInt8((ident >> UInt64(8 * i)) & 0xFF)
        var f = UInt16(Int16(filter).cast[DType.uint16]())
        buf[8] = UInt8(f & 0xFF)
        buf[9] = UInt8((f >> 8) & 0xFF)
        buf[10] = UInt8(flags & 0xFF)
        buf[11] = UInt8((flags >> 8) & 0xFF)
        # All kevent call sites must share one FFI signature, so instead
        # of NULL pointers this passes valid dummy buffers with zero
        # counts (the kernel never reads them).
        var no_events = Array[UInt8, _KEVENT_LEN](fill=0)
        var ts = Array[UInt8, 16](fill=0)
        var rc = external_call["kevent", c_int](
            self.fd,
            buf.unsafe_ptr(),
            c_int(1),
            no_events.unsafe_ptr(),
            c_int(0),
            ts.unsafe_ptr(),
        )
        if rc < 0 and not tolerate_missing:
            raise os_error("kevent")

    def _epoll_ctl(self, op: Int, fd: c_int, events: Int) raises:
        var buf = Array[UInt8, 16](fill=0)
        var ev = UInt32(events)
        for i in range(4):
            buf[i] = UInt8((ev >> UInt32(8 * i)) & 0xFF)
        var data_off = 4 if _epoll_event_len() == 12 else 8
        var ident = UInt64(Int(fd))
        for i in range(8):
            buf[data_off + i] = UInt8((ident >> UInt64(8 * i)) & 0xFF)
        var rc = external_call["epoll_ctl", c_int](
            self.fd, c_int(op), fd, buf.unsafe_ptr()
        )
        if rc < 0:
            raise os_error("epoll_ctl")

    def _apply(
        self, fd: c_int, readable: Bool, writable: Bool, adding: Bool
    ) raises:
        comptime if CompilationTarget.is_macos():
            if readable:
                self._kevent_change(fd, _EVFILT_READ, _EV_ADD, False)
            else:
                self._kevent_change(fd, _EVFILT_READ, _EV_DELETE, True)
            if writable:
                self._kevent_change(fd, _EVFILT_WRITE, _EV_ADD, False)
            else:
                self._kevent_change(fd, _EVFILT_WRITE, _EV_DELETE, True)
        else:
            var events = _EPOLLRDHUP
            if readable:
                events |= _EPOLLIN
            if writable:
                events |= _EPOLLOUT
            self._epoll_ctl(
                _EPOLL_CTL_ADD if adding else _EPOLL_CTL_MOD, fd, events
            )

    def register(self, fd: c_int, *, readable: Bool, writable: Bool) raises:
        """Starts watching a descriptor for the given interests.

        Args:
            fd: The descriptor to watch.
            readable: Report when a read can make progress.
            writable: Report when a write can make progress.

        Raises:
            If the kernel rejects the registration.
        """
        self._apply(fd, readable, writable, True)

    def modify(self, fd: c_int, *, readable: Bool, writable: Bool) raises:
        """Changes the interests of an already-registered descriptor.

        Args:
            fd: The registered descriptor.
            readable: Report when a read can make progress.
            writable: Report when a write can make progress.

        Raises:
            If the kernel rejects the change.
        """
        self._apply(fd, readable, writable, False)

    def unregister(self, fd: c_int) raises:
        """Stops watching a descriptor.

        Closing a descriptor removes it implicitly; use this only when the
        descriptor stays open.

        Args:
            fd: The descriptor to stop watching.

        Raises:
            If the kernel rejects the removal (epoll only; kqueue treats a
            missing filter as already gone).
        """
        comptime if CompilationTarget.is_macos():
            self._kevent_change(fd, _EVFILT_READ, _EV_DELETE, True)
            self._kevent_change(fd, _EVFILT_WRITE, _EV_DELETE, True)
        else:
            self._epoll_ctl(_EPOLL_CTL_DEL, fd, 0)

    def wait(self, timeout_ms: Int) raises -> List[PollEvent]:
        """Blocks until at least one watched descriptor is ready.

        Args:
            timeout_ms: Longest time to wait in milliseconds; 0 polls
                without blocking, and a negative value waits indefinitely.

        Returns:
            The ready descriptors' events; empty if the timeout expired
            first.

        Raises:
            If the kernel wait call fails.
        """
        var out = List[PollEvent]()
        comptime if CompilationTarget.is_macos():
            var events = Array[UInt8, 2048](fill=0)  # 64 * 32 bytes
            var no_changes = Array[UInt8, _KEVENT_LEN](fill=0)
            # A negative timeout means "wait indefinitely"; kevent has no
            # -1 convention, so model it as a day-long timespec.
            var wait_ms = 86_400_000 if timeout_ms < 0 else timeout_ms
            var ts = Array[UInt8, 16](fill=0)  # timespec: i64 sec, i64 nsec
            var secs = UInt64(wait_ms // 1000)
            var nsecs = UInt64((wait_ms % 1000) * 1_000_000)
            for i in range(8):
                ts[i] = UInt8((secs >> UInt64(8 * i)) & 0xFF)
                ts[8 + i] = UInt8((nsecs >> UInt64(8 * i)) & 0xFF)
            var n = external_call["kevent", c_int](
                self.fd,
                no_changes.unsafe_ptr(),
                c_int(0),
                events.unsafe_ptr(),
                c_int(_MAX_EVENTS),
                ts.unsafe_ptr(),
            )
            if n < 0:
                raise os_error("kevent")
            for i in range(Int(n)):
                var base = i * _KEVENT_LEN
                var ident = UInt64(0)
                for b in range(8):
                    ident |= UInt64(events[base + b]) << UInt64(8 * b)
                # Compare the filter in the unsigned domain: EVFILT_READ
                # is -1 (0xFFFF as int16 bytes) and EVFILT_WRITE -2
                # (0xFFFE). Round-tripping through a signed cast here is
                # exactly the composed-cast pattern that miscompiles
                # (modular/modular#6935).
                var filt_raw = UInt16(events[base + 8]) | (
                    UInt16(events[base + 9]) << 8
                )
                var flags = UInt16(events[base + 10]) | (
                    UInt16(events[base + 11]) << 8
                )
                out.append(
                    PollEvent(
                        fd=c_int(Int(ident & 0xFFFFFFFF)),
                        readable=filt_raw == UInt16(0xFFFF),
                        writable=filt_raw == UInt16(0xFFFE),
                        hangup=(Int(flags) & _EV_EOF) != 0,
                        error=(Int(flags) & _EV_ERROR) != 0,
                    )
                )
        else:
            var elen = _epoll_event_len()
            var events = Array[UInt8, 1024](fill=0)  # 64 * up to 16 bytes
            var n = external_call["epoll_wait", c_int](
                self.fd,
                events.unsafe_ptr(),
                c_int(_MAX_EVENTS),
                c_int(timeout_ms),
            )
            if n < 0:
                raise os_error("epoll_wait")
            for i in range(Int(n)):
                var base = i * elen
                var bits = UInt32(0)
                for b in range(4):
                    bits |= UInt32(events[base + b]) << UInt32(8 * b)
                var data_off = base + (4 if elen == 12 else 8)
                var ident = UInt64(0)
                for b in range(8):
                    ident |= UInt64(events[data_off + b]) << UInt64(8 * b)
                out.append(
                    PollEvent(
                        fd=c_int(Int(ident & 0xFFFFFFFF)),
                        readable=(Int(bits) & _EPOLLIN) != 0,
                        writable=(Int(bits) & _EPOLLOUT) != 0,
                        hangup=(Int(bits) & (_EPOLLHUP | _EPOLLRDHUP)) != 0,
                        error=(Int(bits) & _EPOLLERR) != 0,
                    )
                )
        return out^

    def close(mut self):
        """Closes the readiness queue; safe to call more than once."""
        if not self.closed:
            _ = c_close(self.fd)
            self.closed = True

    def __deinit__(deinit self):
        """Closes the readiness queue if `close()` was never called."""
        if not self.closed:
            _ = c_close(self.fd)
