#!/usr/bin/env python3
"""mojo-net compliance suite.

Differentially tests the `net` package against CPython's `socket` module,
the OS truth for TCP, UDP, and DNS semantics. Never self-grading: every
check has a CPython socket on the other end of the wire.

Rerun with: pixi run compliance   (from the package root)
Writes COMPLIANCE.md at the package root and exits non-zero on any failure.
With --json PATH, also dumps {"sections": {...}} for the umbrella suite.
"""

import argparse
import ipaddress
import json
import os
import platform
import socket
import selectors
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # package root
BUILD = ROOT / "build"
TOOLS = ROOT / "compliance" / "tools"
REPORT = ROOT / "COMPLIANCE.md"
COMPLIANCE_BADGE = ROOT / "compliance-badge.json"

EXPECTED_NET_CHECKS = (
    "mojo TCP server echoes 1MiB to python client + EOF semantics",
    "mojo TCP client 1MiB roundtrip vs python server + EOF check",
    "resolve() agrees with CPython getaddrinfo for localhost",
    "mojo UDP exchange vs CPython socket (send, recv, sender addr)",
    "mojo IPv6 TCP client 100KB roundtrip vs python ::1 server",
    "mojo unix-socket server echoes 1MiB to CPython AF_UNIX client",
    "mojo unix-socket client 1MiB roundtrip vs CPython server",
    "one Poller event loop drains and echoes a burst of 20 CPython clients",
    "Poller readiness sequence matches CPython selectors",
    "ReadinessStream TCP partial I/O matches CPython sockets",
    "ReadinessStream Unix partial I/O matches CPython AF_UNIX",
    "TCP IPv4 local and peer addresses match CPython socket names",
    "TCP IPv6 local and peer addresses match CPython socket names",
    "Unix local and peer paths match CPython socket names",
    "accepted TCP streams match explicit CPython blocking modes",
)

RESULTS: dict[str, list[tuple[str, bool, str]]] = {}
PROBE_TIMEOUT = 15


def record(section: str, name: str, ok: bool, detail: str = ""):
    RESULTS.setdefault(section, []).append((name, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'} [{section}] {name}" + ("" if ok else f"  <- {detail}"))


def run_tool(binary: str, *args, timeout=60) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(BUILD / binary), *map(str, args)],
        capture_output=True, text=True, timeout=timeout, cwd=ROOT,
    )


def build_tools():
    print("== building Mojo compliance tools ==")
    BUILD.mkdir(exist_ok=True)
    for src in sorted(TOOLS.glob("*.mojo")):
        out = BUILD / src.stem
        subprocess.run(
            ["mojo", "build", "-I", "src", str(src.relative_to(ROOT)), "-o", str(out)],
            check=True, cwd=ROOT,
        )
        print(f"  built {src.stem}")


def parse_name_probe(output: str) -> dict[str, str]:
    values = {}
    for line in output.splitlines():
        key, separator, value = line.partition(" ")
        if separator:
            values[key] = value
    return values


def stop_probe(proc: subprocess.Popen | None) -> None:
    """Terminates and reaps a probe that has not exited."""
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.terminate()
    except ProcessLookupError:
        proc.wait()
        return
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        proc.wait(timeout=2)


def read_probe_line(proc: subprocess.Popen, timeout=PROBE_TIMEOUT) -> str:
    """Reads one probe line without allowing a readiness hang."""
    if proc.stdout is None:
        raise RuntimeError("probe stdout is unavailable")
    selector = selectors.DefaultSelector()
    try:
        selector.register(proc.stdout, selectors.EVENT_READ)
        if not selector.select(timeout):
            raise TimeoutError("probe readiness timed out")
        line = proc.stdout.readline()
    finally:
        selector.close()
    if not line:
        raise RuntimeError("probe exited before reporting readiness")
    return line.rstrip("\n")


def finish_probe(
    proc: subprocess.Popen, timeout=PROBE_TIMEOUT
) -> tuple[str, str]:
    """Collects a probe and always reaps it on timeout."""
    try:
        return proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stop_probe(proc)
        raise TimeoutError("probe completion timed out") from error


def unix_name_text(value: str | bytes) -> str:
    """Converts CPython's pathname or abstract-byte result to Mojo text."""
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return value


def unix_name_length(value: str | bytes) -> int:
    """Returns the byte length CPython reports for a Unix socket name."""
    if isinstance(value, bytes):
        return len(value)
    return len(value.encode("utf-8"))


def format_inet_name(value: tuple) -> tuple[str, int]:
    host = ipaddress.ip_address(value[0])
    port = value[1]
    if host.version == 4:
        return f"{host}:{port}", 0
    groups = ":".join(
        format(int(group, 16), "x")
        for group in host.exploded.split(":")
    )
    scope = value[3] if len(value) > 3 else 0
    return f"[{groups}]:{port}", scope


