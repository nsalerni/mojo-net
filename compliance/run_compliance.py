#!/usr/bin/env python3
"""mojo-net compliance suite.

Differentially tests the `net` package against CPython's `socket` module —
the OS truth for TCP, UDP, and DNS semantics. Never self-grading: every
check has a CPython socket on the other end of the wire.

Rerun with: pixi run compliance   (from the package root)
Writes COMPLIANCE.md at the package root and exits non-zero on any failure.
With --json PATH, also dumps {"sections": {...}} for the umbrella suite.
"""

import argparse
import json
import platform
import socket
import subprocess
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # package root
BUILD = ROOT / "build"
TOOLS = ROOT / "compliance" / "tools"
REPORT = ROOT / "COMPLIANCE.md"

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
        "<!-- GENERATED by compliance/run_compliance.py — do not edit. -->",
        "<!-- Regenerate with: pixi run compliance -->",
        "",
        f"**Result: {passed}/{total} checks passed.** Generated {now}.",
        "",
        "Every check compares mojo-net against CPython's `socket` module —",
        "the OS truth for TCP, UDP, and DNS semantics — never against itself.",
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
        lines += ["", f"## `{section}` vs CPython sockets — {p}/{len(rows)}", "",
                  "| Check | Result |", "|---|---|"]
        for name, ok, detail in rows:
            status = "✅ pass" if ok else f"❌ **fail** — {detail[:160]}"
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", type=Path, default=None,
                    help="dump {'sections': ...} JSON for the umbrella suite")
    args = ap.parse_args()
    build_tools()
    section_net()
    ok = write_report()
    if args.json:
        args.json.write_text(json.dumps(
            {"sections": {s: [[n, o, d] for n, o, d in rows]
                          for s, rows in RESULTS.items()}}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
