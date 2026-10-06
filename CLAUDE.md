# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`msb-manager` manages [microsandbox](https://github.com/microsandbox/microsandbox) microVMs as per-project agent sandboxes: deny-by-default egress, credentials substituted host-side (never inside the VM), one CLI/picker to start, stop, rebuild and update them. Developed against `msb` 0.7.6, host now on 0.7.7 (behaviour re-checked on both, except that **0.7.7 guests have no nested KVM** — `spikes/11-nested-kvm-by-version.sh` — so the dev sandbox can no longer run `msb` while the host is on 0.7.7); `msb --help` is more reliable than its published docs.

`msbctl` runs on the **host** and needs `/dev/kvm` plus the `msb` binary. As observed on 2026-10-05 (host on `msb` 0.7.6) the dev sandbox had nested KVM and could reach GitHub, so `msb` 0.7.6 can be installed here from its GitHub release (`install.sh` from the release assets, checksum-verified) and `msbctl` run for real against throwaway sandboxes. Docker Hub is *not* reachable (`index.docker.io:443` is refused), so load an image instead: `podman save --format oci-archive` then `msb load -i`, and create with `--pull never`. Use a throwaway `MSB_CONFIG_DIR`/`MSB_STATE_DIR`, and always `msb rm -f` what you create. Otherwise syntax-check with `python3 -m py_compile msbctl` and `bash -n`.

## Hard constraints

- **No dependencies.** Python 3.11+ stdlib (`tomllib`) and the `msb` binary only. No pip, no TOML writer. Registry entries are rendered whole from `templates/` and only read back via `tomllib`; the single exception is the `[versions]` table that `update` rewrites (`write_version_override()`).
- `.gitignore` blocks `*.env` and `secrets/`. Nothing machine-local or generated belongs in the repo.
- Comments in config/templates are the documentation (failure modes are non-obvious and cost debugging sessions). Preserve and extend them when changing behaviour; `msbctl --help` and `defaults.toml` are the user-facing docs.

## Layout

