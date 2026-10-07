---
title: Overview
section: Start here
order: 10
description: msb-manager runs coding agents in per-project microVMs with deny-by-default egress and credentials that never enter the VM.
---

![msb-manager](assets/brand/msb-manager-mark-dotmatrix-dark.svg)

**msb-manager** runs coding agents against your real repositories inside
[microsandbox](https://github.com/microsandbox/microsandbox) microVMs, without
giving them your network or your tokens. One sandbox per project, managed by a
single command, `msbctl`, and a picker.

```console
$ msbctl add myproject          # register it: a short wizard
$ msbctl start myproject        # create the VM and bootstrap it, once
$ cd ~/workspaces/myproject
$ msbctl shell                  # a shell in this folder's sandbox; run claude there
```

## What you get

**Deny-by-default egress, per host and per port.** A sandbox reaches the hosts
its project needs and nothing else. Egress rules come in named groups (`github`,
`npm`, `python`, `go`, …) that a project picks from. A sandbox that needs SSH to
one machine gets that port on that machine, not the whole machine.

**Tokens never enter the VM.** Inside the sandbox, `$GH_TOKEN` holds a placeholder.
The real value is swapped in *on the host*, in request headers only, and only for
the hosts it was issued for. `gh api user` works; the token can't be read from
inside the sandbox, so it can't leak from there either.

**SSH without keys in the guest.** The sandbox talks to a per-sandbox filter in
front of your SSH agent. It can list and sign with only the keys you picked,
which lets it push over SSH and sign commits. The private keys never cross over.

**One central `CLAUDE.md`.** Every sandbox gets msb-manager's own instructions
plus your additions, copied in on each start from a read-only mount. Each sandbox
has its own `~/.claude`, so none of them holds your real Claude credentials or
another project's transcripts.

**Config that travels with the repo.** Egress groups, packages and resource
limits live in the project's `.msb/` and are committed with it. Host paths and
tokens stay in `~/.config/msb/` on your machine.

**No dependencies.** `msbctl` is one Python file that uses only the standard
library, plus the `msb` binary. Nothing from pip, nothing to break after a year
of not being touched.

## How it fits together

```text title="the picture"
 host                                          microVM (one per project)
 ──────────────────────────────────            ─────────────────────────────────
 msbctl ── creates/starts ───────────────────▶ /work      ← your project folder
 ~/.config/msb/    your config, tokens         ~/.claude  ← its own state
 ssh-agent ◀── filter (only picked keys) ◀──── git push / commit signing
 msb egress: rules + secret substitution ◀──── every outbound connection
            │
            └─▶ the internet, only where a rule allows
```

The VM sees your project at `/work`, with your own file ownership, so whatever
the agent writes is yours on the host. Everything else stays on the host: your
config, your tokens and your keys.

## Where to go next

- New here? [Install](install.md), then [Get started](quickstart.md).
- Already running a sandbox? [Everyday use](everyday.md) covers the commands
  you'll type every day.
- Something refused a connection? Read [Network & egress](egress.md), then
  [Troubleshooting](troubleshooting.md).
- Looking up a flag? See the [command reference](commands.md) and the
  [configuration reference](configuration.md).

> **Tip:** Pointing an agent at these docs? Every page has a Markdown copy
> beside it (`install.md` next to `install.html`), [`llms.txt`](llms.txt)
> indexes them, and [`llms-full.txt`](llms-full.txt) is all of them in one
> file.

> **Note:** msb-manager is young and developed for one operator's machine
> (Fedora, `msb` 0.7.6 and 0.7.7). It's small, has no dependencies and is
> commented for whoever has to debug it at 2am, but it hasn't been run widely.
> Issues and PRs are welcome, especially from other distros and newer `msb`
> versions.
