# Working inside a microsandbox

This file is **managed centrally**. The host builds it from msb-manager's shipped
text plus the operator's own additions, and copies it to `~/.claude/CLAUDE.md` on
every sandbox start. Editing it inside the sandbox achieves nothing — the copy is
overwritten on the next start, and the source is on a read-only mount. Changes
belong on the host.

A project's own `CLAUDE.md` is separate, lives in the repo, and wins where the
two disagree.

## Where you are

A microVM, not a container. The project is mounted read-write at `/work` (or,
if this sandbox was set up that way, at the same path as on the host; a new
shell starts there) and presented as the host user, so files you create are owned by them and they can
delete them without `sudo`. You run as root inside the guest; that is a
property of the VM and not a privilege over the host.

Installed packages persist across stop/start but **not across a rebuild**. If
something is worth having every time, say so — it belongs in the manager's
`bootstrap.sh` or the project's `.msb/sandbox.toml`, both of which are on the
host and outside your reach by design.

## The network will refuse things, and that is the design

Egress is deny-by-default and plain HTTP is denied outright. Only an explicit
allowlist of hosts is reachable, on explicit ports.

**So treat a connection failure as policy before you treat it as an outage.**
Do not retry it, do not look for a proxy, and do not reach for an alternative
mirror — report the exact host and port that was refused. Adding it is one line
in the project's `.msb/sandbox.toml` on the host, and the whole allowlist is
deliberately built from denials that actually happened rather than from guesses.

If a fetch over `http://` fails, the fix is its `https://` URL. A hostname rule
on a plaintext port is enforced as a set of IP addresses and breaks against
address pools, which is why plaintext is simply off.

## Credentials: you are holding placeholders, not secrets

Three things are wired in, and none of them puts a usable secret inside this VM.

**SSH** goes through an agent forwarded from the host. The agent protocol
crosses; the private key never does. `git push` works where the remote is SSH.
`~/.ssh/known_hosts` is mounted read-only — you can verify hosts the operator
already trusts and cannot silently add a new one.

**`GH_TOKEN`** is an opaque placeholder. The real token is substituted on the
host, into request **headers only**, on the way out to `github.com` and
`api.github.com`. So this works:

```sh
curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user
gh api user
```

`https://x:$GH_TOKEN@api.github.com/…` works as well — curl turns userinfo into
an `Authorization: Basic` header before sending, so that is a header too.

What does **not** work is a placeholder in a query string or a request body.
Those are outside the headers, so the real value is never substituted there and
the request either fails or carries meaningless literal text. That is the
design, not a bug. Never try to work around it by moving a credential into a
URL — report what refused you instead.

Never run `gh auth login`. It would try to store a credential that is not real.

**Claude's own credential** is bound the same way and is not readable here.

Do not print, log, echo or copy any of these values anywhere. They are
placeholders, so leaking one costs nothing — but the habit is the point, and a
real token reaching a transcript is the failure this whole arrangement exists
to prevent.

## Committing

Identity resolves from the repo's own `.git/config` first. If the repo sets
none, the manager has already applied one at the `--system` level so that
committing works at all. Either way it is the operator's choice — do not set or
change a git identity yourself, and do not pass `--author`.

## Memory

The VM's memory figure is a ceiling, not a reservation. Anonymous memory is
returned to the host automatically, but **guest page cache is never returned on
its own** — so a sandbox that builds a lot drifts up to its ceiling and stays
there. That is expected and harmless; the operator reclaims it from the host
with `msbctl reclaim`. Nothing you can do from in here fixes it, so do not try.
