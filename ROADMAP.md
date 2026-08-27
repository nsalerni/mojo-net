# Roadmap

Shipped work lives in [CHANGELOG.md](CHANGELOG.md).

## Open

These are not blocked on Mojo 1.0 or another package:

- Unix datagram sockets (`SOCK_DGRAM`), if a consumer needs them. UDP and
  Unix stream sockets already exist; datagram Unix is the remaining socket
  kind and is optional until a caller asks for it.

## Blocked

- **Async/await adapters on `Poller`.** Mojo 1.0 has `async def` syntax, but
  the task runtime (`std.runtime._asyncrt`) is private and marked unstable.
  Homemade futures are out of scope. `Poller` stays a caller-driven
  kqueue/epoll reactor until Modular ships a public async I/O runtime that
  a thin adapter can sit on.

TLS is a sibling package: [mojo-tls](https://github.com/nsalerni/mojo-tls).
Anything above the socket layer belongs there or in the protocol package
that uses `IOStream`.
