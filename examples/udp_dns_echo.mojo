from net import SocketAddress, UDPSocket, resolve


def resolve_ipv4_loopback(port: UInt16) raises -> SocketAddress:
    """Finds localhost's IPv4 address with the requested destination port."""
    var addresses = resolve("localhost", port)
    var expected = SocketAddress.v4(127, 0, 0, 1, port)
    for address in addresses:
        if address == expected:
            return address.copy()
    raise Error("localhost did not resolve to 127.0.0.1")


def main() raises:
    # Port zero asks the kernel to assign separate unused ports. UDP has no
    # connection or accept step, so both sockets bind before sending data.
    var sender = UDPSocket("127.0.0.1", 0)
    var receiver = UDPSocket("127.0.0.1", 0)

    # A dropped datagram should fail this example instead of leaving it stuck.
    sender.set_read_timeout(2_000_000_000)
    receiver.set_read_timeout(2_000_000_000)

    var destination = resolve_ipv4_loopback(receiver.local_port)
    if destination.port != receiver.local_port:
        raise Error("resolver returned the wrong destination port")

    var message = "hello over UDP"
    sender.send_to(message.as_bytes(), destination)

    var request_buf = List[Byte]()
    request_buf.resize(2048, 0)
    var request = receiver.recv_from(request_buf)
    if request[0] != message.byte_length():
        raise Error("receiver got the wrong datagram length")
    if String(from_utf8=request_buf) != message:
        raise Error("receiver got the wrong datagram payload")
    var expected_source = SocketAddress.v4(127, 0, 0, 1, sender.local_port)
    if request[1] != expected_source:
        raise Error("receiver reported the wrong sender address")

    # recv_from returns a reply address, so no address book is needed here.
    receiver.send_to(Span(request_buf), request[1])

    var response_buf = List[Byte]()
    response_buf.resize(2048, 0)
    var response = sender.recv_from(response_buf)
    if response[0] != message.byte_length():
        raise Error("sender got the wrong datagram length")
    var echoed = String(from_utf8=response_buf)
    if echoed != message:
        raise Error("unexpected echo: " + echoed)
    if response[1] != destination:
        raise Error("sender reported the wrong reply source")

    sender.close()
    receiver.close()
    print(echoed)
