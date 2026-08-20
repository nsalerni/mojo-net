# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""The `IOStream` trait: what a protocol needs from a byte stream.

Protocol layers written against this trait (HTTP/2 in mojo-http2, gRPC
above it) run unchanged over TCP, Unix domain sockets, or a future TLS
stream. The surface is deliberately the small set those layers actually
use, not everything a socket can do.
"""


trait IOStream(Deinitable, Movable):
    """A connected, reliable, ordered byte stream.

    `TCPStream` and `UnixStream` conform; a TLS stream will. Semantics
    follow the concrete types: blocking I/O, timeouts surfaced as the
    typed timeout error, EOF as an error from `read_exact`.
    """

    def read_exact(self, n: Int) raises -> List[Byte]:
        """Reads exactly n bytes, looping over short reads.

        Args:
            n: The exact number of bytes to read.

        Returns:
            A list of exactly n bytes.

        Raises:
            On EOF before n bytes arrive, on I/O errors, or with the
            typed timeout error when a read timeout expires.
        """
        ...

    def write_all(self, data: Span[Byte, _]) raises:
        """Writes the entire span, looping until every byte is sent.

        Args:
            data: The bytes to send.

        Raises:
            On I/O errors, including the typed timeout error when a
            write timeout expires.
        """
        ...

    def set_read_timeout(self, nanos: Int64) raises:
        """Bounds blocking reads; expiry raises the typed timeout error.

        Args:
            nanos: Timeout in nanoseconds; 0 clears the timeout.

        Raises:
            If the underlying call fails.
        """
        ...

    def set_nodelay(self, enabled: Bool) raises:
        """Requests immediate sends for small writes where that exists.

        A latency hint: TCP maps it to TCP_NODELAY; transports without an
        equivalent treat it as a no-op.

        Args:
            enabled: True to send small writes immediately.

        Raises:
            If the underlying call fails.
        """
        ...

    def close(mut self):
        """Closes the stream; safe to call more than once."""
        ...