def tcp_name_differential(family: int, host: str) -> tuple[bool, str]:
    client_probe = None
    listener = None
    accepted = None
    try:
        listener = socket.socket(family, socket.SOCK_STREAM)
        listener.settimeout(PROBE_TIMEOUT)
        listener.bind((host, 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        client_probe = subprocess.Popen(
            [str(BUILD / "socket_name_probe"), "tcp-client", host, str(port)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        accepted, _ = listener.accept()
        accepted.settimeout(PROBE_TIMEOUT)
        python_local = accepted.getsockname()
        python_peer = accepted.getpeername()
        accepted.sendall(b"x")
        client_output, client_error = finish_probe(client_probe)
        client_names = parse_name_probe(client_output)
        expected_client_local = format_inet_name(python_peer)
        expected_client_peer = format_inet_name(python_local)
        client_ok = (
            client_probe.returncode == 0
            and client_names.get("LOCAL") == expected_client_local[0]
            and client_names.get("LOCAL_SCOPE") == str(expected_client_local[1])
            and client_names.get("PEER") == expected_client_peer[0]
            and client_names.get("PEER_SCOPE") == str(expected_client_peer[1])
        )
    except Exception as error:
        return False, f"client phase failed: {error!r}"
    finally:
        if accepted is not None:
            accepted.close()
        if listener is not None:
            listener.close()
        stop_probe(client_probe)

    server_probe = None
    python_client = None
    try:
        server_probe = subprocess.Popen(
            [str(BUILD / "socket_name_probe"), "tcp-server", host],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        server_port = int(read_probe_line(server_probe).removeprefix("PORT "))
        python_client = socket.socket(family, socket.SOCK_STREAM)
        python_client.settimeout(PROBE_TIMEOUT)
        python_client.connect((host, server_port))
        expected_server_local = format_inet_name(python_client.getpeername())
        expected_server_peer = format_inet_name(python_client.getsockname())
        server_output, server_error = finish_probe(server_probe)
        server_names = parse_name_probe(server_output)
        server_ok = (
            server_probe.returncode == 0
            and server_names.get("LOCAL") == expected_server_local[0]
            and server_names.get("LOCAL_SCOPE") == str(expected_server_local[1])
            and server_names.get("PEER") == expected_server_peer[0]
            and server_names.get("PEER_SCOPE") == str(expected_server_peer[1])
        )
    except Exception as error:
        return False, f"server phase failed: {error!r}"
    finally:
        if python_client is not None:
            python_client.close()
        stop_probe(server_probe)

    return client_ok and server_ok, (
        f"client={client_names} expected=({expected_client_local}, "
        f"{expected_client_peer}) rc={client_probe.returncode} "
        f"err={client_error[:100]!r}; server={server_names} "
        f"expected=({expected_server_local}, {expected_server_peer}) "
        f"rc={server_probe.returncode} err={server_error[:100]!r}"
    )


def unix_client_name_phase(
    endpoint: str | bytes, mode: str, argument: str
) -> tuple[bool, str]:
    listener = None
    accepted = None
    probe = None
    try:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.settimeout(PROBE_TIMEOUT)
        listener.bind(endpoint)
        listener.listen(1)
        probe = subprocess.Popen(
            [str(BUILD / "socket_name_probe"), mode, argument],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        accepted, _ = listener.accept()
        accepted.settimeout(PROBE_TIMEOUT)
        python_local = accepted.getsockname()
        python_peer = accepted.getpeername()
        accepted.sendall(b"x")
        output, error = finish_probe(probe)
        names = parse_name_probe(output)
        ok = (
            probe.returncode == 0
            and names.get("LOCAL_PATH") == unix_name_text(python_peer)
            and names.get("LOCAL_LENGTH") == str(unix_name_length(python_peer))
            and names.get("PEER_PATH") == unix_name_text(python_local)
            and names.get("PEER_LENGTH") == str(unix_name_length(python_local))
        )
        return ok, (
            f"client={names} python=({python_peer!r}, {python_local!r}) "
            f"rc={probe.returncode} err={error[:100]!r}"
        )
    except Exception as error:
        return False, f"client phase failed: {error!r}"
    finally:
        if accepted is not None:
            accepted.close()
        if listener is not None:
            listener.close()
        stop_probe(probe)


def unix_server_name_phase(
    endpoint: str | bytes, mode: str, argument: str
) -> tuple[bool, str]:
    probe = None
    python_client = None
    try:
        probe = subprocess.Popen(
            [str(BUILD / "socket_name_probe"), mode, argument],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        ready = read_probe_line(probe)
        python_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        python_client.settimeout(PROBE_TIMEOUT)
        python_client.connect(endpoint)
        python_local = python_client.getpeername()
        python_peer = python_client.getsockname()
        output, error = finish_probe(probe)
        names = parse_name_probe(output)
        ok = (
            ready == "READY"
            and probe.returncode == 0
            and names.get("LOCAL_PATH") == unix_name_text(python_local)
            and names.get("LOCAL_LENGTH") == str(unix_name_length(python_local))
            and names.get("PEER_PATH") == unix_name_text(python_peer)
            and names.get("PEER_LENGTH") == str(unix_name_length(python_peer))
        )
        return ok, (
            f"server={names} python=({python_local!r}, {python_peer!r}) "
            f"rc={probe.returncode} err={error[:100]!r}"
        )
    except Exception as error:
        return False, f"server phase failed: {error!r}"
    finally:
        if python_client is not None:
            python_client.close()
        stop_probe(probe)


def inherited_name_probe(mode: str, sock: socket.socket) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(BUILD / "socket_name_probe"), mode, str(sock.fileno())],
        pass_fds=(sock.fileno(),),
        capture_output=True,
        text=True,
        timeout=PROBE_TIMEOUT,
        cwd=ROOT,
    )


def unix_unnamed_differential() -> tuple[bool, str]:
    left = None
    right = None
    try:
        left, right = socket.socketpair()
        result = inherited_name_probe("unix-fd", right)
        names = parse_name_probe(result.stdout)
        python_local = left.getsockname()
        python_peer = left.getpeername()
        ok = (
            result.returncode == 0
            and names.get("LOCAL_PATH") == unix_name_text(python_peer)
            and names.get("LOCAL_LENGTH") == str(unix_name_length(python_peer))
            and names.get("PEER_PATH") == unix_name_text(python_local)
            and names.get("PEER_LENGTH") == str(unix_name_length(python_local))
        )
        return ok, (
            f"socketpair={names} python=({python_peer!r}, {python_local!r}) "
            f"rc={result.returncode} err={result.stderr[:100]!r}"
        )
    except Exception as error:
        return False, f"socketpair phase failed: {error!r}"
    finally:
        if left is not None:
            left.close()
        if right is not None:
            right.close()


def unconnected_peer_differential(
    family: int, mode: str
) -> tuple[bool, str]:
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        reference_failed = False
        reference_errno = None
        try:
            sock.getpeername()
        except OSError as error:
            reference_failed = True
            reference_errno = error.errno
        result = inherited_name_probe(mode, sock)
        values = parse_name_probe(result.stdout)
        mojo_errno = values.get("ERRNO")
        ok = (
            reference_failed
            and reference_errno is not None
            and result.returncode == 0
            and mojo_errno == str(reference_errno)
        )
        return ok, (
            f"python_errno={reference_errno} mojo_errno={mojo_errno} "
            f"rc={result.returncode} err={result.stderr[:120]!r}"
        )
    except Exception as error:
        return False, f"unconnected peer phase failed: {error!r}"
    finally:
        sock.close()


def unix_name_differential() -> tuple[bool, str]:
    results = []
    details = []
    with tempfile.TemporaryDirectory(
        prefix="mojo-net-names-", dir="/tmp"
    ) as private_dir:
        first_path = str(Path(private_dir) / "client.sock")
        second_path = str(Path(private_dir) / "server.sock")
        ok, detail = unix_client_name_phase(
            first_path, "unix-client", first_path
        )
        results.append(ok)
        details.append("filesystem client " + detail)
        ok, detail = unix_server_name_phase(
            second_path, "unix-server", second_path
        )
        results.append(ok)
        details.append("filesystem server " + detail)
        for path in (first_path, second_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

        if platform.system() == "Linux":
            suffix = "mojo-net-" + Path(private_dir).name
            abstract_name = b"\0" + suffix.encode("utf-8")
            ok, detail = unix_client_name_phase(
                abstract_name, "unix-abstract-client", suffix
            )
            results.append(ok)
            details.append("abstract client " + detail)
            ok, detail = unix_server_name_phase(
                abstract_name + b"-server",
                "unix-abstract-server",
                suffix + "-server",
            )
            results.append(ok)
            details.append("abstract server " + detail)
        else:
            details.append("abstract Linux only")

    ok, detail = unix_unnamed_differential()
    results.append(ok)
    details.append("unnamed socketpair " + detail)
    ok, detail = unconnected_peer_differential(
        socket.AF_UNIX, "unix-peer-fd"
    )
    results.append(ok)
    details.append("unconnected Unix " + detail)
    ok, detail = unconnected_peer_differential(
        socket.AF_INET, "tcp-peer-fd"
    )
    results.append(ok)
    details.append("unconnected TCP " + detail)
    return all(results), "; ".join(details)


def python_accept_mode_reference(nonblocking: bool) -> dict[str, object]:
    """Runs the accepted-stream scenario with explicit CPython modes."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client = None
    accepted = None
    selector = selectors.DefaultSelector()
    try:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.setblocking(not nonblocking)
        client = socket.create_connection(listener.getsockname(), timeout=10)
        if nonblocking:
            selector.register(listener, selectors.EVENT_READ)
            if not selector.select(timeout=5):
                raise TimeoutError("CPython listener readiness timed out")
        accepted, _ = listener.accept()
        accepted.setblocking(not nonblocking)
        wrapper_mode = (
            "NONBLOCKING" if not accepted.getblocking() else "BLOCKING"
        )
        raw_mode = (
            "NONBLOCKING" if not os.get_blocking(accepted.fileno())
            else "BLOCKING"
        )
        empty_result = "SKIPPED"
        if nonblocking:
            try:
                accepted.recv(1)
                empty_result = "NO_ERROR"
            except BlockingIOError:
                empty_result = "WOULD_BLOCK"
            selector.unregister(listener)
            selector.register(accepted, selectors.EVENT_READ)
        client.sendall(b"mode")
        data = bytearray()
        while len(data) < 4:
            if nonblocking and not selector.select(timeout=5):
                raise TimeoutError("CPython accepted read timed out")
            chunk = accepted.recv(4 - len(data))
            if not chunk:
                raise ConnectionError("CPython accepted stream closed early")
            data.extend(chunk)
        return {
            "child": (wrapper_mode, raw_mode),
            "empty": empty_result,
            "data": data.decode("ascii"),
        }
    finally:
        selector.close()
        if accepted is not None:
            accepted.close()
        if client is not None:
            client.close()
        listener.close()


def mojo_accept_mode_result(nonblocking: bool) -> dict[str, object]:
    """Runs the accepted-stream scenario with a CPython client peer."""
    process = None
    client = None
    mode = "nonblocking" if nonblocking else "blocking"
    try:
        process = subprocess.Popen(
            [str(BUILD / "accept_mode_probe"), mode],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        port_fields = read_probe_line(process).split()
        if len(port_fields) != 2 or port_fields[0] != "PORT":
            raise ValueError("probe returned a malformed port line")
        port = int(port_fields[1])
        if not 0 < port <= 65535:
            raise ValueError("probe returned an invalid TCP port")
        client = socket.create_connection(("127.0.0.1", port), timeout=10)
        state_fields = read_probe_line(process).split()
        if len(state_fields) != 4 or state_fields[0] != "STATE":
            raise ValueError("probe returned a malformed state line")
        state = state_fields[1:]
        client.sendall(b"mode")
        output, error = finish_probe(process)
        output_lines = output.splitlines()
        if len(output_lines) != 1 or not output_lines[0].startswith("DATA "):
            raise ValueError("probe returned malformed data output")
        data = output_lines[0].removeprefix("DATA ")
        return {
            "child": tuple(state[:2]),
            "empty": state[2] if len(state) == 3 else None,
            "state_fields": len(state),
            "data": data,
            "rc": process.returncode,
            "error": error[:150],
        }
    except Exception as error:
        return {"error": repr(error)}
    finally:
        if client is not None:
            client.close()
        stop_probe(process)


# ------------------------------------------------------------------ net ---

def section_net():
    print("== net vs CPython sockets ==")
    n = 1_048_576

    # Mojo server, python client.
    proc = subprocess.Popen([str(BUILD / "net_echo_server")], stdout=subprocess.PIPE, text=True, cwd=ROOT)
    port = int(proc.stdout.readline().strip().removeprefix("PORT "))
    data = bytes((i * 7 + 13) % 256 for i in range(n))
    ok, detail = False, ""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.settimeout(30)
        got = bytearray()
        def reader():
            while len(got) < n:
                chunk = s.recv(65536)
                if not chunk:
                    break
                got.extend(chunk)
        t = threading.Thread(target=reader, daemon=True); t.start()
        s.sendall(data)
        s.shutdown(socket.SHUT_WR)
        t.join(timeout=30)
        tail = s.recv(65536)  # server closes after EOF echo: expect b""
        ok = bytes(got) == data and tail == b""
        detail = f"echoed {len(got)}/{n}, clean_eof={tail == b''}"
        s.close()
    except Exception as e:
        detail = repr(e)
    finally:
        proc.kill(); proc.wait()
    record("net", "mojo TCP server echoes 1MiB to python client + EOF semantics", ok, detail)

    # Python server, Mojo client.
    lsock = socket.socket(); lsock.bind(("127.0.0.1", 0)); lsock.listen(1)
    port = lsock.getsockname()[1]
    def py_echo():
        c, _ = lsock.accept()
        c.settimeout(30)
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            c.sendall(chunk)
        c.close()
    t = threading.Thread(target=py_echo, daemon=True); t.start()
    r = run_tool("net_echo_client", port, n, timeout=60)
    t.join(timeout=30); lsock.close()
    ok = r.returncode == 0 and f"OK {n}" in r.stdout
    record("net", "mojo TCP client 1MiB roundtrip vs python server + EOF check",
           ok, f"rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr[:150]!r}")

    # DNS: resolve() must agree with CPython's getaddrinfo.
    r = run_tool("net_resolve_probe", "localhost", 8080)
    mojo_addrs = set(l.strip() for l in r.stdout.splitlines() if l.strip())
    py_addrs = set()
    for family, kind, _, _, sa in socket.getaddrinfo(
        "localhost", 8080, type=socket.SOCK_STREAM
    ):
        if family == socket.AF_INET:
            py_addrs.add(f"{sa[0]}:{sa[1]}")
        elif family == socket.AF_INET6:
            groups = ":".join(
                format(int.from_bytes(bs, "big"), "x")
                for bs in [socket.inet_pton(socket.AF_INET6, sa[0])[i:i+2]
                           for i in range(0, 16, 2)]
            )
            py_addrs.add(f"[{groups}]:{sa[1]}")
    record("net", "resolve() agrees with CPython getaddrinfo for localhost",
           bool(py_addrs) and py_addrs == mojo_addrs,
           f"mojo={sorted(mojo_addrs)} python={sorted(py_addrs)}")

    # UDP datagram exchange against a CPython socket peer.
    usock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    usock.bind(("127.0.0.1", 0)); usock.settimeout(10)
    uport = usock.getsockname()[1]
    def udp_reply():
        data, peer = usock.recvfrom(2048)
        usock.sendto(data.upper(), peer)
    t = threading.Thread(target=udp_reply, daemon=True); t.start()
    r = run_tool("net_udp_probe", uport, "datagram works")
    t.join(timeout=10); usock.close()
    record("net", "mojo UDP exchange vs CPython socket (send, recv, sender addr)",
           "reply=DATAGRAM WORKS" in r.stdout,
           r.stdout.strip() + r.stderr[:100])

    # IPv6 TCP against a CPython socket peer.
    l6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    l6.bind(("::1", 0)); l6.listen(1)
    p6 = l6.getsockname()[1]
    def py6_echo():
        c, _ = l6.accept(); c.settimeout(30)
        while True:
            chunk = c.recv(65536)
            if not chunk: break
            c.sendall(chunk)
        c.close()
    t = threading.Thread(target=py6_echo, daemon=True); t.start()
    r = run_tool("net_echo_client", p6, 100_000, "::1", timeout=60)
    t.join(timeout=30); l6.close()
    record("net", "mojo IPv6 TCP client 100KB roundtrip vs python ::1 server",
           r.returncode == 0 and "OK 100000" in r.stdout,
           f"rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr[:150]!r}")

    # Unix domain sockets: mojo server, CPython AF_UNIX client.
    uds1 = f"/tmp/mojo-net-compl-a-{os.getpid()}.sock"
    proc = subprocess.Popen([str(BUILD / "uds_echo_server"), uds1], stdout=subprocess.PIPE, text=True, cwd=ROOT)
    proc.stdout.readline()  # READY
    data = bytes((i * 3 + 5) % 256 for i in range(n))
    ok, detail = False, ""
    try:
        us = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        us.connect(uds1)
        us.settimeout(30)
        got = bytearray()
        def ureader():
            while len(got) < n:
                chunk = us.recv(65536)
                if not chunk:
                    break
                got.extend(chunk)
        t = threading.Thread(target=ureader, daemon=True); t.start()
        us.sendall(data)
        us.shutdown(socket.SHUT_WR)
        t.join(timeout=30)
        tail = us.recv(65536)
        ok = bytes(got) == data and tail == b""
        detail = f"echoed {len(got)}/{n}, clean_eof={tail == b''}"
        us.close()
    except Exception as e:
        detail = repr(e)
    finally:
        proc.kill(); proc.wait()
        try:
            os.unlink(uds1)
        except OSError:
            pass
    record("net", "mojo unix-socket server echoes 1MiB to CPython AF_UNIX client", ok, detail)

    # CPython server (buffer whole payload, then echo: AF_UNIX in-flight
    # buffers are tiny, so concurrent echo would deadlock), mojo client.
    uds2 = f"/tmp/mojo-net-compl-b-{os.getpid()}.sock"
    try:
        os.unlink(uds2)
    except OSError:
        pass
    lu = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    lu.bind(uds2); lu.listen(1)
    def py_uds_echo():
        c, _ = lu.accept()
        c.settimeout(30)
        blob = bytearray()
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            blob.extend(chunk)
        c.sendall(bytes(blob))
        c.close()
    t = threading.Thread(target=py_uds_echo, daemon=True); t.start()
    r = run_tool("uds_echo_client", uds2, n, timeout=60)
    t.join(timeout=30); lu.close()
    try:
        os.unlink(uds2)
    except OSError:
        pass
    record("net", "mojo unix-socket client 1MiB roundtrip vs CPython server",
           r.returncode == 0 and f"OK {n}" in r.stdout,
           f"rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr[:150]!r}")

    # One single-threaded Poller event loop serving 20 concurrent CPython
    # clients, each echoing 100 KB.
    clients = 20
    per_client = 100_000
    proc = subprocess.Popen([str(BUILD / "poll_echo_server"), str(clients)],
                            stdout=subprocess.PIPE, text=True, cwd=ROOT)
    pport = int(proc.stdout.readline().strip().removeprefix("PORT "))
    failures = []
    start = threading.Barrier(clients)
    def one_client(idx: int):
        try:
            start.wait(timeout=10)
            cs = socket.create_connection(("127.0.0.1", pport), timeout=10)
            cs.settimeout(30)
            payload = bytes((i + idx) % 256 for i in range(per_client))
            got = bytearray()
            def rd():
                while len(got) < per_client:
                    chunk = cs.recv(65536)
                    if not chunk:
                        break
                    got.extend(chunk)
            rt = threading.Thread(target=rd, daemon=True); rt.start()
            cs.sendall(payload)
            cs.shutdown(socket.SHUT_WR)
            rt.join(timeout=30)
            if bytes(got) != payload:
                failures.append(f"client {idx}: {len(got)}/{per_client}")
            cs.close()
        except Exception as e:
            failures.append(f"client {idx}: {e!r}")
    threads = [threading.Thread(target=one_client, args=(i,)) for i in range(clients)]
    for t in threads: t.start()
    for t in threads: t.join(timeout=60)
    served_line = ""
    try:
        proc.wait(timeout=30)
        served_line = proc.stdout.read().strip()
    except Exception:
        proc.kill()
    record("net", f"one Poller event loop drains and echoes a burst of {clients} CPython clients",
           (not failures and f"SERVED {clients}" in served_line
            and "ACCEPT_DRAINS " in served_line
            and "ACCEPT_DRAINS 0" not in served_line),
           "; ".join(failures[:3]) + f" [{served_line!r}]")

    # Readiness semantics agree with CPython's selectors module: run one
    # scripted peer scenario past both observers and diff the sequences.
    def scenario_server():
        c, _ = ssock.accept()
        time.sleep(0.2)
        c.sendall(b"hello")
        time.sleep(0.2)
        c.close()
    def python_observer(port: int) -> list[str]:
        sel = selectors.DefaultSelector()
        obs = socket.create_connection(("127.0.0.1", port), timeout=10)
        obs.setblocking(False)
        sel.register(obs, selectors.EVENT_READ | selectors.EVENT_WRITE)
        seq = []
        reported_writable = False
        for _ in range(50):
            events = sel.select(timeout=5)
            readable = any(ev & selectors.EVENT_READ for _, ev in events)
            writable = any(ev & selectors.EVENT_WRITE for _, ev in events)
            if writable and not reported_writable:
                seq.append("writable")
                reported_writable = True
                sel.modify(obs, selectors.EVENT_READ)
            if readable:
                drained = 0
                eof = False
                while True:
                    try:
                        chunk = obs.recv(4096)
                    except BlockingIOError:
                        break
                    if not chunk:
                        eof = True
                        break
                    drained += len(chunk)
                if drained:
                    seq.append(f"readable data={drained}")
                if eof:
                    seq.append("eof")
                    obs.close()
                    sel.close()
                    return seq
        return seq + ["<incomplete>"]

    ssock = socket.socket(); ssock.bind(("127.0.0.1", 0)); ssock.listen(2)
    sport = ssock.getsockname()[1]
    t = threading.Thread(target=scenario_server, daemon=True); t.start()
    py_seq = python_observer(sport)
    t.join(timeout=10)
    t = threading.Thread(target=scenario_server, daemon=True); t.start()
    r = run_tool("poll_state_probe", sport, timeout=30)
    t.join(timeout=10); ssock.close()
    mojo_seq = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    record("net", "Poller readiness sequence matches CPython selectors",
           py_seq == mojo_seq and "eof" in py_seq,
           f"python={py_seq} mojo={mojo_seq} rc={r.returncode} err={r.stderr[:120]!r}")

    # One trait-generic non-blocking client against CPython peers over both
    # connected stream transports. The payload exceeds normal socket buffers,
    # requiring multiple readiness-driven reads and writes.
    readiness_size = 8 * 1024 * 1024

    def readiness_echo(listener, result):
        try:
            conn, _ = listener.accept()
            total = 0
            while total < readiness_size:
                chunk = conn.recv(min(65536, readiness_size - total))
                if not chunk:
                    break
                conn.sendall(chunk)
                total += len(chunk)
            conn.close()
            result["bytes"] = total
        except Exception as error:
            result["error"] = repr(error)

    def readiness_ok(proc, peer_result):
        parts = proc.stdout.split()
        if proc.returncode != 0 or len(parts) != 5 or parts[0] != "OK":
            return False
        try:
            sent, received, writes, reads = map(int, parts[1:])
        except ValueError:
            return False
        return (
            sent == readiness_size
            and received == readiness_size
            and writes > 1
            and reads > 1
            and peer_result.get("bytes") == readiness_size
            and "error" not in peer_result
        )

    tcp_listener = socket.socket()
    tcp_listener.bind(("127.0.0.1", 0))
    tcp_listener.listen(1)
    tcp_result = {}
    thread = threading.Thread(
        target=readiness_echo, args=(tcp_listener, tcp_result), daemon=True
    )
    thread.start()
    r = run_tool(
        "readiness_client",
        "tcp",
        tcp_listener.getsockname()[1],
        readiness_size,
        timeout=90,
    )
    thread.join(timeout=30)
    tcp_listener.close()
    ok = readiness_ok(r, tcp_result)
    record(
        "net",
        "ReadinessStream TCP partial I/O matches CPython sockets",
        ok,
        f"out={r.stdout.strip()!r} peer={tcp_result} err={r.stderr[:120]!r}",
    )

    unix_path = f"/tmp/mojo-net-readiness-{os.getpid()}.sock"
    try:
        os.unlink(unix_path)
    except FileNotFoundError:
        pass
    unix_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    unix_listener.bind(unix_path)
    unix_listener.listen(1)
    unix_result = {}
    thread = threading.Thread(
        target=readiness_echo, args=(unix_listener, unix_result), daemon=True
    )
    thread.start()
    r = run_tool(
        "readiness_client", "unix", unix_path, readiness_size, timeout=90
    )
    thread.join(timeout=30)
    unix_listener.close()
    try:
        os.unlink(unix_path)
    except FileNotFoundError:
        pass
    ok = readiness_ok(r, unix_result)
    record(
        "net",
        "ReadinessStream Unix partial I/O matches CPython AF_UNIX",
        ok,
        f"out={r.stdout.strip()!r} peer={unix_result} err={r.stderr[:120]!r}",
    )

    ok, detail = tcp_name_differential(socket.AF_INET, "127.0.0.1")
    record(
        "net",
        "TCP IPv4 local and peer addresses match CPython socket names",
        ok,
        detail,
    )

    ok, detail = tcp_name_differential(socket.AF_INET6, "::1")
    record(
        "net",
        "TCP IPv6 local and peer addresses match CPython socket names",
        ok,
        detail,
    )

    ok, detail = unix_name_differential()
    record(
        "net",
        "Unix local and peer paths match CPython socket names",
        ok,
        detail,
    )

    accept_mode_results = []
    accept_mode_details = []
    for nonblocking in (False, True):
        label = "nonblocking" if nonblocking else "blocking"
        try:
            reference = python_accept_mode_reference(nonblocking)
            mojo = mojo_accept_mode_result(nonblocking)
            expected = {
                "child": reference["child"],
                "empty": reference["empty"],
                "data": reference["data"],
            }
            observed = {
                "child": mojo.get("child"),
                "empty": mojo.get("empty"),
                "data": mojo.get("data"),
            }
            ok = (
                mojo.get("rc") == 0
                and mojo.get("state_fields") == 3
                and not mojo.get("error")
                and observed == expected
            )
            detail = f"python={expected} mojo={mojo}"
        except Exception as error:
            ok = False
            detail = repr(error)
        accept_mode_results.append(ok)
        accept_mode_details.append(label + " " + detail)
    record(
        "net",
        "accepted TCP streams match explicit CPython blocking modes",
        all(accept_mode_results),
        "; ".join(accept_mode_details),
    )


# --------------------------------------------------------------- report ---

def versions() -> dict[str, str]:
    mojo = subprocess.run(["mojo", "--version"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
    return {
        "mojo": mojo,
        "python (reference: CPython sockets)": platform.python_version(),
        "platform": f"{platform.system()} {platform.release()} {platform.machine()}",
    }


def net_result_summary(
    results: dict[str, list[tuple[str, bool, str]]],
) -> tuple[int, int, bool]:
    """Counts registered checks and rejects incomplete result sets."""
    rows = results.get("net", [])
    indexed: dict[str, list[bool]] = {}
    for name, ok, _ in rows:
        indexed.setdefault(name, []).append(ok)

    passed = 0
    for name in EXPECTED_NET_CHECKS:
        outcomes = indexed.get(name, [])
        if len(outcomes) == 1 and outcomes[0]:
            passed += 1

    expected = set(EXPECTED_NET_CHECKS)
    valid = (
        set(results) == {"net"}
        and len(rows) == len(EXPECTED_NET_CHECKS)
        and set(indexed) == expected
        and all(len(indexed[name]) == 1 for name in expected)
    )
    return passed, len(EXPECTED_NET_CHECKS), valid


def write_report() -> bool:
    passed, total, valid = net_result_summary(RESULTS)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    verdict = (
        "checks passed"
        if valid
        else "registered checks passed; results incomplete"
    )
    lines = [
        "# mojo-net Compliance Report",
        "",
        "<!-- GENERATED by compliance/run_compliance.py; do not edit. -->",
        "<!-- Regenerate with: pixi run compliance -->",
        "",
        f"**Result: {passed}/{total} {verdict}.** Generated {now}.",
        "",
        "Every check compares mojo-net against CPython's `socket` module,",
        "the OS truth for TCP, UDP, and DNS semantics, never against itself.",
        "",
        "## Environment",
        "",
        "| Component | Version |",
        "|---|---|",
    ]
    for k, v in versions().items():
        lines.append(f"| {k} | {v} |")
    for section, rows in RESULTS.items():
        section_passed = passed if section == "net" else 0
        section_total = total if section == "net" else len(rows)
        lines += [
            "",
            f"## `{section}` vs CPython sockets: "
            f"{section_passed}/{section_total}",
            "",
            "| Check | Result |",
            "|---|---|",
        ]
        for name, ok, detail in rows:
            status = "✅ pass" if ok else f"❌ **fail**: {detail[:160]}"
            lines.append(f"| {name} | {status} |")
    lines += [
        "",
        "## How to rerun",
        "",
        "```sh",
        "pixi run compliance   # from this package root",
        "```",
        "",
    ]
    REPORT.write_text("\n".join(lines))
    print(f"\ncompliance: {passed}/{total} checks passed")
    print(f"report: {REPORT}")
    return valid and passed == total


def compliance_badge_payload(
    results: dict[str, list[tuple[str, bool, str]]],
) -> dict[str, object]:
    """Build a Shields endpoint payload from the expected CPython checks."""
    passed, total, valid = net_result_summary(results)
    complete = valid and passed == total
    return {
        "schemaVersion": 1,
        "label": "CPython socket checks",
        "message": f"{passed}/{total}",
        "color": "brightgreen" if complete else "red",
    }


def compliance_badge_json(
    results: dict[str, list[tuple[str, bool, str]]],
) -> str:
    """Serialize the endpoint payload in a stable form."""
    return json.dumps(
        compliance_badge_payload(results), indent=2, sort_keys=True
    ) + "\n"


def write_compliance_badge() -> bool:
    payload = compliance_badge_payload(RESULTS)
    COMPLIANCE_BADGE.write_text(compliance_badge_json(RESULTS))
    print(f"report: {COMPLIANCE_BADGE.relative_to(ROOT)}")
    return payload["color"] == "brightgreen"


HTML_REPORT = ROOT / "COMPLIANCE.html"

HTML_HEAD = """<!-- GENERATED by compliance/run_compliance.py - regenerate with: pixi run compliance -->
<title>mojo-net Compliance</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans+Condensed:wght@600&display=swap">
<style>
:root {
  --paper: #FAFAF8; --ink: #22262B; --muted: #6E6A62; --accent: #C2551F;
  --pass: #2E7D4F; --fail: #B3362B; --line: #E4E0D8; --panel: #F2F0EA;
  --mono: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace;
  --sans: "IBM Plex Sans", -apple-system, "Segoe UI", sans-serif;
  --cond: "IBM Plex Sans Condensed", "Arial Narrow", var(--sans);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --paper: #16181C; --ink: #E8E6E1; --muted: #98938A; --accent: #E0663A;
    --pass: #5EC08D; --fail: #E5776C; --line: #2C2F35; --panel: #1D2025;
  }
}
:root[data-theme="dark"] {
  --paper: #16181C; --ink: #E8E6E1; --muted: #98938A; --accent: #E0663A;
  --pass: #5EC08D; --fail: #E5776C; --line: #2C2F35; --panel: #1D2025;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--paper); color: var(--ink); font: 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
main { max-width: 76ch; margin: 0 auto; padding: 3.5rem 1.5rem 5rem; }
header { border-bottom: 2px solid var(--ink); padding-bottom: 1.75rem; margin-bottom: 2.5rem; }
.eyebrow { font: 500 0.72rem/1 var(--mono); letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent); margin: 0 0 0.9rem; }
h1 { font: 600 clamp(1.9rem, 5vw, 2.6rem)/1.1 var(--cond); margin: 0 0 1.1rem; text-wrap: balance; letter-spacing: -0.01em; }
.verdict { display: flex; align-items: baseline; gap: 0.75rem; flex-wrap: wrap; }
.verdict .score { font: 500 2rem/1 var(--mono); font-variant-numeric: tabular-nums; color: var(--pass); }
.verdict .score.failing { color: var(--fail); }
.verdict .when { color: var(--muted); font-size: 0.85rem; }
.thesis { color: var(--muted); margin: 0.9rem 0 0; max-width: 62ch; }
.scorecard { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-top: 1.5rem; padding: 0; list-style: none; }
.scorecard li { font: 400 0.78rem/1 var(--mono); padding: 0.45rem 0.7rem; border: 1px solid var(--line); border-radius: 3px; background: var(--panel); display: flex; gap: 0.55rem; align-items: center; }
.scorecard .n { font-variant-numeric: tabular-nums; color: var(--pass); font-weight: 500; }
.scorecard .n.failing { color: var(--fail); }
section { margin: 2.75rem 0; }
h2 { font: 600 1.15rem/1.3 var(--sans); margin: 0 0 0.35rem; text-wrap: balance; }
h2 .pkg { font-family: var(--mono); font-weight: 500; color: var(--accent); }
.vs { color: var(--muted); font-weight: 400; }
.method { color: var(--muted); font-size: 0.88rem; margin: 0 0 1.1rem; max-width: 68ch; }
.tablewrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.88rem; }
th { text-align: left; font: 500 0.7rem/1 var(--mono); letter-spacing: 0.1em; text-transform: uppercase; color: var(--muted); padding: 0 0.75rem 0.5rem 0; border-bottom: 1px solid var(--ink); }
td { padding: 0.5rem 0.75rem 0.5rem 0; border-bottom: 1px solid var(--line); vertical-align: top; }
td.result { white-space: nowrap; font: 500 0.78rem/1.8 var(--mono); }
.pass { color: var(--pass); }
.fail { color: var(--fail); }
td .detail { display: block; color: var(--muted); font-size: 0.8rem; }
.envtable td:first-child { color: var(--muted); width: 40%; }
.envtable td { font-family: var(--mono); font-size: 0.8rem; }
.gaps { border-left: 3px solid var(--accent); background: var(--panel); padding: 1.1rem 1.4rem; }
.gaps h2 { margin-top: 0; }
.gaps ul { margin: 0.5rem 0 0; padding-left: 1.1rem; }
.gaps li { margin: 0.45rem 0; font-size: 0.9rem; }
.gaps strong { font-weight: 600; }
footer { margin-top: 3rem; color: var(--muted); font: 400 0.78rem/1.6 var(--mono); border-top: 1px solid var(--line); padding-top: 1rem; }
code { font-family: var(--mono); font-size: 0.92em; }
</style>
"""


def esc(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


HTML_EYEBROW = "mojo-net &middot; differential compliance run"
HTML_H1 = "Sockets checked against CPython, the operating-system truth"
HTML_THESIS = ("This report records 15 finite differential checks against CPython&rsquo;s socket module and the same kernel. They cover TCP and Unix echo, EOF and half-close behavior, UDP, IPv6 loopback, readiness, accepted stream modes, connected socket names, and <code>getaddrinfo</code> for localhost.")
HTML_GAPS = [
    ("Language async integration", "Poller provides non-blocking readiness today. Native async and await integration depends on public Mojo language support."),
]
HTML_SECTIONS = {
    "net": ("`net` vs CPython sockets",
            "1 MiB echo in both directions between mojo-net and CPython sockets, including TCP and Unix streams, half-close and clean EOF semantics, UDP datagram round trips, IPv6, readiness, connected socket names, and getaddrinfo differential resolution."),
}


def write_html_report() -> bool:
    passed, total, valid = net_result_summary(RESULTS)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    all_ok = valid and passed == total
    verdict = (
        "checks passed"
        if valid
        else "registered checks passed; results incomplete"
    )
    h = [HTML_HEAD, "<main>", "<header>"]
    h.append(f'<p class="eyebrow">{HTML_EYEBROW}</p>')
    h.append(f"<h1>{HTML_H1}</h1>")
    h.append(
        f'<div class="verdict"><span class="score{"" if all_ok else " failing"}">'
        f"{passed}/{total}</span><span>{verdict}</span>"
        f'<span class="when">{now}</span></div>'
    )
    h.append(f'<p class="thesis">{HTML_THESIS}</p>')
    h.append('<ul class="scorecard">')
    for section, rows in RESULTS.items():
        section_passed = passed if section == "net" else 0
        section_total = total if section == "net" else len(rows)
        section_ok = all_ok if section == "net" else False
        cls = "" if section_ok else " failing"
        h.append(
            f'<li>{esc(section)} <span class="n{cls}">'
            f"{section_passed}/{section_total}</span></li>"
        )
    h.append("</ul></header>")

    for section, rows in RESULTS.items():
        title, blurb = HTML_SECTIONS.get(section, (section, ""))
        pkg, _, ref = title.replace("`", "").partition(" vs ")
        h.append("<section>")
        if ref:
            h.append(f'<h2><span class="pkg">{esc(pkg)}</span> <span class="vs">vs</span> {esc(ref)}</h2>')
        else:
            h.append(f"<h2>{esc(pkg)}</h2>")
        if blurb:
            h.append(f'<p class="method">{esc(blurb)}</p>')
        h.append('<div class="tablewrap"><table>')
        h.append("<tr><th>Check</th><th>Result</th></tr>")
        for name, ok, detail in rows:
            cell = '<span class="pass">PASS</span>' if ok else '<span class="fail">FAIL</span>'
            extra = "" if ok else f'<span class="detail">{esc(detail[:200])}</span>'
            h.append(f"<tr><td>{esc(name)}</td><td class=\"result\">{cell}{extra}</td></tr>")
        h.append("</table></div></section>")

    h.append("<section><h2>Environment</h2>")
    h.append('<div class="tablewrap"><table class="envtable">')
    for k, v in versions().items():
        h.append(f"<tr><td>{esc(k)}</td><td>{esc(v)}</td></tr>")
    h.append("</table></div></section>")

    h.append('<section class="gaps"><h2>Known gaps (tracked, not silent)</h2><ul>')
    for k, v in HTML_GAPS:
        h.append(f"<li><strong>{esc(k)}.</strong> {esc(v)}</li>")
    h.append("</ul></section>")
    h.append(
        "<footer>Generated by compliance/run_compliance.py &middot; "
        "rerun with <code>pixi run compliance</code> &middot; canonical copy: "
        "COMPLIANCE.md</footer>"
    )
    h.append("</main>")
    HTML_REPORT.write_text("\n".join(h))
    print(f"report: {HTML_REPORT.relative_to(ROOT)}")
    return all_ok



def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", type=Path, default=None,
                    help="dump {'sections': ...} JSON for the umbrella suite")
    args = ap.parse_args()
    build_tools()
    section_net()
    markdown_ok = write_report()
    html_ok = write_html_report()
    badge_ok = write_compliance_badge()
    if args.json:
        args.json.write_text(json.dumps(
            {"sections": {s: [[n, o, d] for n, o, d in rows]
                          for s, rows in RESULTS.items()}}))
    return 0 if markdown_ok and html_ok and badge_ok else 1


if __name__ == "__main__":
    sys.exit(main())
