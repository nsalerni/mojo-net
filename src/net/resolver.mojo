# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""DNS resolution via `getaddrinfo(3)`.

The C `struct addrinfo` layout differs between the supported platforms
(both 64-bit). The first 24 bytes agree:

    i32 ai_flags; i32 ai_family; i32 ai_socktype; i32 ai_protocol;
    u32 ai_addrlen; (4 bytes padding)

but the pointer fields that follow are ordered differently:

    macOS:  char* ai_canonname @24; sockaddr* ai_addr @32; addrinfo* ai_next @40
    Linux:  sockaddr* ai_addr @24; char* ai_canonname @32; addrinfo* ai_next @40

so `ai_addr` is read from offset 32 on macOS and 24 on Linux
(`ai_next` is at 40 on both).
"""

from std.ffi import c_int, external_call
from std.sys import CompilationTarget

from .libc import AF_UNSPEC, SOCK_STREAM
from .sockaddr import SocketAddress

comptime _ADDRINFO_WORDS = 6  # 48 bytes


def _load_ptr(base: Int, byte_offset: Int) -> Int:
    """Loads an unaligned 64-bit pointer field from a C struct."""
    var p = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=base + byte_offset
    ).unsafe_bitcast[UInt64]()
    return Int(p.unsafe_load[alignment=1]())


def _load_u32(base: Int, byte_offset: Int) -> UInt32:
    """Loads an unaligned 32-bit field from a C struct."""
    var p = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=base + byte_offset
    ).unsafe_bitcast[UInt32]()
    return p.unsafe_load[alignment=1]()


def resolve(
    host: StringSpan,
    port: UInt16,
    *,
    socktype: Int = SOCK_STREAM,
    family: Int = AF_UNSPEC,
) raises -> List[SocketAddress]:
    """Resolves a hostname (or numeric literal) to socket addresses.

    Wraps `getaddrinfo(3)` and walks the returned linked list, decoding
    each entry's sockaddr. Entries with unsupported address families
    (e.g. AF_UNIX) are skipped silently. The result is never empty.

    Args:
        host: Hostname or numeric IP literal to resolve.
        port: Port to attach to every returned address.
        socktype: Socket type hint; defaults to `SOCK_STREAM` so each
            address appears once rather than per-protocol.
        family: Address family hint; the default `AF_UNSPEC` returns
            both IPv4 and IPv6 addresses.

    Returns:
        Addresses in the resolver's preference order (connect to them
        in order).

    Raises:
        If `getaddrinfo` fails or no usable address was returned.
    """
    var host_s = String(host)
    var port_s = String(port)

    # hints: zeroed addrinfo with ai_family and ai_socktype set.
    var hints = Array[UInt8, 48](fill=0)
    var fam = UInt32(family)
    var st = UInt32(socktype)
    for i in range(4):
        hints[4 + i] = UInt8((fam >> UInt32(8 * i)) & 0xFF)
        hints[8 + i] = UInt8((st >> UInt32(8 * i)) & 0xFF)

    var res_ptr: UInt64 = 0
    var rc = external_call["getaddrinfo", c_int](
        host_s.as_c_string_slice(),
        port_s.as_c_string_slice(),
        hints.unsafe_ptr(),
        Pointer(to=res_ptr),
    )
    if rc != 0:
        raise Error(
            "net: getaddrinfo failed for "
            + host_s
            + " (code "
            + String(Int(rc))
            + ")"
        )

    var out = List[SocketAddress]()
    var node = Int(res_ptr)
    while node != 0:
        var addrlen = Int(_load_u32(node, 16))
        var addr_off: Int
        comptime if CompilationTarget.is_macos():
            addr_off = 32
        else:
            addr_off = 24
        var sa_ptr = _load_ptr(node, addr_off)
        if sa_ptr != 0 and addrlen >= 8:
            var raw = List[Byte](capacity=addrlen)
            var src = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=sa_ptr
            )
            for i in range(addrlen):
                raw.append(src[unsafe_offset=i])
            try:
                out.append(SocketAddress.from_sockaddr(Span(raw)))
            except:
                pass  # skip unsupported families (e.g. AF_UNIX)
        node = _load_ptr(node, 40)

    external_call["freeaddrinfo", NoneType](
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(res_ptr))
    )
    if len(out) == 0:
        raise Error("net: no usable addresses for " + host_s)
    return out^
