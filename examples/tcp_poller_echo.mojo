from net import Poller, TCPListener, TCPStream, is_would_block


def main() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server = listener.accept()
    listener.close()

    client.set_nonblocking(True)
    server.set_nonblocking(True)

    var poller = Poller()
    poller.register(client.fd, readable=False, writable=True)
    poller.register(server.fd, readable=True, writable=False)

    var message = "hello from Poller".as_bytes()
    var client_sent = 0
    var server_received = List[Byte]()
    var server_sent = 0
    var client_received = List[Byte]()

    for _ in range(32):
        var events = poller.wait(2_000)
        if len(events) == 0:
            raise Error("echo exchange timed out")

        for event in events:
            if event.error or event.hangup:
                raise Error("socket closed before echoing the message")
            if event.fd == client.fd:
                if event.writable and client_sent < len(message):
                    try:
                        # A ready socket may accept only part of the message.
                        client_sent += client.write_some(
                            message[client_sent : len(message)]
                        )
                    except e:
                        if not is_would_block(e):
                            raise e

                if event.readable:
                    while True:
                        var buf = List[Byte]()
                        buf.resize(4096, 0)
                        try:
                            var n = client.read(buf)
                            if n == 0:
                                raise Error("server closed before echoing")
                            client_received.extend(Span(buf))
                        except e:
                            if not is_would_block(e):
                                raise e
                            break

                poller.modify(
                    client.fd,
                    readable=client_sent == len(message),
                    writable=client_sent < len(message),
                )

            elif event.fd == server.fd:
                if event.readable:
                    while True:
                        var buf = List[Byte]()
                        buf.resize(4096, 0)
                        try:
                            var n = server.read(buf)
                            if n == 0:
                                raise Error("client closed before echoing")
                            server_received.extend(Span(buf))
                        except e:
                            if not is_would_block(e):
                                raise e
                            break

                if event.writable and server_sent < len(server_received):
                    try:
                        # Keep the unsent suffix until the poller wakes us again.
                        server_sent += server.write_some(
                            Span(server_received)[
                                server_sent : len(server_received)
                            ]
                        )
                    except e:
                        if not is_would_block(e):
                            raise e

                poller.modify(
                    server.fd,
                    readable=True,
                    writable=server_sent < len(server_received),
                )

        if len(client_received) == len(message):
            var echoed = String(from_utf8=client_received)
            if echoed != "hello from Poller":
                raise Error("unexpected echo: " + echoed)
            print(echoed)
            client.close()
            server.close()
            poller.close()
            return

    raise Error("echo exchange did not finish")
