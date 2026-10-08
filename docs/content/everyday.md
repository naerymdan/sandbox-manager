---
title: Everyday use
section: Start here
order: 40
description: The current-folder shortcuts, shell and exec, the menu and the picker.
---

## The current folder names the sandbox

Like `docker compose`, `msbctl` works out which sandbox you mean from where you
are. Inside a registered project folder, or any folder below it:

```console
$ msbctl shell                   # this folder's sandbox
$ msbctl exec -- make test       # run one command in it
$ msbctl exec . make test        # the same; "." means "this folder's sandbox"
$ msbctl stop                    # start, rebuild, update, reclaim and purge too
$ msbctl stop . other-sandbox    # "." mixes with names
$ msbctl allow . example.com     # "." where more arguments follow
```

It is designed never to guess:

- **The registry decides.** The sandbox is the registered one whose project
  folder contains your current directory. If projects are nested, the deepest
  one wins, the way git finds a repo. A `.msb/` folder on its own isn't enough:
  a fresh clone of a project that commits `.msb/` isn't registered on this
  machine.
- **The name can be left out only when it's the only argument.** Where
  another argument follows (`exec`, `allow`, `observe`, `mount`, …), the name
  is still required, and `.` is the shorthand for it. `.` can never be a sandbox
  name, so `msbctl observe on` can't silently mean a sandbox called "on".
- **It tells you what it picked.** On a terminal, a dim `name (~/path)` line
  goes to stderr. Piped output stays clean.
- **It stops when it can't decide.** Two sandboxes registered on the same
  folder, a `.msb/` with no registered sandbox, or a folder outside every
  project: each is an error that says what to do.

`shell` and `exec` also start in the matching subfolder: from `~/proj/src`
you land in `/work/src` (or in `~/proj/src` itself, if the sandbox uses the
[host's own path](advanced.md#where-the-project-appears-in-the-sandbox)).

## shell, exec, code

```console
$ msbctl shell myproject                  # bash -l, SSH agent wired up
$ msbctl exec myproject -- npm test       # one command
$ msbctl code myproject                   # your editor on the project, on the host
```

`shell` and `exec` start a stopped sandbox first, but they never *create* one:
creating is the one step that runs the bootstrap and fixes the network policy,
so it should never happen as a side effect. Use `msbctl start` (or
`msbctl rebuild`) for that.

`code` opens `$MSB_EDITOR` (default `codium`) on the project folder **on the
host**, detached from the terminal. The editor works on the same files the
sandbox sees.

## Looking around

```console
$ msbctl ls              # one line per sandbox: state, project, pending updates
$ msbctl status          # one block per sandbox, with RAM and CPU figures
$ msbctl show            # everything about one: resources, versions, every egress rule
$ msbctl config          # the merged configuration, and where each value came from
```

`msbctl show` is the first thing to read when a sandbox behaves strangely. It
lists the resources, disks and extra folders, the installed versions, the
environment, every egress rule in order, and the git identity, SSH keys and
secrets that are bound.

## The menu

Bare `msbctl` opens a menu: register a project, manage sandboxes, machine
setup, your `CLAUDE.md` additions, and refreshing version info. With `fzf`
installed it's a full-screen list with a live status sidebar; without it, a
numbered prompt offering the same actions.

## The picker

**Manage sandboxes** in the menu, `msb-picker`, and the **Sandboxes** desktop
entry all open the picker. It lists every registered sandbox with its state and
what's out of date inside it, and binds a key to each action:

| Key | Action |
| --- | --- |
| `enter` | open the editor on the project (`msbctl code`) |
| `t` | shell |
| `s` / `x` | start / stop |
| `e` | edit, one wizard section at a time |
| `u` | update claude, gh and apt packages |
| `l` | reclaim memory |
| `f` | refresh version info |
| `n` | register a new project |
| `R` / `D` | rebuild / purge (capitals, so a slip of the finger can't destroy anything) |
| `space`, `a` | select one, select all; most actions apply to every selected row |
| `j` / `k`, `q` | move, quit |

Sandboxes marked *autostart* are started when the picker opens, so their state
and versions are current by the time the list appears. Set
`MSB_NO_AUTOSTART=1` to skip that.

## Stop, start, rebuild

| Command | What survives |
| --- | --- |
| `msbctl stop` / `start` | everything: packages, state, files |
| `msbctl rebuild` | your files, the Claude state, package caches and container images. Packages installed by hand are lost; the bootstrap reinstalls its own |
| `msbctl purge` | nothing but your project folder. It asks first and lists exactly what it will delete |

Rebuild whenever something that is **fixed at create time** changes: egress
rules, mounts, the image, environment variables. cpus, memory and the root disk
don't need one ([`msbctl resize`](commands.md#msbctl-resize)).

## Keeping a sandbox current

```console
$ msbctl ls --refresh                 # check upstream versions
$ msbctl update -c claude gh apt      # update in place, no rebuild
```

What `update` installs is recorded in the sandbox's registry entry, so a later
rebuild reproduces it instead of quietly reverting.

## Memory

The VM's memory setting is a ceiling, not a reservation, but the guest's page
cache is never given back on its own, so a sandbox that builds a lot drifts up
to its ceiling and stays there. That's harmless, and takes about a second to
fix:

```console
$ msbctl reclaim
```
