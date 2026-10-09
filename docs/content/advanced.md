---
title: Advanced usage
section: Guides
order: 50
description: Observe mode, caches and podman, resizing, version pins, renaming and moving, extra folders, project setup.
---

## Observe mode: building an allowlist

msb doesn't record what it *denies*, only what it *allows*. So the way to learn
what a sandbox actually needs is a round trip:

```console
$ msbctl observe . on --rebuild       # stop blocking, start recording
$ #  … use the sandbox normally for a while …
$ msbctl observe .                    # every host it reached, and which no rule covers
$ msbctl allow . <the ones that belong>
$ msbctl observe . off --rebuild      # back to deny-by-default
```

While observe mode is on, the sandbox is created with egress allowed by
default, **no** `--net-rule` at all, debug logging and DNS rebind protection
off: nothing is blocked and every host is written to the sandbox's runtime
log. Your rules stay in the config and keep being curated; they're just not
emitted. The report prints a ready-made `msbctl allow` line for whatever no
rule covers.

The mode lives in the **registry entry only**, never in `.msb/sandbox.toml`.
That file is committed, and an unfiltered sandbox must never ship to everyone
who clones the project.

The report also shows **secret-policy blocks**: requests msb killed because
they carried a placeholder somewhere substitution isn't allowed. Those are
logged even in normal (enforce) mode.

## Package caches

Each package manager can get its own disk for its download cache: `npm`,
`bun`, `python` (pip), `rust` (cargo registry) and `go` (module cache).

```toml title=".msb/sandbox.toml"
[caches]
npm = "5G"
```

Each is a named disk volume, `<sandbox>-cache-<key>`. It's as fast as the root
disk, capped at its size, **kept** across rebuilds and deleted by `purge`.

```console
$ msbctl cache .                # usage per cache
$ msbctl cache . clear npm      # empty one (all of them without a key)
```

A volume's size is fixed when it's first created. Change it in the config later
and msbctl keeps the existing size and warns you; `msbctl cache . clear` then
recreates it at the new size.

> **Note:** The caches mount at `/mnt/cache/<key>`, and the bootstrap symlinks
> the tool's usual directory (such as `/root/.npm`) to it. That detour is
> deliberate: msb refuses a named-volume mount whose guest path contains a dot.

## Containers inside a sandbox (podman)

The `podman` feature installs podman and opens the `containers` egress group.
podman then needs somewhere to keep images. The root filesystem is an overlay
that podman's overlay driver can't sit on, so pick one of:

- **a container disk** (`containers_disk = "20G"`): a named volume at
  `/var/lib/containers`. Fast, and pulled images survive rebuilds. This is the
  recommended option.
- **fuse-overlayfs** (`containers_storage = "fuse-overlayfs"` under
  `[bootstrap]`, plus the package): no extra disk, slower.

With neither, podman falls back to `vfs`: slow, and about three times the disk.
The wizard asks.

## Resizing without a rebuild

```console
$ msbctl resize . --cpus 8 --memory 16G     # needs a restart; asks first
$ msbctl resize . --root-disk 32G           # grows live; shrinking is refused
```

`resize` uses `msb modify`, so the sandbox keeps its state. The new values are
written to the registry entry, so a later rebuild reproduces them.

## Versions and updates

Component versions are pinned in `defaults.toml` under `[versions]` (node's
major, `gh`, `gitleaks`, `bun`), and the image is pinned by digest.

```console
$ msbctl ls --refresh                  # check upstream (cached for 6 hours)
$ msbctl update . -c claude gh apt     # in place
```

`update` records what it installed in the registry entry's `[versions]` table,
so the next rebuild reproduces it rather than silently going back. Delete an
entry there to return to the default. The **image** can't be updated in place:
change its digest in `.msb/dev.yaml`, then rebuild.

The upstream checks use the anonymous GitHub API (60 requests an hour). A
`GH_TOKEN` in `secrets/global.env` is used for them if present.

## Renaming a sandbox, or moving its project

```console
$ msbctl rename old-name new-name
$ msbctl move . ~/src/the-new-place
```

msb can rename neither a sandbox nor a volume, so a **rename** removes the VM
and creates it again under the new name, at the cost of a rebuild.
Everything msbctl keeps under the name moves with it: the registry entry, its
secrets, the Claude state and the version cache. Package caches and container
images are kept too: the entry's `volumes` key keeps pointing at the existing
disks, and that old name stays reserved until you rename back.

