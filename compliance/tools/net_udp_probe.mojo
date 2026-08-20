# Compliance tool: UDP datagram exchange with a reference peer.
# Usage: net_udp_probe <port> <message>
# Sends the message to 127.0.0.1:<port>, waits up to 5s for a reply
# datagram, prints "reply=<text>".

from std.sys import argv

from net import SocketAddress, UDPSocket


def main() raises:
    var args = argv()
    var sock = UDPSocket("127.0.0.1", 0)
    sock.set_read_timeout(5_000_000_000)
    var dest = SocketAddress.parse("127.0.0.1", UInt16(Int(args[1])))
    var msg = String(args[2])
    sock.send_to(msg.as_bytes(), dest)
    var buf = List[Byte]()
    buf.resize(2048, 0)
    var r = sock.recv_from(buf)
    _ = r
    print("reply=", String(from_utf8=buf), sep="")
    sock.close()
