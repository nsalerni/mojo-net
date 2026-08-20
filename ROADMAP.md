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

## 2. Non-blocking I/O and readiness polling

`set_nonblocking()` on sockets, a typed would-block error alongside the
existing typed timeout, and a `Poller` built on kqueue (macOS) and epoll
(Linux) with register/modify/remove/wait. Mojo has no async or threads
yet, but none are needed for an event loop: this makes single-threaded
concurrent servers possible today, which is the biggest current limitation
of the gRPC server built on this package.

Verified by: readiness semantics compared against CPython's `selectors`
module (would-block vs EOF, connect-in-progress, spurious wakeup
handling), and a stress check where one non-blocking echo server serves
many concurrent CPython clients.

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
