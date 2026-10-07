---
title: Configuration
section: Reference
order: 20
description: Every key in config.toml, .msb/sandbox.toml and the registry entry, and where files live.
---

Four TOML files, later ones winning. See
[How it works](how-it-works.md#the-four-configuration-layers) for how they
merge. The comments in the shipped `defaults.toml` and in the files the wizard
writes are the long-form documentation of every key; this page is the map.

## Files and directories

| Path | What |
| --- | --- |
| `<install>/defaults.toml` | the shipped defaults. Never edit; an upgrade replaces it |
| `~/.config/msb/config.toml` | your overrides |
| `~/.config/msb/CLAUDE.local.md` | your additions to every sandbox's `CLAUDE.md` |
| `~/.config/msb/sandboxes/<name>.toml` | one registry entry per sandbox |
| `~/.config/msb/secrets/global.env` | the Claude token, and an optional `GH_TOKEN` for version checks (0600) |
| `~/.config/msb/secrets/<name>.env` | that sandbox's tokens (0600) |
| `<project>/.msb/sandbox.toml` | the project's portable policy |
| `<project>/.msb/dev.yaml` | the file passed to `msb --conf`: image, cpus, memory |
| `~/.local/state/msb/claude/<name>/` | that sandbox's `~/.claude` |
| `~/.local/state/msb/profile/` | the assembled `CLAUDE.md`, mounted read-only |
| `~/.local/state/msb/agent/` | the SSH-agent filters' sockets and logs |
| `~/.local/state/msb/versions.json` | the cached version checks |

`MSB_CONFIG_DIR` and `MSB_STATE_DIR` move the two roots.

## config.toml

Keep it short: a value copied here from `defaults.toml` stops following the
shipped one. Tables merge with the shipped ones key by key; anything else,
including a whole egress group, replaces the shipped value.

### `[defaults]`

| Key | Default | Meaning |
| --- | --- | --- |
| `workspaces` | `"~/workspaces"` | where a bare name given to `msbctl add` resolves. `""` resolves against the current directory |
| `image` | a pinned devcontainers Ubuntu digest | the image a new sandbox starts from |
| `cpus` | `4` | |
| `memory` | `"8G"` | a ceiling, not a reservation |
| `root_disk` | `"16G"` | the writable root disk |
| `rule_groups` | `["github", "claude"]` | groups a new sandbox gets on top of `base` |
| `egress_mode` | `"enforce"` | `"observe"` stops blocking (per sandbox is better: `msbctl observe`) |
| `private_dns_groups` | `[]` | groups whose names resolve to private addresses; projects using one get `allow_private_dns` |
| `claude_auth` | `"secret"` | `"mount"` shares the host's real `~/.claude` instead. A fallback only |
| `identity` | `""` | the `[identities]` entry new sandboxes use |

### `[identities.<name>]`

```toml
[identities.public]
name        = "yourhandle"
email       = "12345+yourhandle@users.noreply.github.com"
signing_key = "ssh-ed25519 AAAA..."      # optional: sign commits with this key
```

Applied inside the guest with `git config --system`, the lowest of git's three
layers, so a repo's own identity still wins. See
[commit signing](credentials.md#commit-signing).

### `[rules]`

Egress groups, `name = [rule, …]`. Yours are added to the shipped ones; a
shipped name redefined here replaces that group entirely. See
[Network & egress](egress.md).

### `[env]`

Environment variables every sandbox gets. The shipped set turns off telemetry,
error reporting and feedback prompts, and sets `EDITOR = "nano"`. Projects
merge their own over these. Fixed at create time.

### `[versions]`

Component pins for the bootstrap: `node` (major), `gh`, `gitleaks`, `bun`. A
sandbox's own `[versions]` overrides these.

### `[version_check]`

| Key | Default | Meaning |
| --- | --- | --- |
| `ttl_hours` | `6` | how long upstream version checks are cached |
| `use_global_token` | `true` | use `GH_TOKEN` from `secrets/global.env` for them, if present |

### `[secret_presets.<name>]`

What `msbctl secret add` offers. Shipped: `npm`, `dockerhub`, `ghcr`, `pypi`,
`crates`.

```toml
[secret_presets.mytool]
env   = "MYTOOL_TOKEN"
hosts = ["api.mytool.example"]
help  = "https://mytool.example/settings/tokens"
usage = "mytool login --token \"$MYTOOL_TOKEN\""
```

## .msb/sandbox.toml

The project's policy. It never contains a host path, a token or a sandbox
name, so it's safe to commit.

| Key | Meaning |
| --- | --- |
| `rule_groups` | egress groups, on top of `base` |
| `extra_rules` | one-off rules, emitted last |
| `allow_private_dns` | accept DNS answers that point at private addresses |
| `secret_binds` | extra secrets, as `ENV[:OPTIONS]@HOST[,HOST]`; values live in `secrets/<name>.env` |
| `cpus`, `memory`, `root_disk` | resources; omit to use the defaults |
| `containers_disk` | a disk for `/var/lib/containers`, kept across rebuilds |
| `identity` | an `[identities]` name this project commits as |
| `[env]` | extra environment variables, merged over the machine-wide set |
| `[caches]` | `key = "size"` per package manager: `npm`, `bun`, `python`, `rust`, `go` |
| `[secrets] github` | bind this project's `GH_TOKEN` (default: true when it has a GitHub repo) |

### `[bootstrap]`

| Key | Meaning |
| --- | --- |
| `packages` | extra apt packages |
| `claude` | install Claude Code (default true) |
| `bun`, `gitleaks` | install these (default false) |
| `containers_storage` | `"fuse-overlayfs"` for podman without a container disk |
| `script` | a project script run last, inside the guest, from `/work` |

## The registry entry

`~/.config/msb/sandboxes/<name>.toml` is machine-local and never committed.
Any key it sets overrides the project's file.

| Key | Meaning |
| --- | --- |
| `name`, `project` | the sandbox's name and the absolute path of its project folder |
| `repo` | `owner/name` on GitHub, for the token binding and the picker |
| `identity` | an `[identities]` name; applied at every start |
| `autostart` | started when the picker opens |
| `ssh_keys` | key fingerprints this sandbox may use. Absent means all, `[]` means none |
| `mounts` | extra folders, as `"HOST[:GUEST][:ro\|rw]"` |
| `egress_mode` | `"observe"` while measuring; only ever set here, never in the project |
| `volumes` | the disk-volume prefix, set by `msbctl rename` to keep the old disks |
| `image`, `cpus`, `memory`, `root_disk`, `conf`, `rule_groups`, `extra_rules` | per-machine overrides |
| `[versions]` | what `msbctl update` installed, so a rebuild reproduces it |
