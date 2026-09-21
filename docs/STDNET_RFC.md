# RFC: `std.net` for Mojo 1.0

**Working prototype:** [mojo-net](https://github.com/nsalerni/mojo-net)
**Status:** community package today; propose a minimal core for the
standard library
**Audience:** Modular stdlib maintainers and anyone currently binding
`socket()` via `std.ffi`

## Problem

Mojo 1.0 has `std.io.FileDescriptor` but no `socket()`, no address types,
and no TCP API. Community projects each carry their own libc bindings
(sockaddr layout, `addrinfo` field order, kqueue vs epoll). That
duplicates platform bugs and splits the ecosystem.

## Proposal

Land a small `std.net` with the shapes mojo-net already ships and tests
against CPython `socket` (15/15):

- `SocketAddress` — IPv4 and IPv6, including DNS via `resolve()`
- `TCPListener` / `TCPStream` — listen, accept, connect, read/write,
  half-close, `TCP_NODELAY`, read/write/connect timeouts
- Typed errno errors (`TIMEOUT`, `WOULD_BLOCK`, `CONNECTION_REFUSED`,
  `CONNECTION_RESET`) instead of parsing `"errno N"`

Keep the first stdlib surface small. Leave these in the community
package until the core is accepted:

- UDP
- Unix domain sockets
- `Poller` (kqueue/epoll) and `Wakeup`
- `IOStream` / `ReadinessStream` traits used by mojo-tls and mojo-http2

## Non-goals

- An async runtime. `Poller` stays caller-driven until Modular ships a
  public async I/O API. Homemade futures are out of scope.
- TLS. That is [mojo-tls](https://github.com/nsalerni/mojo-tls) over
  libssl.
- Windows. Mojo 1.0 platforms here are macOS arm64 and Linux.

## Evidence

mojo-net is the socket layer under mojo-tls, mojo-http2, and grpc-mojo.
grpc-mojo passes the official gRPC interop suite 84/84 over h2c, TLS,
and Unix sockets. The API is Go-`net`-shaped on purpose.

## Ask

1. Treat mojo-net as the working prototype for a `std.net` design thread.
2. Review the minimal core above; we will send a stdlib PR once the
   shape is agreed.
3. HTTP frameworks (lightbug and others) should depend on this layer
   rather than rebinding libc.

Prototype docs: [README.md](../README.md), [COMPLIANCE.md](../COMPLIANCE.md).
