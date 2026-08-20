# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""IPv4 socket addresses and the platform `sockaddr_in` layout.

Predates `SocketAddress` (sockaddr.mojo), which supersedes it for
dual-stack use; kept for callers that are IPv4-only by construction.
"""

from std.sys import CompilationTarget

from .libc import AF_INET


@fieldwise_init
struct IPv4Address(Copyable, ImplicitlyCopyable, Movable, Writable):
    """An IPv4 address plus TCP/UDP port.

    Formats as "a.b.c.d:port" when written. Convert to and from the
    C `struct sockaddr_in` wire layout with `to_sockaddr()` /
    `from_sockaddr()`.
    """

    var a: UInt8
    """First (most significant) octet of the dotted-quad address."""
    var b: UInt8
    """Second octet of the dotted-quad address."""
    var c: UInt8
    """Third octet of the dotted-quad address."""
    var d: UInt8
    """Fourth (least significant) octet of the dotted-quad address."""
    var port: UInt16
    """TCP/UDP port in host byte order."""

    def __init__(out self, host: StringSpan, port: UInt16) raises:
        """Parses a dotted-quad host string, e.g. IPv4Address("127.0.0.1", 80).

        Args:
            host: Numeric dotted-quad address; each octet must be 0-255.
            port: Port number in host byte order.

        Raises:
            If `host` is not a valid dotted-quad IPv4 literal.
        """
        var parts = host.split(".")
        if len(parts) != 4:
            raise Error("invalid IPv4 address: " + String(host))
        var octets = Array[UInt8, 4](fill=0)
        for i in range(4):
            var v = Int(parts[i])
            if v < 0 or v > 255:
                raise Error("invalid IPv4 address: " + String(host))
            octets[i] = UInt8(v)
        self.a = octets[0]
        self.b = octets[1]
        self.c = octets[2]
        self.d = octets[3]
        self.port = port

    def write_to[W: Writer](self, mut writer: W):
        """Writes the address as "a.b.c.d:port".

        Parameters:
            W: The writer type to output to.

        Args:
            writer: The writer that receives the formatted address.
        """
        writer.write(
            self.a, ".", self.b, ".", self.c, ".", self.d, ":", self.port
        )

    def to_sockaddr(self) -> Array[UInt8, 16]:
        """Encodes the address as a C `struct sockaddr_in` (16 bytes).

        The layout differs by platform:

        macOS/BSD: sin_len(u8) sin_family(u8) sin_port(u16be) sin_addr(u32) pad(8)

        Linux: sin_family(u16le) sin_port(u16be) sin_addr(u32) pad(8)

        Returns:
            The packed sockaddr_in bytes for the compilation target.
        """
        var buf = Array[UInt8, 16](fill=0)
        comptime if CompilationTarget.is_macos():
            buf[0] = 16
            buf[1] = UInt8(AF_INET)
        else:
            buf[0] = UInt8(AF_INET)
            buf[1] = 0
        buf[2] = UInt8((self.port >> 8) & 0xFF)
        buf[3] = UInt8(self.port & 0xFF)
        buf[4] = self.a
        buf[5] = self.b
        buf[6] = self.c
        buf[7] = self.d
        return buf^

    @staticmethod
    def from_sockaddr(buf: Array[UInt8, 16]) -> IPv4Address:
        """Decodes a packed C `struct sockaddr_in` back into an address.

        Reads only the port and address bytes, which sit at the same
        offsets on macOS and Linux; the family bytes are not validated.

        Args:
            buf: The 16-byte sockaddr_in produced by `to_sockaddr()` or
                by a syscall such as `getsockname(2)`.

        Returns:
            The decoded address and port.
        """
        return IPv4Address(
            a=buf[4],
            b=buf[5],
            c=buf[6],
            d=buf[7],
            port=(UInt16(buf[2]) << 8) | UInt16(buf[3]),
        )
