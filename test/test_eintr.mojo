# The handler is installed without SA_RESTART, which is what makes
# epoll_wait, recv, and accept return EINTR.

from std.ffi import c_int, external_call
from std.python import Python
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns, sleep

from net import Poller, TCPListener, TCPStream, Wakeup
from net.libc import c_setsockopt_timeval, so_rcvtimeo, sol_socket


def _install_sigusr1() raises -> Int:
    var signal = Python.import_module("signal")
    _ = signal.signal(signal.SIGUSR1, Python.evaluate("lambda s, f: None"))
    var n = 0
    for cp in String(signal.SIGUSR1).codepoints():
        var c = Int(cp)
        if c < 48 or c > 57:
            break
        n = n * 10 + (c - 48)
    return n


def _kill(pid: Int, sig: Int):
    _ = external_call["kill", c_int](c_int(pid), c_int(sig))


def _exit(code: Int):
    external_call["_exit", NoneType](c_int(code))


def _reap(pid: c_int) -> Int:
    var status = c_int(0)
    var rc = external_call["waitpid", c_int](pid, Pointer(to=status), c_int(0))
    if rc <= 0:
        return -1
    return (Int(status) >> 8) & 0xFF


def _recv_syscall_prefix() -> String:
    comptime if CompilationTarget.is_macos():
        return ""
    else:
        comptime if CompilationTarget.is_x86():
            return "45 "
        else:
            return "207 "


def _parent_blocked(pid: Int, needle: String, syscall_prefix: String) raises -> Bool:
    comptime if CompilationTarget.is_macos():
        var subprocess = Python.import_module("subprocess")
        var out = subprocess.check_output(
            ["ps", "-o", "state=", "-p", String(pid)], text=True
        )
        if String(out).find("S") < 0:
            return False
        sleep(0.03)
        out = subprocess.check_output(
            ["ps", "-o", "state=", "-p", String(pid)], text=True
        )
        return String(out).find("S") >= 0
    else:
        var path = Python.import_module("pathlib")
        var root = "/proc/" + String(pid)
        var wchan = String(path.Path(root + "/wchan").read_text())
        if wchan.find(needle) < 0:
            return False
        if syscall_prefix == "":
            return True
        var syscall = String(path.Path(root + "/syscall").read_text())
        return syscall.find(syscall_prefix) == 0


def _wait_until_blocked(
    pid: Int, needle: String, syscall_prefix: String
) raises -> Bool:
    var deadline = perf_counter_ns() + 3_000_000_000
    while perf_counter_ns() < deadline:
        if _parent_blocked(pid, needle, syscall_prefix):
            return True
        sleep(0.005)
    return False


def test_poller_wait(sig: Int) raises:
    var signal = Python.import_module("signal")
    var wake = Wakeup()
    var poller = Poller()
    poller.register(wake.descriptor(), readable=True, writable=False)
    _ = signal.set_wakeup_fd(Int(wake.write_fd))
    var parent = Int(external_call["getpid", c_int]())
    var pid = external_call["fork", c_int]()
    if pid == 0:
        var code = 1
        try:
            if _wait_until_blocked(parent, "ep_poll", ""):
                _kill(parent, sig)
                code = 0
        except:
            code = 1
        _exit(code)

    var events = poller.wait(5000)
    _ = signal.set_wakeup_fd(-1)
    var code = _reap(pid)
    assert_equal(code, 0, "child must see Poller.wait blocked before the signal")
    assert_equal(len(events), 1, "interrupted wait returns the wakeup")
    assert_equal(Int(events[0].fd), Int(wake.descriptor()))
    assert_true(events[0].readable, "wakeup fd is readable")
    wake.close()
    poller.close()


def test_read_exact(sig: Int) raises:
    var listener = TCPListener("127.0.0.1", 0)
    var client = TCPStream.connect("127.0.0.1", listener.local_port)
    var server = listener.accept()
    server.set_read_timeout(5_000_000_000)
    var parent = Int(external_call["getpid", c_int]())
    var pid = external_call["fork", c_int]()
    if pid == 0:
        var code = 1
        try:
            if _wait_until_blocked(parent, "wait_woken", _recv_syscall_prefix()):
                _kill(parent, sig)
                # Let the interrupted recv return before any bytes are
                # queued. A write in that window makes the kernel return
                # the payload instead of EINTR.
                sleep(0.05)
                client.write_all("ping".as_bytes())
                code = 0
        except:
            code = 1
        _exit(code)

    var got = server.read_exact(4)
    var code = _reap(pid)
    assert_equal(code, 0, "child must see the read blocked before the signal")
    assert_equal(String(from_utf8=got), "ping")
    client.close()
    server.close()
    listener.close()


def test_accept(sig: Int) raises:
    var listener = TCPListener("127.0.0.1", 0)
    # SO_RCVTIMEO bounds accept. A child that never connects must fail
    # the test instead of leaving the parent blocked.
    if (
        c_setsockopt_timeval(
            listener.fd, sol_socket(), so_rcvtimeo(), 5_000_000_000
        )
        != 0
    ):
        raise Error("setsockopt(SO_RCVTIMEO)")
    var port = listener.local_port
    var parent = Int(external_call["getpid", c_int]())
    var pid = external_call["fork", c_int]()
    if pid == 0:
        var code = 1
        try:
            if _wait_until_blocked(parent, "inet_csk_accept", ""):
                _kill(parent, sig)
                sleep(0.05)
                var client = TCPStream.connect("127.0.0.1", port)
                client.write_all("pong".as_bytes())
                client.close()
                code = 0
        except:
            code = 1
        _exit(code)

    var accepted = listener.accept()
    var got = accepted.read_exact(4)
    var code = _reap(pid)
    assert_equal(code, 0, "child must see accept blocked before the signal")
    assert_equal(String(from_utf8=got), "pong")
    accepted.close()
    listener.close()


def main() raises:
    var sig = _install_sigusr1()
    test_poller_wait(sig)
    test_read_exact(sig)
    test_accept(sig)
    print("test_eintr: all tests passed")
