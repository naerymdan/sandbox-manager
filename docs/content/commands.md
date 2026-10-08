---
title: Commands
section: Reference
order: 10
description: Every msbctl subcommand, its arguments and options.
---

`msbctl --help` and `msbctl <command> --help` are always current. This page
explains them.

## Naming the sandbox

- **`name`**: optional. Inside a registered project folder it defaults to that
  folder's sandbox. Elsewhere, it's required.
- **`name…`**: optional and repeatable. None, or `.`, means the current
  folder's sandbox; several names act on each in turn, and every failure is
  reported, not just the first.
- **`name|.`**: required, because another argument follows it. `.` is the
  shorthand for the current folder's sandbox.

See [Everyday use](everyday.md#the-current-folder-names-the-sandbox) for the
rules behind this.

## Registering and inspecting

### `msbctl add`

```text
msbctl add [dir]
```

Register a project with the setup wizard. Nothing is started. A bare name
resolves under your workspaces folder and is created if missing; a path
starting with `/`, `~`, `./` or `../` is taken as written. Without an argument
it asks, defaulting to the current directory. It also asks where the project
appears inside the sandbox: [`/work`, the host's own path, or a custom
one](advanced.md#where-the-project-appears-in-the-sandbox). See
[Get started](quickstart.md#2-register-a-project).

### `msbctl ls`

```text
msbctl ls [--refresh] [--porcelain] [--picker]
```

One line per sandbox: name, state, project, pending updates, autostart.
`--refresh` checks upstream versions first. `--porcelain` prints tab-separated
fields for scripts; `--picker` is the format `msb-picker` reads.

### `msbctl status`

```text
msbctl status [--quick]
```

One block per sandbox, as shown beside the menu: state, RAM and CPU, identity,
image, folder. `--quick` skips reading figures from inside each guest.

### `msbctl show`

```text
msbctl show [name]
```

Everything about one sandbox: resources, disks, extra folders, installed
versions, environment, every egress rule in the order it's emitted, and the
identity, keys and secrets bound to it.

### `msbctl config`

```text
msbctl config
```

The merged configuration (`defaults.toml` plus your `config.toml`), with where
each value comes from.

### `msbctl entry`

```text
msbctl entry [name]
```

Open the sandbox's registry entry (`~/.config/msb/sandboxes/<name>.toml`) in a
terminal editor.

## Lifecycle

### `msbctl start`

```text
msbctl start [name…]
```

Start a stopped sandbox, or create it if it doesn't exist yet. Creating runs
the bootstrap, once.

### `msbctl stop`

```text
msbctl stop [name…]
```

Stop it. Everything is kept.

### `msbctl rebuild`

```text
msbctl rebuild [name…]
```

Destroy and recreate. Needed after changing anything fixed at create time:
egress rules, mounts, the image, environment variables. Your files, the Claude
state, package caches and container images survive; packages installed by
hand don't. Doesn't ask first.

### `msbctl purge`

```text
msbctl purge [name…] [-y]
```

Destroy the sandbox and deregister it: the VM, its Claude state, its disk
volumes, its secrets file and its registry entry. Your project folder is never
touched. Lists exactly what it will delete, and asks once per sandbox unless
`-y` is given. Remember to revoke its GitHub token too.

### `msbctl rename`

```text
msbctl rename name|. new-name [-y]
```

Give a sandbox a new name. msb can't rename a VM, so this recreates it, like a
rebuild; settings, secrets, Claude state, caches and container images all move
with it. See [Advanced usage](advanced.md#renaming-a-sandbox-or-moving-its-project).

### `msbctl move`

```text
msbctl move name|. dir [--rebuild]
```

Point a sandbox at another project folder. `dir` is read as it is for `add`.
Offers to copy `.msb/` across if the new folder lacks it, and re-detects the
GitHub repo. The folder is mounted at create time, so this needs a rebuild:
`--rebuild` does it now.

### `msbctl resize`

```text
msbctl resize [name] [--cpus N] [--memory SIZE] [--root-disk SIZE] [-y]
```

Change resources and keep the sandbox's state. cpus and memory need a restart
(asks first unless `-y` is given); the root disk grows live and can't shrink.
With no options it asks.

### `msbctl reclaim`

```text
msbctl reclaim [name…]
```

Give the guest's page cache back to the host. Harmless, and takes about a
second.

## Working inside

### `msbctl shell`

```text
msbctl shell [name] [msb exec flags…]
```

An interactive login shell, with the SSH agent wired up, starting in the
subfolder of the project that matches your current directory (under `/work`,
or wherever [`guest_path`](advanced.md#where-the-project-appears-in-the-sandbox)
puts it). Starts a stopped
sandbox; never creates one. Flags after the name go to `msb exec` as they are
(see [Passing flags to `msb exec`](#passing-flags-to-msb-exec)).

### `msbctl exec`

```text
msbctl exec name|. [--] command…
msbctl exec [name|.] [msb exec flags…] -- command…
msbctl exec -- command…
```

Run one command in the sandbox, like `shell` but non-interactive. `exec -- cmd`
is the short form for the current folder's sandbox.

#### Passing flags to `msb exec`

`shell` and `exec` hand any flag they do not use themselves to `msb exec`
unchanged, so everything `msb exec --help` lists works. Put the flags after
the name, and for `exec` end them with `--`:

```text
$ msbctl shell -u root                      # this folder's sandbox, as root
$ msbctl exec myproject --timeout 5m -- make test
$ msbctl exec -e DEBUG=1 --no-tty -- ./run.sh
```

`-w`/`--workdir` replaces the matching subfolder of the project, and for `shell`,
`--no-tty` or `--stream` replaces the terminal it would otherwise allocate.

### `msbctl code`

```text
msbctl code [name]
```

Open your editor on the project folder, on the host: `$MSB_EDITOR`, default
`codium`.

## Changing a sandbox

### `msbctl edit`

```text
msbctl edit [name]
```

The setup wizard as a menu of sections, run one at a time against an existing
sandbox: name and folder, features and agents, resources, package caches,
container storage, extra folders, egress rules, SSH keys, GitHub token,
secrets, identity and autostart, or the files themselves in your editor. Applies
what it can immediately and offers one rebuild at the end for the rest.

### `msbctl allow`

```text
msbctl allow name|. target… [--rebuild]
```

Add egress rules. Each target is `host` (HTTPS, :443), `host:port` (TCP), or a
full rule such as `allow@10.0.0.5:tcp:5432`. Written to the project's
`extra_rules`. See [Adding a host](egress.md#adding-a-host).

### `msbctl observe`

```text
msbctl observe name|. [report|on|off] [--rebuild] [-y]
```

`on` stops blocking and records every host the sandbox reaches; `report` (the
default) reads that record back and prints the `msbctl allow` line for what no
rule covers; `off` restores deny-by-default. Turning it on asks first unless
`-y` is given. See [Observe mode](advanced.md#observe-mode-building-an-allowlist).

### `msbctl mount`

```text
msbctl mount name|. SRC[:DEST][:ro|rw] [--rw] [--rebuild]
```

Add an extra host folder. `DEST` defaults to `/mnt/<folder name>`; read-only
unless `rw` or `--rw` is given. Needs a rebuild.

### `msbctl secret`

```text
msbctl secret add name|.
msbctl secret ls  name|.
msbctl secret rm  name|. VAR
```

Tokens the sandbox can use but never see. `add` offers the presets or takes
your own binding. See [Credentials & SSH](credentials.md#more-secrets).

### `msbctl keys`

```text
msbctl keys [name] [--all]
```

Choose which keys from your SSH agent (and `~/.ssh`) the sandbox can list and
sign with. Takes effect immediately. `--all` removes the restriction.

### `msbctl cache`

```text
msbctl cache name|. [ls|clear] [key]
```

Show the package-cache disks, or empty one (or all of them, if no key is
given). See [Package caches](advanced.md#package-caches).

### `msbctl update`

```text
msbctl update [name…] [-c component…]
```

Update components in place, without a rebuild. Components: `claude` (the
default), `gh`, `gitleaks`, `bun`, `apt`. Versions installed this way are
recorded so a rebuild reproduces them. Run `msbctl ls --refresh` first for
`gh`, `gitleaks` and `bun`.

## The machine and msb-manager itself

### `msbctl setup`

```text
msbctl setup [--welcome]
```

Your machine-level settings as a menu: git identities, Claude login, your
network, new-sandbox defaults, or the config file itself. `--welcome` runs the
first-time walk-through.

### `msbctl self-update`

```text
msbctl self-update [--version vX.Y.Z]
```

Upgrade a packaged install to the latest release, or a given one, verifying it
the same way the installer does. In a git checkout it tells you to `git pull`.

## Environment variables

| Variable | Effect |
| --- | --- |
| `MSB_CONFIG_DIR` | config directory (default `~/.config/msb`) |
| `MSB_STATE_DIR` | state directory (default `~/.local/state/msb`) |
| `MSB_EDITOR` | the editor `msbctl code` opens (default `codium`) |
| `MSB_NO_AUTOSTART=1` | the picker doesn't start autostart sandboxes |
| `MSB_MANAGER_SKIP_ATTEST=1` | installer and `self-update`: skip the provenance check |
| `MSB_MANAGER_REPO`, `MSB_MANAGER_BASE_URL` | installer: another repository, or a mirror (`file://` works; needs `--version`) |
