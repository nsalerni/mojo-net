# Compliance tool: single-threaded concurrent echo server on a Poller.
# Usage: poll_echo_server <connections>
# Prints "PORT <n>", serves that many connections concurrently with
# non-blocking sockets and one event loop, then prints "SERVED <n>".

from std.ffi import c_int
from std.sys import argv

from net import Poller, TCPListener, TCPStream, is_would_block


struct Conn(Movable):
    var stream: TCPStream
    var outbuf: List[Byte]
    var sent: Int
    var peer_eof: Bool

    def __init__(out self, var stream: TCPStream):
        self.stream = stream^
        self.outbuf = List[Byte]()
        self.sent = 0
        self.peer_eof = False


def main() raises:
    var target = Int(argv()[1])
    var listener = TCPListener("127.0.0.1", 0)
    listener.set_nonblocking(True)
    print("PORT ", listener.local_port, sep="")

    var poller = Poller()
    poller.register(listener.descriptor(), readable=True, writable=False)

    var conns = Dict[Int, Conn]()
    var served = 0
    var accept_drains = 0
    while served < target:
        var events = poller.wait(10_000)
        if len(events) == 0:
            raise Error("event loop stalled")
        for ev in events:
            var fd = Int(ev.fd)
            if fd == Int(listener.descriptor()):
                # Drain the pending queue so one burst costs one wakeup.
                while True:
                    try:
                        var accepted = listener.accept()
                        accepted.set_nonblocking(True)
                        var cfd = Int(accepted.fd)
                        poller.register(
                            accepted.fd, readable=True, writable=False
                        )
                        conns[cfd] = Conn(accepted^)
                    except e:
                        if not is_would_block(e):
                            raise e
                        accept_drains += 1
                        break
                continue
            if fd not in conns:
                continue
            # Take the connection out of the map while working on it:
            # dict subscripts raise DictKeyError, which cannot share a
            # try block with socket calls that raise Error.
            var conn = conns.pop(fd)

            # Pull everything currently readable into the echo buffer.
            if ev.readable or ev.hangup:
                while True:
                    var buf = List[Byte]()
                    buf.resize(65536, 0)
                    try:
                        var n = conn.stream.read(buf)
                        if n == 0:
                            conn.peer_eof = True
                            break
                        conn.outbuf.extend(Span(buf))
                    except e:
                        if not is_would_block(e):
                            raise e
                        break

            # Flush as much as the kernel accepts right now.
            while conn.sent < len(conn.outbuf):
                var remaining = Span(conn.outbuf)[conn.sent : len(conn.outbuf)]
                try:
                    conn.sent += conn.stream.write_some(remaining)
                except e:
                    if not is_would_block(e):
                        raise e
                    break

            var backlog = len(conn.outbuf) - conn.sent
            if conn.peer_eof and backlog == 0:
                # Fully echoed; closing also drops the poller entry.
                conn.stream.close()
                served += 1
            else:
                poller.modify(
                    c_int(fd),
                    readable=not conn.peer_eof,
                    writable=backlog > 0,
                )
                conns[fd] = conn^
    print("SERVED ", served, sep="")
    print("ACCEPT_DRAINS ", accept_drains, sep="")
    listener.close()
    poller.close()
