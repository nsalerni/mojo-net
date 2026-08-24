# Compliance probe for accepted TCP stream blocking mode.
# Usage: accept_mode_probe <blocking|nonblocking>

from std.sys import argv

from net import Poller, TCPListener, is_timeout_error, is_would_block
from net.libc import F_GETFL, c_fcntl, o_nonblock


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("usage: accept_mode_probe <blocking|nonblocking>")
    var mode = String(args[1])
    if mode != "blocking" and mode != "nonblocking":
        raise Error("mode must be blocking or nonblocking")
    var nonblocking = mode == "nonblocking"

    var listener = TCPListener("127.0.0.1", 0)
    listener.set_nonblocking(nonblocking)
    var accept_poller = Poller()
    if nonblocking:
        accept_poller.register(
            listener.descriptor(), readable=True, writable=False
        )
    print("PORT ", listener.local_port, sep="")

    if nonblocking:
        var listener_events = accept_poller.wait(5000)
        if len(listener_events) == 0:
            raise Error("listener readiness timed out")
    var accepted = listener.accept()
    accept_poller.close()
    var flags = c_fcntl(accepted.fd, F_GETFL, 0)
    if flags < 0:
        raise Error("could not read accepted descriptor flags")
    var raw_nonblocking = (flags & o_nonblock()) != 0
    var empty_result = String("SKIPPED")
    if nonblocking:
        empty_result = "NO_ERROR"
        try:
            _ = accepted.read_exact(1)
        except e:
            if is_would_block(e):
                empty_result = "WOULD_BLOCK"
            elif is_timeout_error(e):
                empty_result = "TIMEOUT"
            else:
                empty_result = "OTHER " + String(e)
    print(
        "STATE ",
        "NONBLOCKING" if accepted.nonblocking else "BLOCKING",
        " ",
        "NONBLOCKING" if raw_nonblocking else "BLOCKING",
        " ",
        empty_result,
        sep="",
    )

    var stream_poller = Poller()
    if nonblocking:
        stream_poller.register(
            accepted.fd, readable=True, writable=False
        )
    if nonblocking and len(stream_poller.wait(5000)) == 0:
        raise Error("accepted stream readiness timed out")
    var data = accepted.read_exact(4)
    print("DATA ", String(from_utf8=data), sep="")
    accepted.close()
    listener.close()
    stream_poller.close()
