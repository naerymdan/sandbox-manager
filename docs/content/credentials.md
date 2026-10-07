---
title: Credentials & SSH
section: Guides
order: 30
description: Tokens a sandbox can use but never see, the filtered SSH agent, and commit signing.
---

## Secrets: usable, never visible

msb-manager binds tokens with msb's `--secret ENV@HOST`. Inside the guest the
variable holds a placeholder, `$MSB_<ENV>`. When a request leaves the VM, msb
replaces the placeholder with the real value, **on the host**, in **request
headers only**, and only for the named hosts.

```console
$ echo "$GH_TOKEN"                     # inside the sandbox
$MSB_GH_TOKEN
$ gh api user --jq .login              # still works: substituted on the way out
yourhandle
```

What this means in practice:

- `curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user` works.
- `https://x:$GH_TOKEN@github.com/…` works too: curl turns the user info into an
  `Authorization` header before sending.
- A placeholder in a **query string** or a **request body** is not substituted,
  unless the binding opts in with `:query` or `:body`.
- Sending a token to a host it isn't bound to sends the placeholder text, which
  is useless to whoever receives it.

The real values live in `~/.config/msb/secrets/`: `global.env` for the Claude
token, and `<name>.env` per sandbox. Both are mode 0600, outside every project.

### Claude

`msbctl setup` → "Claude login" stores a long-lived token from
`claude setup-token` in `secrets/global.env`. Every sandbox gets
`CLAUDE_CODE_OAUTH_TOKEN` as a placeholder bound to `api.anthropic.com` and
`platform.claude.com`, plus its own `~/.claude`, kept on the host at
`~/.local/state/msb/claude/<name>/`.

> **Note:** `claude_auth = "mount"` in your config shares the host's real
> `~/.claude` with every sandbox instead. That means shared history, but also
> your real credentials and every project's transcripts in every VM. It's a
> fallback for when `spikes/07-claude-token-secret.sh` fails, not a preference.

### GitHub

One fine-grained token per project, scoped to that one repository (see
[Get started](quickstart.md#the-github-token)). It's bound as `GH_TOKEN` to
`github.com` and `api.github.com`. Replace or remove it with `msbctl edit` →
"GitHub token".

### More secrets

```console
$ msbctl secret add .            # pick a preset or type your own binding
$ msbctl secret ls .
$ msbctl secret rm . NPM_TOKEN
```

The presets: `npm`, `dockerhub`, `ghcr`, `pypi`, `crates`. Each knows its
variable name, the hosts it goes to, where to create the token and how the tool
picks it up. You can add your own presets under `[secret_presets.<name>]` in
`config.toml`. A hand-written binding uses msb's own syntax:

```text
NPM_TOKEN@registry.npmjs.org
MY_TOKEN:query@api.example.com          # also substitute in the query string
MY_TOKEN@one.example.com,two.example.com
```

A secret doesn't open the network: its hosts must also be allowed by an egress
rule. `msbctl add` warns when they aren't; after `msbctl secret add`, check
with `msbctl show` and [`msbctl allow`](egress.md#adding-a-host) what's
missing.

### Why a placeholder can break an agent, and why it doesn't here

msb blocks any outbound request carrying a placeholder in a place where
substitution isn't allowed, such as a request body. Coding agents send their
whole transcript in the request body on every turn. So once an agent has read
`$MSB_GH_TOKEN` (from `env`, say), every later request would carry it and be
killed, which Claude Code reports as `API Error: Connection dropped
(ECONNRESET)`.

msbctl prevents this by adding `passthrough=` for the agent's own API hosts to
every binding it emits. Passthrough lets the harmless *placeholder* travel to
those hosts and never substitutes the real value, so the real token still goes
only into headers, only to its own hosts.

## SSH: the filtered agent

A sandbox never gets your SSH agent directly. Its `--vsock` points at a small
per-sandbox daemon, `msbctl _agent-filter <name>`, which forwards exactly two
kinds of request to your real agent:

- **list identities**, answered with only the keys this sandbox may use;
- **sign**, refused for any key not on that list.

Everything else (adding keys, removing them, locking the agent) is refused.
Signing still happens in your host agent, so passphrases, hardware keys and
`ssh-add -c` confirmations all keep working.

```console
$ msbctl keys .            # pick keys: one list, agent keys and ~/.ssh files
$ msbctl keys . --all      # remove the restriction: every key in the agent
```

The selection is read on every request, so a change takes effect immediately.
In the registry entry, `ssh_keys` absent means every key, and `ssh_keys = []`
means none. If a selected key isn't loaded in your agent at start, msbctl
finds it in `~/.ssh` and `ssh-add`s it, asking for a passphrase if it needs one.

Inside the guest, `SSH_AUTH_SOCK` is `/tmp/ssh-agent.sock` in `msbctl shell`
and `exec`. Your `~/.ssh/known_hosts` is mounted **read-only**: the sandbox can
check hosts you already trust, but can't quietly add a new one.

## Commit signing

Give an identity in `config.toml` (or in `msbctl setup` → "Git identities") a
`signing_key`, the public half of an SSH key:

```toml title="~/.config/msb/config.toml"
[identities.public]
name        = "yourhandle"
email       = "12345+yourhandle@users.noreply.github.com"
signing_key = "ssh-ed25519 AAAA..."
```

A sandbox using that identity sets `gpg.format=ssh`, `user.signingkey` and
commit and tag signing in the guest's `--system` git config, and signs through
the filtered agent. An allowed-signers file is written too, so
`git log --show-signature` verifies its own commits.

Signing is on only while the sandbox is allowed that key. Drop it in
`msbctl keys` and signing turns off, with a warning, rather than leaving you
with a sandbox where every commit fails.
