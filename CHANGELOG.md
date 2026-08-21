# Changelog

## Unreleased

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
