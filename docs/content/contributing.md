---
title: Contributing
section: Project
order: 10
description: Working on msb-manager: the checks, the rules, the spikes, the docs and releases.
---

Issues and PRs are welcome, especially from anyone on a different distro or a
newer `msb`. Read
[`CLAUDE.md`](https://github.com/runoverlabs/sandbox-manager/blob/main/CLAUDE.md)
in the repo first: despite the name, it's the design guide for humans and agents
alike, and it records the failure modes that aren't obvious.

## Getting set up

```console
$ git clone https://github.com/runoverlabs/sandbox-manager msb-manager
$ cd msb-manager
$ ./install.sh                 # dev mode: the commands link into this checkout
```

## Before you open a PR

```console
$ scripts/check.sh             # exactly what CI runs
$ scripts/smoke-install.sh     # package, then install into a throwaway HOME
```

`check.sh` covers Python syntax, `bash -n` and shellcheck, TOML parsing, the
release payload lists agreeing, tracked file modes, gitleaks, and a docs build
that fails on a broken link or an undocumented command.

The rules:

- **No dependencies.** Python 3.11+ standard library and the `msb` binary,
  nothing else. That includes this documentation site, which `docs/build.py`
  builds with the standard library alone.
- **Every behaviour change gets a one-line `CHANGELOG.md` entry** under
  `## [Unreleased]`, saying what changed and what a user must do about it (for
  example "needs a rebuild"). Refactors and CI-only changes need none.
- **Comments are the documentation.** Preserve and extend them when behaviour
  changes. `msbctl --help`, `defaults.toml` and these pages are what users
  read; update the relevant page in `docs/content/` with the code.
- **Egress rules come from an observed denial**, not a guess. The *egress
  denial* issue form asks for the host, the port and what failed.
- **File modes follow one rule:** a file with a shebang is 755, everything else
  644, except `bootstrap.sh` (piped into the guest, never executed). `check.sh`
  reads the git index, so `git add` after a `chmod`.

## Testing against a real msb

`msbctl` needs `/dev/kvm` and `msb`. Use a throwaway `MSB_CONFIG_DIR` and
`MSB_STATE_DIR`, and `msb rm -f` whatever you create. Without KVM,
`scripts/check.sh` is what you can run, plus exercising functions against a stub
`msb` on `PATH`.

## The spikes

`spikes/` holds one re-runnable script per mechanism the design depends on: the
agent bridge, mount ownership, per-port rules, persistence, hostname rules,
memory reclaim, both token placeholders, profile seeding and DNS rebind
protection.

```console
$ ./spikes/07-claude-token-secret.sh
```

Each prints `PASS` or `FAIL` with a reason, and asserts **both halves** of its
claim: that the allowed thing works *and* that the denied thing is still
denied. A rule set that permits the one service you need is worthless if it
also permits the admin page next to it, and only the negative half catches that.
Several need addresses on your own network set first, and have no defaults on
purpose: a wrong guess makes a spike pass for the wrong reason.

## The docs

These pages are Markdown in `docs/content/`, built by `docs/build.py`:

```console
$ python3 docs/build.py --check        # build into docs/_site and check links
$ xdg-open docs/_site/index.html       # works straight off the disk
```

Each page starts with `title`, `section` (Start here, Guides, Reference or
Project), `order` and a one-sentence `description`, which `--check` requires:
it becomes the page's meta description, its link preview and its line in
`llms.txt`. The converter supports a deliberate subset of Markdown:
headings, paragraphs, lists, fenced code (`console` blocks get prompts, and
their copy button copies only the commands), tables, `> **Note:**` /
`**Tip:**` / `**Warning:**` callouts, and inline code, emphasis, links and
images. A new `msbctl` subcommand needs a `### msbctl <name>` section on the
[Commands](commands.md) page, or `--check` fails.

The same build writes what search engines and agents look for: canonical
links, Open Graph and JSON-LD tags, `sitemap.xml`, `llms.txt`, `llms-full.txt`
and a Markdown copy of every page. None of it is hand-maintained. The social
preview image is `docs/assets/social-card.png`.

The site deploys to GitHub Pages from `main`.

## Workflows

They run on `pull_request`, never `pull_request_target`, with read-only
default permissions. Every action is pinned by commit hash with its version in
a comment; Dependabot moves the hash and the comment together, so don't unpin
one to "fix" something. `zizmor` lints them in CI.

## Releases

Maintainers only, and tag-driven: move the `CHANGELOG.md` **Unreleased**
entries under `## [X.Y.Z] - YYYY-MM-DD`, set `VERSION`, merge, then:

```console
$ git tag vX.Y.Z && git push origin vX.Y.Z
```

The release workflow refuses if the tag, `VERSION` and the changelog disagree.
It builds the assets, attests them and publishes them. Nothing is published by
hand. To build the same assets locally without publishing:

```console
$ scripts/package.sh --version 0.2.0 --repo runoverlabs/sandbox-manager   # writes ./dist
```

## Security

A way around the egress rules, a credential readable from inside the guest, or
a leak through the agent filter is a vulnerability. Report it privately, as
described in
[SECURITY.md](https://github.com/runoverlabs/sandbox-manager/blob/main/SECURITY.md),
not in a public issue.
