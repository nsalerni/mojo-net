# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026 the grpc-mojo contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# ===----------------------------------------------------------------------=== #

"""Loopback throughput and latency benchmarks for mojo-net.

Both ends of each connection live in this single thread, alternating
writes and reads; the kernel's loopback socket buffers hold each burst.
Run: `pixi run bench`. Pass `--smoke` for a milliseconds-long CI run.
"""

from std.benchmark import Unit, run
from std.sys import argv

from net import (
    ReadinessStream,
    SocketAddress,
    TCPListener,
    TCPStream,
    UDPSocket,
)


def is_smoke() -> Bool:
    for a in argv():
        if a == "--smoke":
            return True
    return False


def bench_time() -> Float64:
    return 0.005 if is_smoke() else 0.5


def run_capped[F: def() raises](f: F, secs: Float64) raises -> Float64:
    """Runs a benchmark bounded by `secs` and returns the mean in ns."""
    var report = run(f, min_runtime_secs=secs, max_runtime_secs=secs * 3)
    return report.mean(Unit.ns)


def report_line(name: StringSpan, ns_per_op: Float64, bytes_per_op: Int):
    var mib_s = 0.0
    if ns_per_op > 0:
        mib_s = (Float64(bytes_per_op) / (1024 * 1024)) / (ns_per_op / 1e9)
    print(
        String(name),
        ": ",
        Int(ns_per_op),
        " ns/op",
        ", ",
        Int(mib_s),
        " MiB/s",
        sep="",
    )


def readiness_roundtrip[
    S: ReadinessStream
](mut client: S, mut server: S, payload: Span[Byte, _]) raises:
    """Performs one trait-generic partial-I/O round trip."""
    var sent = client.write_some(payload)
    if sent != len(payload):
        raise Error("benchmark partial write")
    var got = List[Byte](length=len(payload), fill=0)
    if server.read(got) != len(payload):
        raise Error("benchmark partial read")
    sent = server.write_some(Span(got))
    if sent != len(got):
        raise Error("benchmark partial write")
    var back = List[Byte](length=len(payload), fill=0)
    if client.read(back) != len(payload):
        raise Error("benchmark partial read")


def main() raises:
    var secs = bench_time()

    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server_side = listener.accept()
    client.set_nodelay(True)
    server_side.set_nodelay(True)

    # --- TCP round trip: 64 B there and back (4 syscalls) ---
    var ping = List[Byte]()
    ping.resize(64, 0x42)

    def tcp_rtt() raises {client, server_side, ping}:
        client.write_all(Span(ping))
        var got = server_side.read_exact(64)
        server_side.write_all(Span(got))
        var back = client.read_exact(64)
        if len(back) != 64:
            raise Error("unreachable")

    var r = run_capped(tcp_rtt, secs)
    report_line("tcp 64B round trip", r, 128)

    def readiness_rtt() raises {mut client, mut server_side, ping}:
        readiness_roundtrip(client, server_side, Span(ping))

    r = run_capped(readiness_rtt, secs)
    report_line("readiness trait 64B round trip", r, 128)

    # --- TCP bulk: 64 KiB one way, drained by the peer in-loop ---
    var chunk = List[Byte]()
    chunk.resize(16 * 1024, 0x5A)

    def tcp_bulk() raises {client, server_side, chunk}:
        # 4 x 16 KiB fits comfortably in loopback socket buffers.
        for _ in range(4):
            client.write_all(Span(chunk))
            var got = server_side.read_exact(16 * 1024)
            if len(got) == 0:
                raise Error("unreachable")

    r = run_capped(tcp_bulk, secs)
    report_line("tcp 64KiB transfer", r, 64 * 1024)

    # --- UDP round trip ---
    var a = UDPSocket("127.0.0.1", 0)
    var b = UDPSocket("127.0.0.1", 0)
    var dest_b = SocketAddress.parse("127.0.0.1", b.local_port)
    var dest_a = SocketAddress.parse("127.0.0.1", a.local_port)
    var datagram = List[Byte]()
    datagram.resize(64, 0x7E)

    def udp_rtt() raises {a, b, datagram, dest_a, dest_b}:
        a.send_to(Span(datagram), dest_b)
        var buf = List[Byte]()
        buf.resize(64, 0)
        _ = b.recv_from(buf)
        b.send_to(Span(buf), dest_a)
        var buf2 = List[Byte]()
        buf2.resize(64, 0)
        var got = a.recv_from(buf2)
        if got[0] != 64:
            raise Error("unreachable")

    r = run_capped(udp_rtt, secs)
    report_line("udp 64B round trip", r, 128)

    client.close()
    server_side.close()
    listener.close()
    a.close()
    b.close()
    print("bench_net: done")
