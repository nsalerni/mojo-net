# One request and response over a Unix domain socket file.

from std.ffi import c_int, external_call

from net import UnixListener, UnixStream


def socket_path() -> String:
    var pid = external_call["getpid", c_int]()
    return "/tmp/mojo-net-example-" + String(Int(pid)) + ".sock"


def unlink(path: StringSpan):
    var owned = String(path)
    _ = external_call["unlink", c_int](owned.as_c_string_slice())


def main() raises:
    var path = socket_path()
    # The default refuses an existing path. The example never deletes a path
    # that it did not create.
    var listener = UnixListener(path)
    var client = UnixStream.connect(path)
    var server = listener.accept()
    listener.close()

    client.set_read_timeout(2_000_000_000)
    client.set_write_timeout(2_000_000_000)
    server.set_read_timeout(2_000_000_000)
    server.set_write_timeout(2_000_000_000)

    var message = String("hello over a Unix socket")
    client.write_all(message.as_bytes())
    var request = server.read_exact(message.byte_length())
    server.write_all(Span(request))

    var response = client.read_exact(message.byte_length())
    var echoed = String(from_utf8=response)
    if echoed != message:
        raise Error("unexpected echo: " + echoed)

    if client.peer_path() != path or server.local_path() != path:
        raise Error("socket path inspection did not match the bound path")

    client.shutdown_write()
    var eof = List[Byte]()
    eof.resize(1, 0)
    if server.read(eof) != 0:
        raise Error("expected EOF after client shutdown")

    client.close()
    server.close()
    unlink(path)
    print(echoed)
