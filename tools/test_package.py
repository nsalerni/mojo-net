#!/usr/bin/env python3
"""Build mojo-net and verify the installed package in a clean environment."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def run(*args: str, cwd: Path = ROOT, capture: bool = False) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout if capture else ""


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mojo-net-package-") as temp_name:
        temp = Path(temp_name)
        artifacts = temp / "artifacts"
        run(
            "pixi",
            "publish",
            "--clean",
            "--path",
            ".",
            "--target-dir",
            str(artifacts),
        )

        packages = list(artifacts.glob("mojo-net-*.conda"))
        if len(packages) != 1:
            raise RuntimeError(
                f"expected one mojo-net package, found {len(packages)}"
            )

        info = json.loads(run("pixi", "info", "--json", capture=True))
        manifest = temp / "pixi.toml"
        manifest.write_text(
            "\n".join(
                [
                    "[workspace]",
                    'channels = ["https://conda.modular.com/max", "conda-forge"]',
                    'name = "mojo-net-package-smoke"',
                    f'platforms = ["{info["platform"]}"]',
                    "",
                ]
            )
        )
        run(
            "pixi",
            "add",
            "--manifest-path",
            str(manifest),
            str(packages[0].resolve()),
            cwd=temp,
        )
        installed = json.loads(
            run(
                "pixi",
                "list",
                "--manifest-path",
                str(manifest),
                "--json",
                cwd=temp,
                capture=True,
            )
        )
        mojo_net = next(item for item in installed if item["name"] == "mojo-net")
        expected_runtime = "mojo-compiler >=1.0.0,<1.1.0"
        if expected_runtime not in mojo_net["depends"]:
            raise RuntimeError(
                f"expected runtime dependency {expected_runtime!r}, "
                f"found {mojo_net['depends']!r}"
            )
        if not any(item["name"] == "mojo-compiler" for item in installed):
            raise RuntimeError("Mojo compiler dependency was not installed")

        source = temp / "import_net.mojo"
        source.write_text(
            "\n".join(
                [
                    "from net import IPv4Address",
                    "",
                    "def main() raises:",
                    '    var address = IPv4Address("127.0.0.1", 443)',
                    "    if address.port != 443:",
                    '        raise Error("installed mojo-net package returned the wrong port")',
                    "",
                ]
            )
        )
        executable = temp / "import_net"
        run(
            "pixi",
            "run",
            "--manifest-path",
            str(manifest),
            "mojo",
            "build",
            str(source),
            "-o",
            str(executable),
            cwd=temp,
        )
        run(str(executable), cwd=temp)


if __name__ == "__main__":
    main()
