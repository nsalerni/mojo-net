# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately via
[GitHub security advisories](https://github.com/nsalerni/mojo-net/security/advisories/new)
rather than public issues. You should receive a response within a week.

## Scope

mojo-net provides TCP, UDP, Unix domain socket, DNS, and readiness polling.
It does not authenticate peers or encrypt TCP traffic. Use
[mojo-tls](https://github.com/nsalerni/mojo-tls) when you need transport
security.

Reports about descriptor lifecycle, address handling, platform socket layouts,
or Poller event handling are in scope. The project has not had an external
security review.
