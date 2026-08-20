#!/usr/bin/env python3
"""Run every test executable in test/ (pixi's task shell has no loops)."""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    failed = 0
    for t in sorted((ROOT / "test").glob("test_*.mojo")):
        r = subprocess.run(
            ["mojo", "run", "-I", "src", "-I", "test", str(t.relative_to(ROOT))],
            cwd=ROOT,
        )
        print(("PASS " if r.returncode == 0 else "FAIL ") + t.name)
        failed += r.returncode != 0
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
