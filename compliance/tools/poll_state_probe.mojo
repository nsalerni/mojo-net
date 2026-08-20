# Compliance tool: readiness-sequence observer for the selectors
# differential. Usage: poll_state_probe <port>
# Connects, then prints one normalized line per state change:
#   writable            (initial connect readiness; write interest dropped)
#   readable data=<n>   (bytes drained after a readable wakeup)
#   eof                 (peer closed)
# The CPython side runs the identical scenario through the selectors
# module and the two outputs must match line for line.

from std.sys import argv

from net import Poller, TCPStream, is_would_block


def main() raises:
    var port = UInt16(Int(argv()[1]))
    var stream = TCPStream.connect("127.0.0.1", port)
    stream.set_nonblocking(True)

    var poller = Poller()
    poller.register(stream.fd, readable=True, writable=True)

    var reported_writable = False
    for _ in range(50):
        var events = poller.wait(5000)
        var readable = False
        var writable = False
        for ev in events:
            if Int(ev.fd) != Int(stream.fd):
                continue
            readable = readable or ev.readable or ev.hangup
            writable = writable or ev.writable
        if writable and not reported_writable:
            print("writable")
            reported_writable = True
            # Like any real event loop: stop asking about writability
            # once there is nothing to write, or it wakes us forever.
            poller.modify(stream.fd, readable=True, writable=False)
        if readable:
            var drained = 0
            var eof = False
            while True:
                var buf = List[Byte]()
                buf.resize(4096, 0)
                try:
                    var n = stream.read(buf)
                    if n == 0:
                        eof = True
                        break
                    drained += n
                except e:
                    if not is_would_block(e):
                        raise e
                    break
            if drained > 0:
                print("readable data=", drained, sep="")
            if eof:
                print("eof")
                stream.close()
                poller.close()
                return
    raise Error("scenario did not complete")
