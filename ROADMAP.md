# Roadmap

The rule that governs everything here: a feature lands together with a
differential check against a reference implementation, or it doesn't land.
For this package the reference is CPython's socket machinery talking to the
same kernel. Every item below names its verification up front.

## 1. Unix domain sockets (shipped)

`UnixListener` / `UnixStream` with `sockaddr_un` handled for both
platforms, the Linux abstract namespace, and CPython-matching socket-file
semantics (bind fails on an existing path unless asked to remove it;
close leaves the file). Verified by echo differentials against CPython
`AF_UNIX` sockets in both directions, now part of the standing compliance
report. Datagram support can follow if a consumer needs it.

## 2. Non-blocking I/O and readiness polling (shipped)

`set_nonblocking()` with a typed would-block error, `write_some` as the
partial-write primitive, non-blocking connect with `connect_error()`, and
a `Poller` over kqueue (macOS) and epoll (Linux). Verified by a readiness
sequence diffed line-for-line against CPython's `selectors` module and by
a single-threaded Poller event loop echoing to twenty concurrent CPython
clients, both now standing compliance checks. The gRPC server built on
this package can now drop its one-connection-at-a-time limitation; that
work happens in the grpc-mojo repo.

## 3. TLS, as a sibling package

TLS is big enough to be its own repo (`mojo-tls`), following the same
layout as this one: stdlib plus mojo-net deps only, its own tests,
benchmarks, compliance runner, and published report. The plan is an FFI
binding to libssl from the conda-forge `openssl` package, giving a
`TLSStream` that wraps `TCPStream`: client and server sides, SNI, ALPN
(needed for HTTP/2), and certificate verification against a real trust
store.

Verified by: a handshake matrix against CPython's `ssl` module (TLS 1.2
and 1.3, ALPN and SNI negotiation, client certificates), and a locally
generated bad-certificate corpus (expired, self-signed, wrong hostname)
that must be rejected for the same reasons CPython rejects it.

## Explicitly out of scope for now

Async/await integration (waiting on the language), and anything above the
socket layer. Once Mojo grows public threads or async, the Poller is the
seam where that lands.