- `msbctl` — single-file Python CLI (~1900 lines). `Sandbox` class (config resolution, `msb` flag emission), `cmd_*` handlers, `main()` argparse at the bottom, fzf menu with numbered-prompt fallback.
- `msb-picker` — fzf picker used by the desktop entry (`msb-manager.desktop`).
- `bootstrap.sh` — runs once **inside the guest** at create time. `msbctl` pipes it in over stdin (not mounted, so manager code stays out of the VM). Intentionally not `set -e`: every step records its outcome and failures are summarized together so an allowlist can be built in one pass. Parameterized by `MSB_*` env vars.
- `install.sh` — two modes: `--dev` (a git checkout; symlinks the commands into it) and `--package` (copies the tree to `~/.local/share/msb-manager/versions/<v>/`, `current` link, commands link through it; keeps current + previous). Seeds `~/.config/msb/` from templates, never overwrites, `--uninstall` removes only what it owns. Never reads stdin (it runs under `curl | sh`) and has no backticks in its unquoted heredoc (they execute).
- `get.sh` — the `curl | sh` entry point (POSIX sh, modeled on microsandbox's installer): resolves the latest release via the GitHub API, downloads the tarball, verifies its sha256, runs the installer inside it. `@@GITHUB_REPO@@` is filled in by `scripts/package.sh`; `MSB_MANAGER_BASE_URL` (+ `--version`) serves assets from a mirror or `file://` for testing.
- `scripts/package.sh` — builds `dist/` (reproducible tarball, repo-bound `get.sh`, `checksums.sha256`) from an explicit PAYLOAD list (keep in step with `install.sh`); fails on symlinks, `.env` files or an unreplaced placeholder; normalizes modes. Does not publish.
- `VERSION` — the release version; `msbctl --version`, `msbctl self-update` (re-runs the packaged `get.sh`; a checkout says `git pull`).
- `profile/CLAUDE.md` — the SHIPPED central CLAUDE.md. `assemble_profile()` appends the operator's `~/.config/msb/CLAUDE.local.md` and writes the result to `~/.local/state/msb/profile/` (a real file); that directory is what is mounted read-only and copied into each sandbox's `~/.claude` on every start. Nothing mounts or links a path inside the checkout or install tree. Editing the copy in a sandbox does nothing.
- `defaults.toml` — what msb-manager ships: egress rule groups, version pins, baseline defaults. Read from the checkout, never copied.
- `templates/` — `config.toml.in` (the short skeleton of *local* overrides install.sh writes once), `sandbox.toml.in`, `dev.yaml.in`, `registry.toml.in`.
- `.msb/` — this repo's own sandbox policy (`sandbox.toml`, `dev.yaml`).
- `spikes/NN-*.sh` — re-runnable PASS/FAIL scripts, one per mechanism the design relies on (SSH agent over vsock, mount ownership, per-port rules, persistence, hostname rules, memory reclaim, token placeholders, profile seeding, DNS rebind). Run one with `./spikes/07-claude-token-secret.sh`. Several need host-specific env vars (e.g. `ALLOW_HOST`, `ALLOW_PORT`) with no defaults, on purpose. Each must assert both the allowed and the denied half.

## Configuration model

Four TOML files, later wins:

1. `<repo>/defaults.toml` — shipped: egress rule groups, pins, baselines (updates with `git pull`)
2. `~/.config/msb/config.toml` — the operator's overrides only, merged over (1): tables merge key by key, anything else (incl. a rule group) is replaced whole. `msbctl config` shows the result and each value's origin
3. `<project>/.msb/sandbox.toml` — committed, portable, no host paths or tokens
4. `~/.config/msb/sandboxes/<name>.toml` — machine-local paths and overrides

Put new defaults and rule groups in `defaults.toml`, never in the template skeleton.

`dev.yaml` is passed to `msb --conf`, but egress rules are deliberately **not** put in its `network:` block; msbctl emits verified `--net-rule` flags from the `sandbox.toml` group list instead. Env overrides: `MSB_CONFIG_DIR`, `MSB_STATE_DIR`.

## Wizard features

`msbctl add` asks for *features*, not raw egress groups. `FEATURES` in `msbctl` maps each one to the egress groups, apt packages and bootstrap switches it needs (e.g. `bun` → `bun` group + `bun = true`; `gitleaks` is opt-in, never preselected; `podman` → `containers` group + packages + a storage follow-up). A feature's `languages` are GitHub linguist names; `detect_features()` reads the repo's languages from the GitHub API and preselects features at ≥5% of bytes. Add a new feature there rather than teaching users to tick a group and a package separately. Coding agents are a separate `AGENTS` list (only `claude` for now, preselected); an agent is installed only if ticked, so add new ones there plus an installer step in `bootstrap.sh`. Groups neither list owns still get their own toggle. Package caches (`pick_caches()`) are named disk volumes, kept across rebuilds and deleted by `purge`. After features, `pick_disks()` asks for the root disk size (small/medium/large/custom around the usual 16G) and, if podman is in, a container disk — or none, which means `fuse-overlayfs` on the rootfs. Single-choice prompts use `choose_one()`; all multi-choice prompts go through `toggle_list()`: a stdlib `termios` menu (arrows/jk, space, enter) on a terminal, numbered input otherwise — keep both paths working, since tests pipe stdin.

## Editing an existing sandbox

`msbctl edit <name>` (the picker's `e`) is the wizard as a menu of sections, one at a time: `EDIT_SECTIONS` in `msbctl` (features & agents, resources, package caches, container storage, extra folders, egress rules, SSH keys, GitHub token, secrets, identity & autostart) plus "edit the files in your editor". Each `section_*` reuses the wizard's own `pick_*` function preselected from the sandbox's current state, writes back with `set_toml_key()` (an in-place, comment-preserving, parse-checked single-key editor — never rewrite a whole file), and either applies live (resources via `msb modify`, keys, secrets) or adds to `ctx["rebuild"]`, which `Done` turns into a rebuild offer. Portable settings go to the project's `.msb/sandbox.toml`, machine-local ones (mounts, identity, ssh keys, autostart) to the registry entry; `edit_target()` writes to the registry only if it already overrides that key. Esc inside a section returns to the menu. If a hand edit leaves a file unparseable, `_recover_broken()` offers the editor instead of locking you out. A new wizard step should get a matching section. Per-sandbox secrets (`secrets/<name>.env`) are written ONLY through `set_env_file_value()`/`store_secret_value()` — never by truncating the file, which once erased every other secret in it.

## Machine-level setup and first run

`msbctl setup` is the machine-level twin of `edit`: `SETUP_SECTIONS` (git identities, Claude login, your network, new-sandbox defaults) plus "edit the file", each writing to `~/.config/msb/config.toml` via `set_toml_key()` / `remove_toml_table()` or to `secrets/global.env` via `set_env_file_value()` (0600, keeps the documenting comments). The main menu's "setup" item opens it. `maybe_welcome()` (bare `msbctl` and `add`, interactive only) offers the same sections as a guided walk-through the first time: `needs_welcome()` is true only if there is no `welcome-done` marker AND nothing configured yet, so an already-set-up machine is marked done silently. A group you define under "your network" that names LAN hosts goes in `defaults.private_dns_groups`, which `msbctl add` and `edit` read to set `allow_private_dns`. A new machine-level setting should get a section here. When testing, `claude` may be on PATH and adds a "run claude setup-token" row to the login menu — patch `shutil.which` so numbering is deterministic.

## SSH agent filtering

Each sandbox's `--vsock` points at its own filtering daemon (`msbctl _agent-filter <name>`, same file, state in `~/.local/state/msb/agent/`), not the host agent. It forwards only identity-list and sign requests, restricted to the fingerprints in the registry entry's `ssh_keys` (absent = all, `[]` = none), re-read per request. The socket path is baked in at create time, so sandboxes created before this need one `rebuild`. Keys are picked in one grouped multiselect (`agent:` / `~/.ssh:` headings via `Header` rows in `toggle_list`); an encrypted key with no `.pub` is listed unnamed and only asks for its passphrase if picked. The fingerprint is the stored/matched identity but is never displayed. `ensure_keys_loaded()` (called from `ensure_agent_filter()`, so every start path) `ssh-add`s any selected key missing from the agent, found by fingerprint in `~/.ssh` (still-unnamed encrypted files are tried in turn), warning rather than failing if it can't. The daemon skips the `msb`/KVM preflight; `ensure_agent_filter()` respawns it on every start.

## What msb can and cannot change (verified on 0.7.6 and re-checked on 0.7.7)

`msb modify` changes cpus, memory, root disk (grow only), env and **secrets** on an existing sandbox, keeping its state — cpus/memory/env need a restart, root disk and secret removal are live. That is what `msbctl resize` and `msbctl secret` use. Network rules, TLS interception, DNS rebind protection, mounts, owned disks and the image are create-time only (`msbctl allow` / `mount` record them and need a rebuild). A full snapshot restored with `msb restore --disk-only` can change network rules and mounts *and keep state*, but it drops TLS interception (re-enable via `modify --secret`), env (re-add with `modify -e`) and resets DNS rebind protection with no way back — not built. When applying `modify`, pass `box.secret_env()` (0.7.6 failed if any bound secret's host variable was unset). CLI flags override `--conf`. `msb` does not log egress denials at any level. Forking a sandbox with a host mount does not give an isolated workspace (unmapped → EIO; remapped → ESTALE).

**Disks:** `--mount-owned DEST:kind=disk,size=…` is deleted with its sandbox. `--mount-named NAME:DEST:kind=disk,size=…` creates a volume that **outlives** it (so a rebuild keeps it), but the guest path must contain **no dot** ("invalid or reserved device id" otherwise — `/d` and `/mnt/cache/npm` work, `/root/.npm` fails; both versions). That is why caches mount at `/mnt/cache/<key>` and bootstrap symlinks the tool's dotted directory to it. A volume's size is fixed at creation and `create` fails if the requested size differs, so `named_disk_flags()` keeps the existing capacity. `msb volume rm` refuses an attached volume. A directory mount with `quota=` also works but is a virtiofs share, ~12–20x slower for tiny files.

## Egress rule gotchas (easy to get wrong)

- Rules are **first-match-wins**; a leading deny can't be undone by a later allow. The `base` group is always applied first.
- A hostname rule only inspects HTTPS. On other ports it degrades to the resolved IP set and breaks against address pools. Plain HTTP (:80) is denied outright.
- DNS resolution is part of a rule: an unresolvable name fails identically to an unallowed one.
- Secrets use `msb --secret ENV[:OPTIONS]@HOST`: placeholder in the guest env, real value substituted host-side into request **headers (HTTP Basic auth included)** for the named hosts only. Query strings and bodies are *not* substituted unless the binding opts in with `:query` / `:body`; don't rely on them by default.
- Some settings are fixed at create time and others changeable on restart — see the comments in `defaults.toml` before moving a setting between them.
