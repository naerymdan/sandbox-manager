---
title: Troubleshooting
section: Guides
order: 60
description: Refused connections, dropped API connections, NXDOMAIN on your LAN, and other failures that look like something else.
---

Most failures here are disguised: they look like an outage or a bug, and are
actually policy doing its job. Start with `msbctl show` for the sandbox, which
lists every rule it emits.

## "connection refused" / a host is unreachable

**It's a missing egress rule until proven otherwise.** Don't retry, and don't
reach for a proxy or another mirror. Find the exact host and port that was
refused, then:

```console
$ msbctl allow . that.host.example        # :443
$ msbctl allow . that.host.example:22     # another port
$ msbctl rebuild .
```

If the failing URL is `http://`, use its `https://` form instead: plain HTTP is
denied for every sandbox, and a project can't override that (see
[first-match-wins](egress.md#rules-are-first-match-wins)).

If you can't tell what's being refused, use
[observe mode](advanced.md#observe-mode-building-an-allowlist).

## The bootstrap reports "REQUIRED, FAILED"

Almost always a missing rule, not a broken installer. The bootstrap lists every
failed step at once. Read the error above the summary for the host it couldn't
reach. Before creating a sandbox, msbctl also warns about install hosts the
rules don't cover; the usual missing groups are `npm` and `claude`.

## Claude Code: `API Error: Connection dropped (ECONNRESET)`

A fresh session works, then every request fails, permanently. This is the
**secret policy**, not the network: the agent has read a token placeholder
(`$MSB_GH_TOKEN`) at some point, and now carries it in every request body,
which msb kills.

Sandboxes created by current msb-manager let the placeholder travel to the
agent's own endpoints, so this shouldn't happen. If it does:

```console
$ msbctl observe .          # lists secret-policy blocks, even in enforce mode
$ msbctl rebuild .          # picks up the current bindings
```

Allowing the host changes nothing here, because it's not a network block.

## Claude Code: "Unable to connect to Anthropic services"

The sandbox can't reach `platform.claude.com`, which Claude Code contacts on
startup. Both hosts in the `claude` group are needed: check the project's
`rule_groups`.

## Claude Code isn't logged in

The sandbox's Claude token isn't stored: `msbctl show <name>` says which one it
uses and flags it as NOT STORED. Run `msbctl setup` → "Claude login" to add it
(or `claude setup-token` on the host and paste the result), or pick a token you
have with `msbctl edit <name>` → "Claude token", then restart the sandbox.

## A name on my LAN returns NXDOMAIN

msb drops DNS answers that point at private addresses (DNS rebind protection),
and the result looks exactly like a missing rule: NXDOMAIN, then a refused
connection. Set `allow_private_dns = true` in the project's
`.msb/sandbox.toml` and rebuild. See
[DNS resolution is part of the rule](egress.md#dns-resolution-is-part-of-the-rule).

## `git commit`: "Please tell me who you are"

The repo has no identity of its own, and there's no host-wide git config inside
a microVM. Pick an identity: `msbctl edit .` → "Identity & autostart". It
applies on the next start.

## Commits aren't signed

The identity names a `signing_key`, but this sandbox isn't allowed that key.
`msbctl show` says so under "Credentials". Allow it with `msbctl keys .`.

## `.git/index` disappears for a few seconds after a git command

`git status` right after a `git reset`, `add` or `commit` in the sandbox shows
every file deleted and untracked, then recovers about 5 seconds later. A host
editor that watches the repo (zed, or any IDE that polls git) is running
`git diff` on the host. The index records each file's stat details, which
differ between the guest and the host, so the host's git rewrites the index
straight after the sandbox does. The sandbox's view of the file then goes stale
until it expires.

msbctl prevents this by setting `core.checkStat=minimal` in the project's own
`.git/config` on every start, unless the repo already sets `core.checkStat`.
Git then compares only mtime and size, which both sides agree on. For a repo
that isn't the project's top folder, or before the next start, run
`git config core.checkStat minimal` in it. `GIT_OPTIONAL_LOCKS=0` for the
editor doesn't help: `git diff` ignores it.

## podman: "boot ID differs from cached boot ID"

Every podman command fails like this after the sandbox restarts. Podman keeps
its runtime state in `/run` and expects a reboot to empty it, but inside a
sandbox `/run` is part of the disk and survives a stop/start.

msbctl clears that state when it starts the sandbox (`msbctl start`, `shell`,
`exec`, the picker), but only if it's left over from an earlier boot, so
running containers are never touched. Images, volumes and container
definitions are kept. If you started the sandbox some other way (with `msb`
directly), run `msbctl shell .` once, or delete what podman names yourself:
`rm -rf /run/containers /run/libpod`.

## `git push` over SSH fails

- Check that the key is selected: `msbctl keys .`.
- Check that it's loaded in your **host** agent (`ssh-add -l`). msbctl tries to
  load selected keys at start, and warns if it can't.
- Sandboxes created before the filtered agent existed need one `msbctl rebuild`.
- The host must already be in your `~/.ssh/known_hosts`: it's mounted
  read-only, so the sandbox can't add a new host.

## `/memory`, `git commit` or ctrl-g opens nothing

No editor was set, and the image's `code` command has no VS Code to hand off to
inside the VM. Sandboxes get `EDITOR=nano` by default. Older ones need a
rebuild, or `export EDITOR=nano` in the shell for now.

## Memory use creeps up to the ceiling and stays there

Guest page cache is never handed back on its own. It's harmless, and
`msbctl reclaim` fixes it in about a second.

## The sandbox lost something after a rebuild

A rebuild keeps your files, the Claude state, package caches and container
images, and reinstalls whatever the bootstrap installs. Anything you installed
by hand is gone. Put it in `[bootstrap] packages` or the project's setup
`script` so it comes back every time.

## `msbctl` says "no /dev/kvm"

`msbctl` runs on the host. It can't run inside a container, or inside another
VM unless that VM has nested virtualization.
