---
title: Install
section: Start here
order: 20
description: Requirements, the one-line installer, verifying a release, and installing from a checkout.
---

## Requirements

| What | Why |
| --- | --- |
| Linux with `/dev/kvm` | microsandbox is a libkrun microVM runtime, so this runs on a host, never inside a container |
| [`msb`](https://github.com/microsandbox/microsandbox) on `PATH` | the runtime itself. Developed against 0.7.6, re-checked on 0.7.7 |
| Python 3.11+ | `msbctl` uses only the standard library (`tomllib` needs 3.11). Nothing to pip install, ever |
| `git` | project detection, cloning |
| `fzf` *(optional)* | the full-screen menu and the picker; without it you get numbered prompts |
| a terminal emulator *(optional)* | for the desktop entry: konsole, alacritty, foot, gnome-terminal and xterm are detected |

## One-line install

```console
$ curl -fsSL https://github.com/runoverlabs/sandbox-manager/releases/latest/download/get.sh | sh
```

`get.sh` finds the latest release, downloads it, **verifies its sha256** against
the checksums published with it, and runs the installer inside it. If the
checksum doesn't match, nothing is installed. If an authenticated
[`gh`](https://cli.github.com) is on `PATH`, it also checks the tarball's
**build provenance** (see [verifying a release](#verifying-a-release)) and
refuses to install if that check fails.

To pin a release or pass installer options:

```console
$ curl -fsSL .../get.sh | sh -s -- --version v0.2.2     # a specific release
$ curl -fsSL .../get.sh | sh -s -- --prefix ~/tools      # flags after -- go to install.sh
```

| `install.sh` option | Effect |
| --- | --- |
| `--prefix DIR` | where versions are kept (default `~/.local/share/msb-manager`) |
| `--bin-dir DIR` | where `msbctl` and `msb-picker` are linked (default `~/.local/bin`) |
| `--no-desktop` | skip the "Sandboxes" desktop entry |
| `--uninstall [--yes]` | remove what the installer put there; your config and sandboxes stay |

### What a package install does

The release is copied to `~/.local/share/msb-manager/versions/<version>/`,
`current` points at it, and `~/.local/bin/msbctl` and `msb-picker` link
through `current`. An upgrade is therefore one atomic switch, and the previous
version stays around for rolling back. The installed tree is real files only:
the installer refuses a release that contains symlinks.

```console
$ msbctl self-update                     # the latest release
$ msbctl self-update --version v0.2.2    # a specific one
$ ~/.local/share/msb-manager/current/install.sh --uninstall
```

## Verifying a release

A checksum published next to a tarball only proves the download wasn't
damaged: anyone who could replace the tarball could replace the checksum too.
So each release is also **attested**: a Sigstore-signed statement, made by this
repository's release workflow, of exactly which commit built which file. You
can check it yourself:

```console
$ gh attestation verify msb-manager-0.2.2.tar.gz --repo runoverlabs/sandbox-manager \
    --signer-workflow runoverlabs/sandbox-manager/.github/workflows/release.yml
```

`get.sh` and `msbctl self-update` run this check automatically when `gh` is
logged in, refuse to install if it fails, and tell you plainly when only the
checksum could be checked. Set `MSB_MANAGER_SKIP_ATTEST=1` to skip it.

The attestation is also attached to each release (from 0.2.4 on) as
`msb-manager-X.Y.Z.intoto.jsonl`. Download it beside the tarball and pass it
with `--bundle` to check against that file instead of GitHub's attestation API:

```console
$ gh attestation verify msb-manager-0.2.4.tar.gz --repo runoverlabs/sandbox-manager \
    --bundle msb-manager-0.2.4.intoto.jsonl \
    --signer-workflow runoverlabs/sandbox-manager/.github/workflows/release.yml
```

## From a checkout (development)

```console
$ git clone https://github.com/runoverlabs/sandbox-manager msb-manager
$ cd msb-manager
$ ./install.sh                  # --dev is implied inside a git checkout
```

Dev mode symlinks the two commands into the checkout, so `git pull` updates the
tool with no reinstall. `msbctl self-update` tells you to `git pull` instead.
Everything else works the same in both modes.

## What is yours, and what ships

The installer seeds two files that **you** own. They're real files, never links
into the installed tree, and no install or upgrade overwrites them:

- `~/.config/msb/config.toml`: your overrides on top of the shipped
  `defaults.toml`, such as egress groups, version pins and default resources.
  Keep it short; `msbctl config` prints the merged result and where each value
  came from. See the [configuration reference](configuration.md).
- `~/.config/msb/CLAUDE.local.md`: your additions to the `CLAUDE.md` every
  sandbox gets. On each start msb-manager's own text and yours are put together
  into `~/.local/state/msb/profile/`, and that's what sandboxes see, read-only.

`defaults.toml` itself ships with msb-manager and is read straight from the
installed tree, so an upgrade updates it. Never edit it; put your changes in
`config.toml`.

Next: [Get started](quickstart.md).
