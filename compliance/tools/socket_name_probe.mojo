# Compliance tool for connected socket address inspection.
# Usage: socket_name_probe tcp-client <host> <port>
#        socket_name_probe tcp-server <host>
#        socket_name_probe unix-client <path>
#        socket_name_probe unix-server <path>
#        socket_name_probe unix-abstract-client <suffix>
#        socket_name_probe unix-abstract-server <suffix>
#        socket_name_probe unix-fd <fd>
#        socket_name_probe unix-peer-fd <fd>
#        socket_name_probe tcp-peer-fd <fd>

from std.ffi import c_int, get_errno
from std.sys import argv

from net import TCPListener, TCPStream, UnixListener, UnixStream


def print_tcp(stream: TCPStream) raises:
    var local = stream.local_address()
    var peer = stream.peer_address()
    print("LOCAL ", String(local), sep="")
    print("LOCAL_SCOPE ", local.scope_id, sep="")
    print("PEER ", String(peer), sep="")
    print("PEER_SCOPE ", peer.scope_id, sep="")


def print_unix(stream: UnixStream) raises:
    var local = stream.local_path()
    var peer = stream.peer_path()
    print("LOCAL_PATH ", local, sep="")
    print("LOCAL_LENGTH ", local.byte_length(), sep="")
    print("PEER_PATH ", peer, sep="")
    print("PEER_LENGTH ", peer.byte_length(), sep="")


def main() raises:
    var args = argv()
    if len(args) < 3:
        raise Error("usage: socket_name_probe <mode> <endpoint> [port]")
    var mode = String(args[1])
    if mode == "tcp-client":
        if len(args) != 4:
            raise Error("tcp-client needs host and port")
        var stream = TCPStream.connect(String(args[2]), UInt16(Int(args[3])))
        print_tcp(stream)
        _ = stream.read_exact(1)
        stream.close()
    elif mode == "tcp-server":
        if len(args) != 3:
            raise Error("tcp-server needs a bind address")
        var listener = TCPListener(String(args[2]), 0)
        print("PORT ", listener.local_port, sep="")
        var stream = listener.accept()
        print_tcp(stream)
        stream.close()
        listener.close()
    elif mode == "unix-client":
        if len(args) != 3:
            raise Error("unix-client needs a path")
        var stream = UnixStream.connect(String(args[2]))
        print_unix(stream)
        _ = stream.read_exact(1)
        stream.close()
    elif mode == "unix-server":
        if len(args) != 3:
            raise Error("unix-server needs a path")
        var listener = UnixListener(String(args[2]), remove_existing=True)
        print("READY")
        var stream = listener.accept()
        print_unix(stream)
        stream.close()
        listener.close()
    elif mode == "unix-abstract-client":
        if len(args) != 3:
            raise Error("unix-abstract-client needs a name suffix")
        var name = String(chr(0)) + String(args[2])
        var stream = UnixStream.connect(name)
        print_unix(stream)
        _ = stream.read_exact(1)
        stream.close()
    elif mode == "unix-abstract-server":
        if len(args) != 3:
            raise Error("unix-abstract-server needs a name suffix")
        var name = String(chr(0)) + String(args[2])
        var listener = UnixListener(name)
        print("READY")
        var stream = listener.accept()
        print_unix(stream)
        stream.close()
        listener.close()
    elif mode == "unix-fd":
        if len(args) != 3:
            raise Error("unix-fd needs a descriptor")
        var stream = UnixStream(stream=TCPStream(c_int(Int(args[2]))))
        print_unix(stream)
        stream.close()
    elif mode == "unix-peer-fd":
        if len(args) != 3:
            raise Error("unix-peer-fd needs a descriptor")
        var stream = UnixStream(stream=TCPStream(c_int(Int(args[2]))))
        try:
            _ = stream.peer_path()
        except:
            var error_number = get_errno()
            print("ERRNO ", error_number.value, sep="")
            stream.close()
            return
        stream.close()
        raise Error("unconnected unix peer lookup succeeded")
    elif mode == "tcp-peer-fd":
        if len(args) != 3:
            raise Error("tcp-peer-fd needs a descriptor")
        var stream = TCPStream(c_int(Int(args[2])))
        try:
            _ = stream.peer_address()
        except:
            var error_number = get_errno()
            print("ERRNO ", error_number.value, sep="")
            stream.close()
            return
        stream.close()
        raise Error("unconnected TCP peer lookup succeeded")
    else:
        raise Error("unknown socket name probe mode")
