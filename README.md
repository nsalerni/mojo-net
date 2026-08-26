# mojo-net

[![CI](https://github.com/nsalerni/mojo-net/actions/workflows/ci.yml/badge.svg)](https://github.com/nsalerni/mojo-net/actions/workflows/ci.yml)
[![CPython socket checks](https://img.shields.io/endpoint?url=https%3A%2F%2Fnsalerni.github.io%2Fmojo-net%2Fcompliance-badge.json)](https://nsalerni.github.io/mojo-net/COMPLIANCE.html)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

TCP, UDP, DNS, Unix sockets, and readiness polling for **Mojo 1.0**. Built on
libc because the standard library has no socket API yet.

**[Compliance report](https://nsalerni.github.io/mojo-net/COMPLIANCE.html)**
([Markdown](COMPLIANCE.md)) is regenerated on every CI run.

## Install

```sh
curl -fsSL https://pixi.sh/install.sh | sh
git clone https://github.com/nsalerni/mojo-net.git
cd mojo-net
pixi install
pixi run test
pixi run example
```

Depends only on the Mojo standard library. A conda recipe lives in
[`recipe/`](recipe/).

## Example

```mojo
from net import TCPListener, TCPStream

def main() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    print("local: ", client.local_address())
    print("peer:  ", client.peer_address())
    client.close()
    server_side.close()
    listener.close()
```

Runnable examples:

| File | Command |
|---|---|
| [tcp_blocking_echo.mojo](examples/tcp_blocking_echo.mojo) | `pixi run example` (runs all four) |
| [udp_dns_echo.mojo](examples/udp_dns_echo.mojo) | |
| [tcp_poller_echo.mojo](examples/tcp_poller_echo.mojo) | |
| [unix_socket_echo.mojo](examples/unix_socket_echo.mojo) | |

See [examples/README.md](examples/README.md).

## Features

- `TCPListener` / `TCPStream` — timeouts, half-close, `TCP_NODELAY`, addresses
- `UDPSocket` — `send_to` / `recv_from`
- `UnixListener` / `UnixStream` — filesystem paths and Linux abstract names
- `Poller` — kqueue (macOS) and epoll (Linux)
- `ReadinessStream` — non-blocking reads and partial writes
- `resolve()` — `getaddrinfo` for IPv4 and IPv6

Platforms: macOS (arm64) and Linux (x86-64, arm64).

TLS lives in [mojo-tls](https://github.com/nsalerni/mojo-tls).

## Compliance

Checked against CPython's `socket` module. Current results:
[COMPLIANCE.md](COMPLIANCE.md).

```sh
pixi run compliance
```

## Related packages

[mojo-tls](https://github.com/nsalerni/mojo-tls) ·
[mojo-http2](https://github.com/nsalerni/mojo-http2) ·
[grpc-mojo](https://github.com/nsalerni/grpc-mojo)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Remaining work is in
[ROADMAP.md](ROADMAP.md).

## License

[Apache-2.0](LICENSE). Not affiliated with Modular; "Mojo" is a trademark of
Modular Inc.