A **move** points the sandbox at a different folder, for example after you
moved the checkout on disk. The old folder may already be gone. If the new
folder has no `.msb/`, msbctl offers to copy it over, re-detects the GitHub
repo, and offers the rebuild the new mount needs.

Both are also in `msbctl edit` → "Name & folder".

## Where the project appears in the sandbox

By default the project is mounted at `/work`. `msbctl add` asks where it
should appear, and `msbctl edit` → "Name & folder" changes it:

- **the same path as on the host.** Absolute paths in compiler errors, stack
  traces and an agent's output are then valid on both sides, so your editor (or
  an ACP client) can open them as they are. A `msbctl move` takes the mount
  along with it.
- **`/work`.** This keeps your folder layout and username out of the guest.
- **any other absolute path.** Not inside a system folder (`/usr`, `/etc`, …)
  and not over a whole one like `/home` or `/tmp`.

It's stored as `guest_path` in the registry entry (`"host"`, `"/work"` or the
path), never in `.msb/sandbox.toml`, because a host path is one person's
machine. Set the default for new sandboxes in `msbctl setup` → "Defaults for
new sandboxes". A change needs a rebuild, and Claude Code keeps its sessions
and memory per path, so the ones from the old path stay behind.

## Extra folders

```console
$ msbctl mount . ~/reference                      # read-only at /mnt/reference
$ msbctl mount . ~/datasets:/data --rw --rebuild  # read-write, at /data, now
```

Extra host folders are read-only unless you ask, and read-write ones show your
own ownership, like `/work`. Host paths are machine-local, so they're stored in
the registry entry, never in the project. Like every mount, they're fixed at
create time.

## Reaching a server in the sandbox

```console
$ msbctl port . 8080 --rebuild        # http://localhost:8080 reaches :8080 inside
$ msbctl port . 3000:5173             # host 3000 to a dev server on 5173
$ msbctl port .                       # list them; --rm 8080 removes one
```

Inside, the server has to listen on `0.0.0.0` — `python3 -m http.server 8080
--bind 0.0.0.0`, `vite --host 0.0.0.0` — because msb connects to the guest's
own address and a server bound to `localhost` is never reached. On the host the
port binds to `127.0.0.1` only; `0.0.0.0:8080:8080` opens it to your network,
and `msbctl` says so. The connection comes in rather than going out, so the
egress rules don't apply. Ports are stored in the registry entry, not the
project, since a host port is one machine's to hand out; `msbctl` warns when
another sandbox already publishes the same one. They're fixed at create time,
and `msbctl edit` → "Published ports" changes them too.

## Project setup and environment

```toml title=".msb/sandbox.toml"
[bootstrap]
packages = ["postgresql-client"]       # extra apt packages
script   = "scripts/sandbox-setup.sh"  # run last, inside the guest, from the project folder

[env]
SOME_PROJECT_FLAG = "1"                # merged over the machine-wide [env]
```

The setup script runs once, at create time, after everything else, for things
like `npm ci`. A failure is reported, not fatal. Environment variables are
create-time, like mounts.

## Your network

For hosts on your LAN (a Git server, a package mirror), define a group once in
`config.toml`, or use `msbctl setup` → "your network". If those names resolve
to private addresses, list the group under `private_dns_groups`, so projects
that use it get `allow_private_dns = true` automatically. See
[DNS resolution is part of the rule](egress.md#dns-resolution-is-part-of-the-rule).

## Your CLAUDE.md additions

`~/.config/msb/CLAUDE.local.md` is appended to msb-manager's shipped
instructions, and the result is copied into every sandbox's `~/.claude` on each
start. Edit it from the main menu ("edit your CLAUDE.md additions") or directly.
Editing the copy *inside* a sandbox does nothing: it's overwritten on the next
start.

Each sandbox's copy also ends with a short "This sandbox" section, written by
msbctl: one line per feature it has (podman, python, …). It's built from the current config on every start, so after
an edit that still needs a rebuild it describes the sandbox you'll get, not yet
the one that's running. `msbctl edit <name>` → "View the CLAUDE.md it gets"
shows the whole file as that sandbox will receive it.

## Autostart

Mark a sandbox to start whenever the picker opens:
`msbctl edit .` → "Identity & autostart". An idle sandbox costs about 300 MB,
and a running one is the only kind whose installed versions can be checked.
