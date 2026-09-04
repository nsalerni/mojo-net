# Wakeup self-pipe: notify wakes Poller.wait, drain leaves it quiet,
# and a forked child can wake a parent blocked in wait.

from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_true
from std.time import sleep

from net import PollEvent, Poller, Wakeup


def flags_for(
    events: List[PollEvent], fd: Int
) -> Tuple[Bool, Bool, Bool, Bool]:
    var r = False
    var w = False
    var h = False
    var e = False
    for ev in events:
        if Int(ev.fd) != fd:
            continue
        r = r or ev.readable
        w = w or ev.writable
        h = h or ev.hangup
        e = e or ev.error
    return (r, w, h, e)


def test_notify_then_wait() raises:
    var wakeup = Wakeup()
    var poller = Poller()
    poller.register(wakeup.descriptor(), readable=True, writable=False)

    assert_equal(len(poller.wait(50)), 0, "idle wakeup must not be readable")

    wakeup.notify()
    var events = poller.wait(2000)
    var got = flags_for(events, Int(wakeup.descriptor()))
    assert_true(got[0], "notify must make the read end readable")

    wakeup.drain()
    assert_equal(len(poller.wait(50)), 0, "drain must leave the pipe empty")

    wakeup.close()
    poller.close()


def test_fork_wakes_blocked_wait() raises:
    var wakeup = Wakeup()
    var poller = Poller()
    poller.register(wakeup.descriptor(), readable=True, writable=False)

    var pid = external_call["fork", c_int]()
    if pid == 0:
        sleep(0.05)
        wakeup.notify()
        external_call["_exit", NoneType](c_int(0))

    var events = poller.wait(2000)
    var got = flags_for(events, Int(wakeup.descriptor()))
    assert_true(got[0], "child notify must wake the parent's Poller.wait")
    wakeup.drain()

    var status = c_int(0)
    _ = external_call["waitpid", c_int](pid, Pointer(to=status), c_int(0))
    wakeup.close()
    poller.close()


def test_closed_notify_is_noop() raises:
    var wakeup = Wakeup()
    wakeup.close()
    wakeup.notify()


def main() raises:
    test_notify_then_wait()
    test_fork_wakes_blocked_wait()
    test_closed_notify_is_noop()
    print("test_wakeup: all tests passed")
