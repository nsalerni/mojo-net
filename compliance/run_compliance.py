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
import json
import os
import platform
import socket
import selectors
import subprocess
import sys
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
)

RESULTS: dict[str, list[tuple[str, bool, str]]] = {}


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


# --------------------------------------------------------------- report ---

def versions() -> dict[str, str]:
    mojo = subprocess.run(["mojo", "--version"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
    return {
        "mojo": mojo,
        "python (reference: CPython sockets)": platform.python_version(),
        "platform": f"{platform.system()} {platform.release()} {platform.machine()}",
    }


def write_report() -> bool:
    total = sum(len(v) for v in RESULTS.values())
    passed = sum(1 for v in RESULTS.values() for _, ok, _ in v if ok)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# mojo-net Compliance Report",
        "",
        "<!-- GENERATED by compliance/run_compliance.py; do not edit. -->",
        "<!-- Regenerate with: pixi run compliance -->",
        "",
        f"**Result: {passed}/{total} checks passed.** Generated {now}.",
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
        p = sum(1 for _, ok, _ in rows if ok)
        lines += ["", f"## `{section}` vs CPython sockets: {p}/{len(rows)}", "",
                  "| Check | Result |", "|---|---|"]
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
    return passed == total


def compliance_badge_payload(
    results: dict[str, list[tuple[str, bool, str]]],
) -> dict[str, object]:
    """Build a Shields endpoint payload from the expected CPython checks."""
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
    complete = (
        set(results) == {"net"}
        and len(rows) == len(EXPECTED_NET_CHECKS)
        and set(indexed) == expected
        and all(len(indexed[name]) == 1 for name in expected)
        and passed == len(EXPECTED_NET_CHECKS)
    )
    return {
        "schemaVersion": 1,
        "label": "CPython socket checks",
        "message": f"{passed}/{len(EXPECTED_NET_CHECKS)}",
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
HTML_THESIS = ("No self-grading: every TCP, UDP, IPv6, and DNS behavior is exercised against CPython&rsquo;s socket module talking to the same kernel &mdash; echo both directions, half-close semantics, datagram round trips, and <code>getaddrinfo</code> agreement.")
HTML_GAPS = [
    ("TLS", "not implemented; needs a Mojo TLS binding."),
    ("Async / non-blocking I/O", "blocking sockets only until Mojo exposes threads/async; bound waits with the typed read/write timeouts."),
    ("Unix domain sockets", "not implemented (AF_INET/AF_INET6 only)."),
]
HTML_SECTIONS = {
    "net": ("`net` vs CPython sockets",
            "1 MiB echo in both directions between mojo-net TCP and CPython sockets, including half-close (shutdown) and clean-EOF semantics, UDP datagram round trips, IPv6, and getaddrinfo differential resolution."),
}


def write_html_report():
    total = sum(len(v) for v in RESULTS.values())
    passed = sum(1 for v in RESULTS.values() for _, ok, _ in v if ok)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    all_ok = passed == total
    h = [HTML_HEAD, "<main>", "<header>"]
    h.append(f'<p class="eyebrow">{HTML_EYEBROW}</p>')
    h.append(f"<h1>{HTML_H1}</h1>")
    h.append(
        f'<div class="verdict"><span class="score{"" if all_ok else " failing"}">'
        f"{passed}/{total}</span><span>checks passed</span>"
        f'<span class="when">{now}</span></div>'
    )
    h.append(f'<p class="thesis">{HTML_THESIS}</p>')
    h.append('<ul class="scorecard">')
    for section, rows in RESULTS.items():
        p = sum(1 for _, ok, _ in rows if ok)
        cls = "" if p == len(rows) else " failing"
        h.append(f'<li>{esc(section)} <span class="n{cls}">{p}/{len(rows)}</span></li>')
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
        h.append(f"<li><strong>{esc(k)}</strong> &mdash; {esc(v)}</li>")
    h.append("</ul></section>")
    h.append(
        "<footer>Generated by compliance/run_compliance.py &middot; "
        "rerun with <code>pixi run compliance</code> &middot; canonical copy: "
        "COMPLIANCE.md</footer>"
    )
    h.append("</main>")
    HTML_REPORT.write_text("\n".join(h))
    print(f"report: {HTML_REPORT.relative_to(ROOT)}")



def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", type=Path, default=None,
                    help="dump {'sections': ...} JSON for the umbrella suite")
    args = ap.parse_args()
    build_tools()
    section_net()
    ok = write_report()
    write_html_report()
    badge_ok = write_compliance_badge()
    if args.json:
        args.json.write_text(json.dumps(
            {"sections": {s: [[n, o, d] for n, o, d in rows]
                          for s, rows in RESULTS.items()}}))
    return 0 if ok and badge_ok else 1


if __name__ == "__main__":
    sys.exit(main())
