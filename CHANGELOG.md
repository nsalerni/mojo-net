# Changelog

## Unreleased

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
