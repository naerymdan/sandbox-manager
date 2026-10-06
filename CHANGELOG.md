# Changelog

All notable changes, one line each, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow `VERSION`.
Add entries under **Unreleased**; the release process turns that heading into
the version being cut, and the release workflow publishes that section as the
release notes.

## [Unreleased]

### Changed
- The Claude egress hosts (`api.anthropic.com`, `platform.claude.com`) now come only from the `claude` rule group, no longer from `base`; a sandbox whose `rule_groups` omits `claude` loses Claude access at its next rebuild.

### Fixed
- `install.sh --dev` no longer sets the executable bit on `bootstrap.sh`, which is committed as 644 and showed up as modified after every dev install.

### Added
- `scripts/check.sh` (static checks, run by CI) and `scripts/smoke-install.sh` (package, then install into a throwaway HOME).
- CI, a tag-driven release workflow, Dependabot for Actions, issue forms, a PR template, `CODEOWNERS` and `SECURITY.md`.
