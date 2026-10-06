# Changelog

All notable changes, one line each, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow `VERSION`.
Add entries under **Unreleased**; the release process turns that heading into
the version being cut, and the release workflow publishes that section as the
release notes.

## [Unreleased]

### Changed
- The `github` rule group now allows `results-receiver.actions.githubusercontent.com`, so `gh run view --log` can read Actions logs from a sandbox; needs a rebuild.
- bun and node are now installed from verified sources: bun is a pinned (`[versions] bun`, default 1.4.2) GitHub release checked against its published checksums, node from NodeSource's apt repository with a pinned signing-key fingerprint, instead of `curl | bash`; the `bun` rule group now allows `github.com` rather than `bun.sh`, `msbctl update -c bun` bumps the pin, and an existing sandbox picks this up at its next rebuild.
- The Claude egress hosts (`api.anthropic.com`, `platform.claude.com`) now come only from the `claude` rule group, no longer from `base`; a sandbox whose `rule_groups` omits `claude` loses Claude access at its next rebuild.

### Fixed
- Secret placeholders no longer kill a coding agent's own API requests: every binding now passes the placeholder through to `api.anthropic.com` and `platform.claude.com`, so an agent that has once read `$MSB_GH_TOKEN` stops getting `ECONNRESET` on every later turn; needs a rebuild. The real token is unaffected — it still only goes into headers, for its own hosts.
- `msbctl observe <name>` reports requests msb blocked over the secret policy, which are invisible from inside the guest and look exactly like a missing egress rule.
- `install.sh --dev` no longer sets the executable bit on `bootstrap.sh`, which is committed as 644 and showed up as modified after every dev install.

### Added
- Each release's tarball and `get.sh` carry a signed build-provenance attestation; `get.sh` and `msbctl self-update` verify it when an authenticated `gh` is installed (`MSB_MANAGER_SKIP_ATTEST=1` skips it) and otherwise say only the checksum was checked.
- `egress_mode = "observe"` per sandbox (`msbctl observe <name> on`, or `msbctl edit`): stops blocking egress entirely and records every host reached, for when the allowlist is too tight to work in; needs a rebuild, and leaves that sandbox with unrestricted egress until you switch back.
- `msbctl observe <name>` lists the hosts a sandbox actually reached, flags the ones no rule covers and prints the `msbctl allow` line for them.
- `scripts/check.sh` (static checks, run by CI) and `scripts/smoke-install.sh` (package, then install into a throwaway HOME).
- CI, a tag-driven release workflow, Dependabot for Actions, issue forms, a PR template, `CODEOWNERS` and `SECURITY.md`.
