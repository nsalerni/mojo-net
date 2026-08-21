# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""Blocking TCP/UDP sockets, DNS resolution, and IPv4/IPv6 addressing for
Mojo 1.0, built on libc via `std.ffi.external_call`.

Mojo 1.0 ships no socket API in its standard library; this package is the
gap-filler. It supports macOS and Linux, handling the platform differences in
`sockaddr` layout (the BSD `sin_len` byte versus Linux's 16-bit `sa_family`)
and in `struct addrinfo` field order.

The package is standalone by design: it depends only on the standard library,
so it can be extracted as a `mojo-net` package or offered upstream (see
docs/PRIMITIVES.md).

Highlights:

- `TCPListener` / `TCPStream`: blocking TCP with per-socket read/write
  timeouts (SO_RCVTIMEO / SO_SNDTIMEO). Timeouts surface as the typed
  `TIMEOUT_ERROR`, checked with `is_timeout_error()`.
- `UDPSocket`: bound datagram sockets with `send_to` / `recv_from`.
- `UnixListener` / `UnixStream`: Unix domain stream sockets, including the
  Linux abstract namespace.
- `SocketAddress`: IPv4 and IPv6 addresses with platform `sockaddr` coding.
- `resolve()`: hostname resolution via `getaddrinfo(3)`.
- `Poller`: readiness polling over kqueue/epoll for non-blocking sockets
  (`set_nonblocking`, `write_some`, `connect_addr_nonblocking`).
- `ReadinessStream`: the shared descriptor and partial-I/O contract
  implemented by TCP and Unix streams.

Example:

```mojo
from net import TCPListener, TCPStream

def main() raises:
    var listener = TCPListener("127.0.0.1", 0)  # port 0 = pick a free port
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.write_all("hello".as_bytes())
    var data = server_side.read_exact(5)
```
"""

from .address import IPv4Address
from .libc import (
    TIMEOUT_ERROR,
    WOULD_BLOCK_ERROR,
    is_timeout_error,
    is_would_block,
)
from .poll import PollEvent, Poller
from .resolver import resolve
from .stream import IOStream, ReadinessStream
from .sockaddr import SocketAddress
from .tcp import TCPListener, TCPStream
from .udp import UDPSocket
from .unix import UnixListener, UnixStream
