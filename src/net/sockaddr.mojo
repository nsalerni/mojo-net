# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""`SocketAddress`: IPv4/IPv6 address plus port, with platform sockaddr coding.

Handles the layout difference between BSD-style `sockaddr` structs (macOS:
a `sin_len` length byte followed by a one-byte family) and Linux
(a 16-bit little-endian `sa_family` in the first two bytes).
"""

from std.sys import CompilationTarget

from .libc import AF_INET, af_inet6, c_inet_pton

comptime SOCKADDR_STORAGE_LEN = 28
"""Buffer size large enough for sockaddr_in (16) and sockaddr_in6 (28)."""


@fieldwise_init
struct SocketAddress(Copyable, Equatable, Movable, Writable):
    """An IPv4 or IPv6 socket address (ip + port, plus a v6 scope id).

    Construct with `v4()`, `parse()`, or `from_sockaddr()`; convert to
    the C wire layout with `to_sockaddr()`. Formats as "a.b.c.d:port"
    for v4 and "[groups]:port" for v6 when written.
    """

    var is_v6: Bool
    """True for an IPv6 address, False for IPv4."""
    var addr: Array[UInt8, 16]
    """Address bytes in network order; v4 uses the first 4 bytes, v6 all 16."""
    var port: UInt16
    """TCP/UDP port in host byte order."""
    var scope_id: UInt32
    """IPv6 scope/zone id (interface index for link-local); 0 for v4."""

    @staticmethod
    def v4(
        a: UInt8, b: UInt8, c: UInt8, d: UInt8, port: UInt16
    ) -> SocketAddress:
        """Builds an IPv4 address from its four octets and a port.

        Args:
            a: First (most significant) octet.
            b: Second octet.
            c: Third octet.
            d: Fourth (least significant) octet.
            port: Port number in host byte order.

        Returns:
            The IPv4 `SocketAddress`.
        """
        var bytes = Array[UInt8, 16](fill=0)
        bytes[0] = a
        bytes[1] = b
        bytes[2] = c
        bytes[3] = d
        return SocketAddress(is_v6=False, addr=bytes^, port=port, scope_id=0)

    @staticmethod
    def parse(literal: StringSpan, port: UInt16) raises -> SocketAddress:
        """Parses a numeric IPv4 ("1.2.3.4") or IPv6 ("::1") literal.

        Tries `inet_pton` with AF_INET first, then AF_INET6.

        Args:
            literal: The numeric IP literal to parse.
            port: Port number in host byte order.

        Returns:
            The parsed address with `is_v6` set per the detected family.

        Raises:
            On non-numeric hosts — use resolve() for hostnames.
        """
        var host = String(literal)
        var out = Array[UInt8, 16](fill=0)
        if c_inet_pton(AF_INET, host, out.unsafe_ptr()) == 1:
            return SocketAddress(is_v6=False, addr=out^, port=port, scope_id=0)
        if c_inet_pton(af_inet6(), host, out.unsafe_ptr()) == 1:
            return SocketAddress(is_v6=True, addr=out^, port=port, scope_id=0)
        raise Error("net: not a numeric IP literal: " + host)

    def family(self) -> Int:
        """Returns the address family constant for this address.

        Returns:
            `AF_INET` for v4, the platform's AF_INET6 value for v6.
        """
        return af_inet6() if self.is_v6 else AF_INET

    def __eq__(self, other: Self) -> Bool:
        """Compares two addresses for equality.

        Compares family, port, and the significant address bytes (4 for
        v4, 16 for v6). The v6 `scope_id` is not compared.

        Args:
            other: The address to compare against.

        Returns:
            True if both addresses have the same family, port, and
            address bytes.
        """
        if self.is_v6 != other.is_v6 or self.port != other.port:
            return False
        var n = 16 if self.is_v6 else 4
        for i in range(n):
            if self.addr[i] != other.addr[i]:
                return False
        return True

    def write_to(self, mut writer: Some[Writer]):
        """Writes the address as "a.b.c.d:port" (v4) or "[groups]:port" (v6).

        IPv6 uses the grouped-hex form without :: compression —
        unambiguous and simple, at the cost of longer output.

        Args:
            writer: The writer that receives the formatted address.
        """
        if self.is_v6:
            writer.write("[")
            for i in range(8):
                if i > 0:
                    writer.write(":")
                var group = (UInt16(self.addr[2 * i]) << 8) | UInt16(
                    self.addr[2 * i + 1]
                )
                writer.write(
                    hex(Int(group))[byte = 2 : hex(Int(group)).byte_length()]
                )
            writer.write("]:", self.port)
        else:
            writer.write(
                self.addr[0],
                ".",
                self.addr[1],
                ".",
                self.addr[2],
                ".",
                self.addr[3],
                ":",
                self.port,
            )

    def to_sockaddr(self) -> Tuple[Array[UInt8, SOCKADDR_STORAGE_LEN], Int]:
        """Encodes the address as a C sockaddr_in or sockaddr_in6.

        The buffer starts with `sin_len`/`sin6_len` plus a one-byte
        family on macOS/BSD, or a 16-bit little-endian family on Linux.
        For v6 the flowinfo field is always encoded as 0 and `scope_id`
        is written little-endian at offset 24.

        Returns:
            A (buffer, length) tuple; length is 16 for v4 and 28 for v6.
        """
        var buf = Array[UInt8, SOCKADDR_STORAGE_LEN](fill=0)
        if self.is_v6:
            comptime if CompilationTarget.is_macos():
                buf[0] = 28  # sin6_len
                buf[1] = UInt8(af_inet6())
            else:
                buf[0] = UInt8(af_inet6())
                buf[1] = 0
            buf[2] = UInt8((self.port >> 8) & 0xFF)
            buf[3] = UInt8(self.port & 0xFF)
            # flowinfo = 0 (bytes 4..8)
            for i in range(16):
                buf[8 + i] = self.addr[i]
            for i in range(4):
                buf[24 + i] = UInt8((self.scope_id >> UInt32(8 * i)) & 0xFF)
            return (buf^, 28)
        comptime if CompilationTarget.is_macos():
            buf[0] = 16  # sin_len
            buf[1] = UInt8(AF_INET)
        else:
            buf[0] = UInt8(AF_INET)
            buf[1] = 0
        buf[2] = UInt8((self.port >> 8) & 0xFF)
        buf[3] = UInt8(self.port & 0xFF)
        for i in range(4):
            buf[4 + i] = self.addr[i]
        return (buf^, 16)

    @staticmethod
    def from_sockaddr(raw: Span[Byte, _]) raises -> SocketAddress:
        """Decodes a packed sockaddr_in or sockaddr_in6.

        The family is read per the platform layout (byte 1 on macOS/BSD,
        16-bit little-endian at offset 0 on Linux) and selects v4 or v6
        decoding.

        Args:
            raw: The packed sockaddr bytes, e.g. from `accept(2)` or
                `getsockname(2)`.

        Returns:
            The decoded address; `scope_id` is recovered for v6.

        Raises:
            If the buffer is too short for its family or the family is
            neither AF_INET nor AF_INET6 (e.g. AF_UNIX).
        """
        if len(raw) < 8:
            raise Error("net: short sockaddr")
        var family: Int
        comptime if CompilationTarget.is_macos():
            family = Int(raw[1])
        else:
            family = Int(raw[0]) | (Int(raw[1]) << 8)
        var port = (UInt16(raw[2]) << 8) | UInt16(raw[3])
        var addr = Array[UInt8, 16](fill=0)
        if family == AF_INET:
            if len(raw) < 8:
                raise Error("net: short sockaddr_in")
            for i in range(4):
                addr[i] = raw[4 + i]
            return SocketAddress(is_v6=False, addr=addr^, port=port, scope_id=0)
        if family == af_inet6():
            if len(raw) < 28:
                raise Error("net: short sockaddr_in6")
            for i in range(16):
                addr[i] = raw[8 + i]
            var scope: UInt32 = 0
            for i in range(4):
                scope |= UInt32(raw[24 + i]) << UInt32(8 * i)
            return SocketAddress(
                is_v6=True, addr=addr^, port=port, scope_id=scope
            )
        raise Error("net: unsupported address family " + String(family))
