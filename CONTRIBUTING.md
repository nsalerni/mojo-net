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

## Checks

```sh
pixi run test
pixi run example
pixi run compliance    # if you change socket or resolver behavior
```

Fork, branch from `main`, and keep pull requests focused. By contributing,
you agree that your contributions are licensed under
[Apache License 2.0](LICENSE).
