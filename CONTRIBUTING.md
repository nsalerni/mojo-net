# Contributing to mojo-net

Thanks for looking at the project. Socket behavior is checked against
CPython's `socket` module.

## Setup

```sh
curl -fsSL https://pixi.sh/install.sh | sh
git clone https://github.com/nsalerni/mojo-net.git
cd mojo-net
pixi install
pixi run test
```

## Style

- Public APIs follow the
  [Mojo docstring style](https://github.com/modular/modular/blob/main/mojo/stdlib/docs/docstring-style-guide.md).
- This repo targets Mojo 1.0: `def` only (no `fn`), `comptime` not `alias`,
  `std.`-prefixed imports, and explicit `.copy()` / `^` moves. Host names,
  paths, and other borrowed text on public constructors take `StringSpan`.
  Tests are plain executables run by `tools/run_tests.py` (`mojo test` no
  longer exists).

## Checks

```sh
pixi run test
pixi run example
pixi run compliance    # if you change socket or resolver behavior
```

Fork, branch from `main`, and keep pull requests focused. By contributing,
you agree that your contributions are licensed under
[Apache License 2.0](LICENSE).
