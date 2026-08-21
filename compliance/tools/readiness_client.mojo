# Generic readiness-stream client against a CPython echo peer.
# Usage: readiness_client tcp <port> <bytes>
#        readiness_client unix <path> <bytes>

from std.sys import argv

from net import (
    Poller,
    ReadinessStream,
    TCPStream,
    UnixStream,
    is_would_block,
)


def run[S: ReadinessStream](var stream: S, size: Int) raises:
    stream.set_nonblocking(True)
    var poller = Poller()
    poller.register(stream.descriptor(), readable=True, writable=True)

    var payload = List[Byte](capacity=size)
    for i in range(size):
        payload.append(UInt8((i * 13 + 7) % 256))

    var sent = 0
    var received = 0
    var writes = 0
    var reads = 0
    var waits = 0
    while received < size:
        waits += 1
        if waits > 10000:
            raise Error("readiness client exceeded event-loop bound")
        var events = poller.wait(10000)
        if len(events) == 0:
            raise Error("readiness client timed out")
        for event in events:
            if event.writable and sent < size:
                try:
                    sent += stream.write_some(Span(payload)[sent:size])
                    writes += 1
                    if sent == size:
                        poller.modify(
                            stream.descriptor(),
                            readable=True,
                            writable=False,
                        )
                except error:
                    if not is_would_block(error):
                        raise error
            if event.readable or event.hangup:
                var buf = List[Byte](length=min(65536, size - received), fill=0)
                try:
                    var count = stream.read(buf)
                    if count == 0:
                        raise Error(
                            "readiness peer closed before echo completed"
                        )
                    reads += 1
                    for i in range(count):
                        if buf[i] != UInt8(((received + i) * 13 + 7) % 256):
                            raise Error("readiness echo payload mismatch")
                    received += count
                except error:
                    if not is_would_block(error):
                        raise error

    print("OK ", sent, " ", received, " ", writes, " ", reads, sep="")
    poller.close()
    stream.close()


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: readiness_client <tcp|unix> <endpoint> <bytes>")
    var mode = String(args[1])
    var size = Int(args[3])
    if mode == "tcp":
        run(TCPStream.connect("127.0.0.1", UInt16(Int(args[2]))), size)
    elif mode == "unix":
        run(UnixStream.connect(String(args[2])), size)
    else:
        raise Error("unknown readiness transport")
