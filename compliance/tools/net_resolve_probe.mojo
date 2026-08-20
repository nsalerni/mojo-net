# Compliance tool: DNS resolution probe.
# Usage: net_resolve_probe <host> <port>
# Prints one resolved address per line (the runner compares the set with
# CPython's socket.getaddrinfo results).

from std.sys import argv

from net import resolve


def main() raises:
    var args = argv()
    var addrs = resolve(args[1], UInt16(Int(args[2])))
    for a in addrs:
        print(String(a))
