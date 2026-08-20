# Compliance tool: Unix domain socket echo server (one connection).
# Usage: uds_echo_server <path>
# Prints "READY", echoes bytes until EOF, prints "ECHOED <n>", exits.

from std.sys import argv

from net import UnixListener


def main() raises:
    var path = String(argv()[1])
    var listener = UnixListener(path, remove_existing=True)
    print("READY")
    var stream = listener.accept()
    var total = 0
    while True:
        var buf = List[Byte]()
        buf.resize(65536, 0)
        var n = stream.read(buf)
        if n == 0:
            break
        stream.write_all(Span(buf))
        total += n
    print("ECHOED ", total, sep="")
    stream.close()
    listener.close()
