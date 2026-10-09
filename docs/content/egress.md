---
title: Network & egress
section: Guides
order: 20
description: Rule groups, the rule grammar, the three properties that are easy to get backwards, and adding hosts.
---

Every sandbox is **deny-by-default**. A connection gets out only if a rule
allows it, and the rules are built from named groups that each project picks.

## Rule groups

A group is a named list of rules. msb-manager ships these in `defaults.toml`:

| Group | Allows |
| --- | --- |
| `base` | DNS, the Ubuntu mirrors over HTTPS, and a **deny** of plain HTTP. Always applied, always first |
| `github` | github.com (HTTPS and SSH), the API, release assets, raw content, Actions logs, attestation verification |
| `claude` | `api.anthropic.com` and `platform.claude.com`. Claude Code needs both |
| `npm` | the npm registry and NodeSource |
| `bun` | the GitHub release assets bun is installed from |
| `python` | PyPI |
| `rust` | crates.io |
| `go` | the Go module proxy and checksum database |
| `containers` | Docker Hub (all three hosts it needs), ghcr.io, codeberg.org |
| `playwright` | Playwright's browser downloads (the `browsers` feature) |

New sandboxes start with `github` and `claude`, and the wizard adds whatever
the chosen features need. A project lists its groups in `.msb/sandbox.toml`:

```toml title=".msb/sandbox.toml"
rule_groups = ["github", "claude", "npm"]
extra_rules = ["allow@mirror.example.com:tcp:443"]   # one-offs, emitted last
```

Your own groups go in `~/.config/msb/config.toml` (`msbctl setup` → "your
network" writes them for you):

```toml title="~/.config/msb/config.toml"
[rules]
# By address and port: precise, and safe to use for SSH.
my-servers = [
    "allow@10.0.0.10:tcp:22",
]
# By name over HTTPS. A suffix doesn't cover the apex, so list both.
my-services = [
    "allow@*.example.com:tcp:443",
    "allow@example.com:tcp:443",
]
```

## The rule grammar

```text
<action>[:<direction>]@<target>[:<proto>[:<ports>]]

allow@github.com:tcp:443          a hostname, HTTPS
allow@10.0.0.10:tcp:22            an address and one port
deny@public:tcp:80                a class of addresses
allow@dns                         DNS itself
```

## Three properties that are easy to get backwards

### Rules are first-match-wins

A leading deny can't be undone by appending an allow later. That's why `base`
is always emitted first, and why nothing a project writes can come before it.
In particular, **a plaintext :80 allow can't be added from a project**: the
`base` deny has already matched by the time the project's rule is considered.
Fix it with the `https://` URL; that almost always works.

### A hostname rule only means a hostname over HTTPS

On :443, msb's TLS interception reads the server name (SNI) from each
connection, so a name backed by a pool of addresses is fine. On any other port
nothing inspects the traffic, and the rule is enforced as *the addresses that
name resolved to*, which breaks against address pools. Prefer HTTPS everywhere.
For SSH, prefer a rule by address.

### DNS resolution is part of the rule

msb allows a connection based on the addresses *it* resolved from the allowed
names. A name it can't resolve fails exactly like a name you never allowed:
NXDOMAIN inside the guest, then a refused connection.

This bites on home and office networks. A name like `git.example.com` can be a
real public record pointing at `192.168.x.x`, and msb drops such answers as DNS
rebind protection. The fix is per project:

```toml title=".msb/sandbox.toml"
allow_private_dns = true
```

A group you list under `private_dns_groups` in your config gets this set
automatically by `msbctl add` and `msbctl edit`.

## Adding a host

When a connection is refused, treat it as policy first, not an outage. Then
add exactly the host and port that was refused:

```console
$ msbctl allow . registry.example.com          # HTTPS (:443)
$ msbctl allow . git.example.com:22            # a TCP port
$ msbctl allow . allow@10.0.0.5:tcp:5432       # a full rule
$ msbctl allow . pypi.example.com --rebuild    # and apply it now
```

`allow` appends to `extra_rules` in the project's `.msb/sandbox.toml` (or in
the registry entry, if that already overrides the list). Rules are fixed at
create time, so they take effect at the next `msbctl rebuild`.

If more than one project needs the same host, make it a group in your
`config.toml` instead and add the group to each project's `rule_groups`.

## Finding out what a sandbox needs

msb **never logs what it denied**, at any log level. It does log what it
allows. So the only way to learn what a sandbox needs is to stop blocking for a
while and write down where it goes. That's **observe mode**, covered in
[Advanced usage](advanced.md#observe-mode-building-an-allowlist).

> **Warning:** In observe mode nothing is blocked. Secrets stay protected
> (substitution still happens on the host and only to their named hosts), but
> the agent can reach anywhere. Turn it off as soon as you've collected what
> you need.
