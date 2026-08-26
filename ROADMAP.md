# Roadmap

Shipped work lives in [CHANGELOG.md](CHANGELOG.md).

## Open

- Unix datagram sockets, if a consumer needs them
- Async/await adapters on top of `Poller`, once Mojo's public async I/O
  story settles

TLS is a sibling package: [mojo-tls](https://github.com/nsalerni/mojo-tls).
Anything above the socket layer belongs there or in the protocol package
that uses `IOStream`.
