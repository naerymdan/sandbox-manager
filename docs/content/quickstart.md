---
title: Get started
section: Start here
order: 30
description: From a fresh install to Claude Code running in your first sandbox.
---

This page takes you from a fresh [install](install.md) to an agent running in
your first sandbox. It takes about ten minutes, most of which is the first
bootstrap.

## 1. First run: the machine-level setup

```console
$ msbctl
```

The first time `msbctl` runs on a machine with nothing configured, it offers a
short walk-through. Each step is optional, and `msbctl setup` returns to any of
them later:

- **Git identities**: the names and emails a sandbox can commit as, and
  optionally an SSH key to sign with. They're applied inside the guest with
  `git config --system`, so a repo's own identity still wins.
- **Claude login**: a long-lived token from `claude setup-token`, stored in
  `~/.config/msb/secrets/global.env` (mode 0600). Sandboxes get a placeholder
  for it; the real token never enters a VM.
- **Your network**: egress groups for your own machines, such as a Git server
  or a package mirror on your LAN.
- **New-sandbox defaults**: where projects live, the default cpus and memory,
  which identity to use.

> **Tip:** Prefer a GitHub *noreply* address for anything that can reach a
> public repo. It attributes commits to your account without publishing a real
> address. Find yours at <https://github.com/settings/emails>.

## 2. Register a project

```console
$ msbctl add myproject
```

A bare name resolves under your workspaces folder (`~/workspaces` by default),
and the folder is created if it's missing. A path that states its location is
taken as written: `/srv/thing`, `~/src/thing`, `./thing`.

The wizard then asks, in order:

1. **Sandbox name**: lowercase letters, digits and dashes. It defaults to the
   folder name.
2. **GitHub repo**: detected from the checkout's `origin`. If the folder is
   empty, it offers to clone the repo into a subfolder over SSH.
3. **Git identity** and **SSH keys**: which keys from your host agent this
   sandbox may use. Nothing is ticked by default.
4. **Features and agents**: what the project needs, not raw egress rules.
   Ticking `python` brings the PyPI egress group *and* the toolchain packages.
   Features are pre-ticked from the repo's languages on GitHub.
5. **Resources and disks**: cpus, memory, the root disk size and, for podman,
   a container disk.
6. **Package caches, extra folders and secrets**: all optional.
7. **Image**: offered pinned by digest, so a moving tag can't change the
   sandbox underneath you.
8. **GitHub token**: a fine-grained PAT for this one repository, read straight
   into a 0600 file. It's never echoed and never on a command line.

Nothing is started yet. The wizard writes three things:

| File | What | Committed? |
| --- | --- | --- |
| `<project>/.msb/sandbox.toml` | the portable policy: egress groups, packages, resources | yes, if the project folder is the checkout |
| `<project>/.msb/dev.yaml` | the `msb --conf` file: image, cpus, memory | yes, likewise |
| `~/.config/msb/sandboxes/<name>.toml` | the machine-local entry: host path, identity, keys, mounts | never |

### The GitHub token

GitHub has no API for creating fine-grained tokens, so this one step is manual,
once per project. Create one at
<https://github.com/settings/personal-access-tokens/new> with exactly:

| Setting | Value |
| --- | --- |
| Repository access | Only select repositories → this one |
| Contents | Read and write |
| Pull requests | Read and write |
| Actions | Read-only |
| Metadata | Read-only (forced) |

Inside the sandbox, `GH_TOKEN` is a placeholder. The real value is swapped in
on the host, in request headers only, for `github.com` and `api.github.com`.
`git push` over SSH doesn't use it at all; that goes through the
[filtered SSH agent](credentials.md#ssh-the-filtered-agent).

## 3. Start it

```console
$ msbctl start myproject
```

The first start creates the VM and runs the **bootstrap** inside it, once. That
installs the base packages, node, `gh`, Claude Code and whatever the features
asked for. It takes a few minutes. The bootstrap deliberately doesn't stop at
the first failure: it reports every step that failed together at the end, so
a missing egress rule shows up in one pass rather than one round trip at a
time.

Later starts take seconds: the VM keeps its state between stop and start.

## 4. Work in it

```console
$ cd ~/workspaces/myproject
$ msbctl shell
```

Inside a registered project folder you can leave the sandbox name out (see
[Everyday use](everyday.md)). The shell starts in `/work` (or the host's own
path, if you chose that when registering), which is your project folder,
shared from the host. Files the guest writes there belong to you on the host.

Run the agent:

```console
$ claude
```

It's already logged in through the placeholder token, already has the central
`CLAUDE.md`, and can push to GitHub through the filtered SSH agent.

## 5. Stop it

```console
$ msbctl stop
```

Stopping keeps everything: installed packages, the Claude state, your files.
An idle running sandbox costs about 300 MB, so leaving a few running is cheap.

## Where next

- [Everyday use](everyday.md): the picker, `exec`, and the current-folder
  shortcuts.
- [Network & egress](egress.md): what to do when something is refused.
- [Credentials & SSH](credentials.md): more tokens, key selection, commit
  signing.
