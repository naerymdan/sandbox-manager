# Contributing

Issues and PRs are welcome, particularly from anyone on a different distro or a
newer `msb`. Read `AGENTS.md` first: despite the name it is the design guide for
humans and agents alike, and it records the failure modes that are not obvious.

## Before you open a PR

```sh
scripts/check.sh            # exactly what CI runs
scripts/smoke-install.sh    # package, then install into a throwaway HOME
```

- **No dependencies.** Python 3.11+ stdlib and the `msb` binary, nothing else.
- **Every behaviour change gets a one-line `CHANGELOG.md` entry** under
  `## [Unreleased]`: what changed and what a user must do about it (for example
  "needs a rebuild"). Refactors and CI-only changes need none.
- **Comments are the documentation.** Preserve and extend them when behaviour
  changes; `msbctl --help` and `defaults.toml` are what users read.
- **Egress rules come from an observed denial**, not a guess. The
  *egress denial* issue form asks for the host, the port and what failed.
- File modes follow one rule (shebang means 755, everything else 644, except
  `bootstrap.sh`); `check.sh` reads the git index, so `git add` after a `chmod`.

## Testing against a real `msb`

`msbctl` needs `/dev/kvm` and `msb`. Use a throwaway `MSB_CONFIG_DIR` and
`MSB_STATE_DIR`, and `msb rm -f` what you create. `AGENTS.md` has the details.
Without KVM, `scripts/check.sh` is what you can run.

## Workflows

They use `pull_request`, never `pull_request_target`, with read-only default
permissions, and every action is pinned by commit hash with its version in a
comment. Dependabot moves the hash and the comment together; do not unpin to
"fix" something. `zizmor` lints them in CI.

## Releases

Maintainers only, tag-driven; see the README. Nothing is published by hand.

## Security

A way around the egress rules, a credential readable in the guest, or an agent
filter leak is a vulnerability: report it privately via
[SECURITY.md](SECURITY.md), not in a public issue.
