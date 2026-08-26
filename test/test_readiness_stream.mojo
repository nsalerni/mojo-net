# Trait-level readiness tests over both TCP and Unix domain streams.

from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_true

from net import (
    IOStream,
    Poller,
    ReadinessStream,
    TCPListener,
    TCPStream,
    UnixListener,
    UnixStream,
    is_would_block,
)


def sock_path() -> String:
    var pid = external_call["getpid", c_int]()
    return "/tmp/mojo-net-ready-" + String(Int(pid)) + ".sock"


def cleanup(var path: String):
    _ = external_call["unlink", c_int](path.as_c_string_slice())


def accepts_blocking_stream[S: IOStream](stream: S):
    """Compile-time proof that the refined trait still satisfies IOStream."""
    _ = stream


def exercise[S: ReadinessStream](mut sender: S, mut receiver: S) raises:
    accepts_blocking_stream(sender)
    accepts_blocking_stream(receiver)
    sender.set_nonblocking(True)
    receiver.set_nonblocking(True)
    assert_true(Int(sender.descriptor()) >= 0)
    assert_true(Int(receiver.descriptor()) >= 0)

    var empty = List[Byte](length=32, fill=0)
    var blocked = False
    try:
        _ = receiver.read(empty)
    except error:
        blocked = True
        assert_true(is_would_block(error), String(error))
    assert_true(blocked, "empty non-blocking read reports would-block")

    var payload = String("readiness trait")
    assert_equal(sender.write_some(payload.as_bytes()), payload.byte_length())
    var poller = Poller()
    poller.register(receiver.descriptor(), readable=True, writable=False)
    var events = poller.wait(2000)
    assert_true(len(events) > 0, "descriptor becomes readable")

    var buf = List[Byte](length=64, fill=0)
    var read = receiver.read(buf)
    assert_equal(read, payload.byte_length())
    assert_equal(String(from_utf8=buf), payload)

    poller.close()
    sender.close()
    receiver.close()


def test_tcp_conformance() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server = listener.accept()
    exercise(client, server)
    listener.close()


def test_unix_conformance() raises:
    var path = sock_path()
    var listener = UnixListener(path, remove_existing=True)
    var client = UnixStream.connect(path)
    var server = listener.accept()
    exercise(client, server)
    listener.close()
    cleanup(path^)


def write_some_via_iostream[S: IOStream](
    stream: S, data: Span[Byte, _]
) raises -> Int:
    """Calls `write_some` through the blocking `IOStream` trait."""
    return stream.write_some(data)


def test_iostream_write_some() raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server = listener.accept()
    var payload = String("iostream write_some")
    assert_equal(
        write_some_via_iostream(client, payload.as_bytes()),
        payload.byte_length(),
    )
    var got = server.read_exact(payload.byte_length())
    assert_equal(String(from_utf8=got), payload)
    client.close()
    server.close()
    listener.close()


def main() raises:
    test_tcp_conformance()
    test_unix_conformance()
    test_iostream_write_some()
    print("test_readiness_stream: all tests passed")
