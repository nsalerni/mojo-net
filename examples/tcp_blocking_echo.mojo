from net import TCPListener, TCPStream


def main() raises:
    # Port zero asks the kernel for an unused port. Binding to loopback keeps
    # this example local to the machine that runs it.
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server = listener.accept()

    # Each stream owns its connected socket. The listener is no longer needed
    # after accept returns, so close its separate listening socket now.
    listener.close()

    # Bound waits keep a broken example from hanging forever.
    client.set_read_timeout(2_000_000_000)
    client.set_write_timeout(2_000_000_000)
    server.set_read_timeout(2_000_000_000)
    server.set_write_timeout(2_000_000_000)

    var message = "hello over blocking TCP"
    client.write_all(message.as_bytes())

    var request = server.read_exact(message.byte_length())
    server.write_all(Span(request))

    var response = client.read_exact(message.byte_length())
    var echoed = String(from_utf8=response)
    if echoed != message:
        raise Error("unexpected echo: " + echoed)

    # shutdown_write sends EOF without closing the read side. close releases
    # each owned socket descriptor and is safe to call more than once.
    client.shutdown_write()
    var eof_buf = List[Byte]()
    eof_buf.resize(1, 0)
    if server.read(eof_buf) != 0:
        raise Error("expected EOF after client shutdown")

    client.close()
    server.close()
    print(echoed)
