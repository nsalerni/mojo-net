# Changelog

## 0.1.0 — 2026-08-19

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
