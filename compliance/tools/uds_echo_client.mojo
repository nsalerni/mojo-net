# Compliance tool: Unix domain socket echo client.
# Usage: uds_echo_client <path> <nbytes>
# Sends nbytes of patterned data, shuts down write, reads the echo back,
# verifies byte equality and clean EOF, prints "OK <n>" or raises.

from std.sys import argv

from net import UnixStream


def main() raises:
    var args = argv()
    var path = String(args[1])
    var n = Int(args[2])

    var stream = UnixStream.connect(path)
    var data = List[Byte](capacity=n)
    for i in range(n):
        data.append(UInt8((i * 7 + 13) % 256))
    stream.write_all(Span(data))
    stream.shutdown_write()

    var got = stream.read_exact(n)
    for i in range(n):
        if got[i] != data[i]:
            raise Error("byte mismatch at " + String(i))
    var buf = List[Byte]()
    buf.resize(16, 0)
    var extra = stream.read(buf)
    if extra != 0:
        raise Error("expected EOF, got extra bytes")
    print("OK ", n, sep="")
    stream.close()
