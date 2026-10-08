# Changelog

All notable changes, one line each, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow `VERSION`.
Add entries under **Unreleased**; the release process turns that heading into
the version being cut, and the release workflow publishes that section as the
release notes.

## [Unreleased]

## [0.2.2] - 2026-10-08

### Added
- `msbctl port <name> 8080` publishes a host port to a server inside the sandbox, so `http://localhost:8080` reaches it (also under `msbctl edit` → Published ports); stored in the registry entry, bound to 127.0.0.1, needs a rebuild, and the server inside must listen on 0.0.0.0.

### Fixed
- `msbctl allow`, `edit` and `setup` accept `host:tcp:port` (and `host:udp:port`) instead of turning it into a rule msb refuses at create (`…:tcp:2222:tcp:443`); a rule already saved that way now fails before create, naming the file to fix it in.

## [0.2.1] - 2026-10-08

### Added
- `msbctl shell` and `msbctl exec` pass any flag after the name to `msb exec` as is (`-u root`, `--timeout 5m`, `-e KEY=value`, …; `msb exec --help` lists them); for `exec`, end them with `--`.
- The project can appear inside the sandbox at its host path (or any path) instead of `/work`, so paths in errors and agent output open on the host as they are: `msbctl add` asks, `msbctl edit` → Name & folder changes it (needs a rebuild), and `setup` sets the default.
- Choosing Claude Code also installs its ACP adapter, `claude-agent-acp`, so an editor can drive Claude in the sandbox over stdio (`msbctl exec . -- claude-agent-acp`); `msbctl update <name> -c claude` updates both, and existing sandboxes get it on a rebuild or that update.
- Claude Code in a sandbox trusts `/tmp` as well as the project, so an agent or ACP session started in scratch space is not stopped by the trust prompt; takes effect on the next start.

### Changed
- The project moved to https://github.com/runoverlabs/sandbox-manager and its documentation to https://sandbox-manager.runoverlabs.dev/; old GitHub links and existing installs keep working through GitHub's redirects, but the old github.io docs address does not.
- Naming the sandbox by the current folder (`.` or leaving the name out) no longer prints the sandbox it resolved to before running the command.

### Fixed
- Input piped into `msbctl exec` (`echo hi | msbctl exec . -- cat`) reaches the command instead of being swallowed, and starting a stopped sandbox no longer writes to its stdout, so it can carry a stream such as ACP.
- After a sandbox is stopped and started again, its SSH agent works again (signing, `git push`) instead of refusing every connection; no rebuild needed.

## [0.2.0] - 2026-10-07

### Added
- Documentation site at https://naerymdan.github.io/sandbox-manager/: install, getting started, guides, command and configuration reference, with search and light/dark themes; agents can read it through `llms.txt`, `llms-full.txt` or the Markdown copy beside each page.
- Sandboxes get `EDITOR=nano` (and nano itself), so Claude Code's `/memory`, `git commit` and friends open an editor instead of silently doing nothing; override it under `[env]`. Existing sandboxes need a rebuild.
- Inside a project folder msbctl knows which sandbox you mean: leave the name out where it is the only argument (`msbctl shell`, `msbctl stop`), use `.` where more follows (`msbctl exec . make`, `msbctl allow . example.com`), or `msbctl exec -- cmd`; `shell` and `exec` start in the matching subfolder of `/work`.
- `msbctl rename <name> <new>` and `msbctl move <name> <dir>` (also `edit` → Name & folder) rename a sandbox or point it at another project folder; a rename recreates the VM and keeps settings, secrets, Claude state, caches and container images, a move needs a rebuild.
- A git identity can name an ssh key to sign commits with (`setup` → Git identities); sandboxes using it sign through the filtered agent (and can verify their own signatures) while the key stays ticked in `msbctl keys`, which flags it and warns before you drop it. Existing sandboxes need a rebuild for `openssh-client` if `ssh-keygen` is missing.

## [0.1.1] - 2026-10-06

First release. msb-manager runs coding agents against real repositories in
[microsandbox](https://github.com/microsandbox/microsandbox) microVMs, without
giving them your network or your tokens.

### Isolation
- **Deny-by-default egress**, per host and per port. Named rule groups (`github`, `npm`, `python`, `go`, `claude`, `bun`, …) compose per project, and plain HTTP is refused outright.
- **Tokens never enter the VM.** `--secret` bindings put an opaque placeholder in the guest and substitute the real value host-side, into request headers only, for the hosts you name. `GH_TOKEN` and Claude's own credential work this way, and `msbctl secret` adds more.
- **A filtered SSH agent** per sandbox, forwarded over vsock: only identity-list and sign requests, limited to the keys you pick (`msbctl keys`). The private key never crosses.
- **A central `CLAUDE.md`** (shipped text plus your own additions) copied into every sandbox on each start from a read-only mount; each sandbox gets its own `~/.claude`.

### Managing sandboxes
- **One CLI and an fzf picker** (with a desktop entry) to register, start, stop, rebuild, purge, resize, shell into and run commands in sandboxes: `msbctl add`, `start`, `stop`, `rebuild`, `purge`, `shell`, `exec`, `resize`, `reclaim`, `ls`, `status`, `show`.
- **A setup wizard** that asks for features (bun, python, podman, gitleaks, …) rather than raw rule groups, preselects them from your repo's languages, and sizes the disks and package caches; `msbctl edit` and `msbctl setup` revisit any section later, and a first-run walk-through covers a new machine.
- **Per-project config that travels with the repo** (`.msb/sandbox.toml`, egress groups, packages, limits), with machine-local paths and tokens kept in `~/.config/msb/` and never committed. `msbctl config` shows the merged result and where each value came from.
- **Extra folders, package-cache disks and secrets** added after the fact (`msbctl mount`, `cache`, `secret`), and `msbctl allow` for one more egress rule.
- **Egress observe mode** (`msbctl observe <name> on`): when an allowlist is too tight to work in, stop blocking, record every host reached, then read it back with the exact `msbctl allow` lines for the hosts no rule covers. It leaves that sandbox's egress unrestricted until you switch it off.
- **Secret placeholders pass through to agent hosts**, so a coding agent that has read `$MSB_GH_TOKEN` no longer breaks its own API calls.
- **In-place updates** of claude, gh, gitleaks, bun and apt (`msbctl update`), with the versions recorded so a rebuild reproduces them, and a version display in the picker.

### Install and supply chain
- **`curl | sh` installer** (`get.sh`) and `msbctl self-update`, with sha256 verification of the release tarball.
- **Signed build-provenance attestations** on every release tarball and `get.sh`, verified by `get.sh` and `self-update` when an authenticated `gh` is installed (`MSB_MANAGER_SKIP_ATTEST=1` skips it; otherwise only the checksum is checked). See the README's "Verifying a release".
- **Verified toolchain installs inside the guest**: bun and gh are pinned release assets checked against their published checksums, and node comes from NodeSource's apt repository with a pinned signing-key fingerprint, instead of `curl | bash`.
- **CI, CodeQL, zizmor and OpenSSF Scorecard**, a tag-driven release workflow, Dependabot, issue forms, a security policy and a contributing guide.

### Upgrading from a checkout
- Rule groups changed: the Claude hosts now come only from the `claude` group, `bun` allows `github.com` instead of `bun.sh`, and `github` allows the Actions log host, Sigstore's trust root and GitHub's attestation storage (so `gh attestation verify` works from a sandbox). Existing sandboxes pick these up, along with the secret pass-through and the new installers, at their next `msbctl rebuild`.
