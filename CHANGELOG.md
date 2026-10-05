# Changelog

## Unreleased

- Blocking `recv`, `send`, `accept`, `sendto`, and `recvfrom` retry when
  a signal interrupts them. `Poller.wait` retries with the time still
  left on its deadline. An interrupted blocking `connect` waits until
  the socket is writable and reads `SO_ERROR`, instead of calling
  `connect` again. `close` is not retried. A retried receive or send
  starts its socket timeout over.
- `IPv4Address` rejects octets with a leading zero (`01.2.3.4`,
  `010.0.0.1`), matching `inet_pton` and `SocketAddress.parse`.
  `inet_aton` reads such octets as octal, so one string could name two
  hosts.
- `set_read_timeout` and `set_write_timeout` round a positive timeout
  below one microsecond up to one microsecond. It was truncated to a
  zero `timeval`, which the kernel reads as "no timeout", so the socket
  blocked forever.

## 0.2.7 - 2026-09-21

- `UnixListener(..., remove_existing=True)` unlinks only an existing
  socket file. A regular file at the bind path is left in place and the
  bind fails with a typed error. Uses the Linux aarch64 `st_mode` offset.
  The `lstat`/`unlink` pair is not atomic; see SECURITY.md.

## 0.2.6 - 2026-09-03

- Added `Wakeup`, a POSIX self-pipe that can wake a blocked
  `Poller.wait`. `notify()` writes one byte with `write(2)` so a C
  signal handler can use the same write end. `drain()` consumes pending
  bytes. This is not an async runtime and is not a cross-thread API.

## 0.2.5 - 2026-09-03

- Added `set_write_timeout` to `IOStream` so protocol layers can bound
  blocking writes through the trait. `TCPStream` and `UnixStream` already
  implement it. This is a source break for custom `IOStream` types: they
  must add `set_write_timeout`; there is no default implementation.
- Documented that Unix datagram sockets are optional future work, and that
  async/await adapters on `Poller` wait on a public Mojo async I/O runtime.

## 0.2.4 - 2026-08-26

- Documented the blocking vs `Poller` concurrency contract, and that IPv6
  `::` dual-stack behavior is OS-dependent.
- Maps `ECONNREFUSED` to `CONNECTION_REFUSED_ERROR` and `ECONNRESET` /
  `EPIPE` to `CONNECTION_RESET_ERROR`. Check with `is_connection_refused()`
  and `is_connection_reset()` instead of parsing "errno N".
- Added `write_some` to `IOStream` so protocol layers can recover after a
  partial write. `TCPStream` and `UnixStream` already implement it. This
  is a source break for custom `IOStream` types: they must add
  `write_some`; there is no default implementation.
- `TCPStream.connect` and `connect_addr` accept `timeout_ns` so a connect
  cannot hang for the kernel default. The Poller wait is converted with
  overflow-safe ceiling division and clamped to `epoll_wait`'s range.
  Expiry is the typed `TIMEOUT_ERROR`.
- `UnixListener` now exposes `descriptor()` and `set_nonblocking()` so
  servers can drain pending connections through `Poller`. Accepted
  streams inherit the listener's logical blocking mode.
- Shortened the README and added contributor, issue, and pull-request
  templates.
- Removed a stray duplicate `unix.mojo` from the repository root.
- Accepted TCP streams now inherit the listener's logical blocking mode on
  macOS and Linux.
- Added local and peer endpoint inspection for connected TCP and Unix domain
  streams, including IPv4 and IPv6 ports plus Linux abstract names.

## 0.2.2 - 2026-08-22

- Added `TCPListener.descriptor()` and `set_nonblocking()` so servers can
  drain pending connections through `Poller` without changing the blocking
  default.
- Extended the CPython differential to release 20 clients together and verify
  that the listener drains the accept queue to a typed would-block result.

## 0.2.1 - 2026-08-21

- Added `ReadinessStream`, a pollable non-blocking partial-I/O trait shared by
  `TCPStream` and `UnixStream` without changing the blocking `IOStream` API.
- Added Unix partial writes and trait-generic TCP and Unix differential checks
  against CPython sockets.

## 0.2.0 - 2026-08-20

- Added `UnixListener` and `UnixStream`, including Linux abstract namespace
  addresses.
- Added nonblocking socket operations and `Poller` readiness polling over
  kqueue on macOS and epoll on Linux.
- Introduced the `IOStream` trait so protocol packages can share TCP, Unix,
  and secure stream implementations.
- Package builds now produce an installed `net.mojoc` module with a strict
  Mojo 1.0 compiler bound and a clean consumer compilation gate.

## 0.1.0 - 2026-08-19

Initial release.

- Blocking TCP (`TCPListener`, `TCPStream`) with hostname resolution,
  read/write timeouts surfaced as a typed timeout error, half-close,
  `TCP_NODELAY`, `bytes_available()`, and SIGPIPE suppression.
- `UDPSocket` with `send_to` / `recv_from` and read timeouts.
- `SocketAddress`: IPv4 + IPv6 with platform `sockaddr` coding
  (macOS `sin_len` vs Linux `sa_family`), v6 scope ids.
- `resolve()` via `getaddrinfo(3)` with platform `addrinfo` layouts.
- Differential compatibility suite vs CPython sockets; loopback
  benchmarks; macOS (arm64) and Linux (x86-64/arm64).
