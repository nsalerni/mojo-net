# Examples

`pixi run example` runs all four, in order. Each binds an unused local port
or a process-specific path under `/tmp`.

| File | What it shows |
|---|---|
| [tcp_blocking_echo.mojo](tcp_blocking_echo.mojo) | Loopback TCP, `shutdown_write()`, EOF |
| [udp_dns_echo.mojo](udp_dns_echo.mojo) | `resolve("localhost")` and `send_to` / `recv_from` |
| [tcp_poller_echo.mojo](tcp_poller_echo.mojo) | Non-blocking TCP with one `Poller` |
| [unix_socket_echo.mojo](unix_socket_echo.mojo) | Unix socket file, path inspection, write-half shutdown |
