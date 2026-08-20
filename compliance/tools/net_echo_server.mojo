# Compliance tool: TCP echo server on an ephemeral port (one connection).
# Prints "PORT <n>", echoes bytes until EOF, then exits.

from net import TCPListener


def main() raises:
    var listener = TCPListener("127.0.0.1", 0)
    print("PORT ", listener.local_port, sep="")
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
