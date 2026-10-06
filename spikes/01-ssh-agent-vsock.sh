#!/usr/bin/env bash
#
# 01-ssh-agent-vsock.sh — can a microsandbox guest use the host's SSH agent?
#
# Checks that the guest can use the host's SSH agent. A microVM cannot
# bind-mount a unix socket, so `--vsock HOST_PATH:PORT` routes guest->host and
# the guest sees an AF_VSOCK endpoint at CID 2 rather than a socket path.
# ssh(1) only speaks to a unix socket, so socat bridges the two.
#
# PASS: `ssh-add -l` inside the guest lists the host's keys.
#
# Reachability only — it does not prove `ssh <host>` works, which needs the
# network rules 03-lan-allowlist.sh covers.
#
# SAFETY NOTE. This forwards your real login agent — the one holding keys that
# reach real hosts — into a VM for one command. Acceptable for a sandbox you
# trust with those hosts anyway; NOT acceptable for one that works on untrusted
# code, where the correct answer is to forward nothing. A forwarded agent signs
# whatever it is asked to, and the VM decides what to ask. `ssh-add -c` makes
# the agent prompt for every use, which is the control that actually bounds
# this.

set -euo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
VSOCK_PORT="${VSOCK_PORT:-5001}"
GUEST_SOCK=/tmp/agent.sock

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run this on the host, not inside a container" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }

: "${SSH_AUTH_SOCK:?no SSH_AUTH_SOCK — start an agent and ssh-add a key first}"
[ -S "$SSH_AUTH_SOCK" ] || { echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK is not a socket" >&2; exit 1; }
note "host agent:  $SSH_AUTH_SOCK"

if ! ssh-add -l >/dev/null 2>&1; then
	echo "the host agent holds no keys — 'ssh-add -l' must list at least one," >&2
	echo "or a pass here would be meaningless (an empty agent also 'answers')." >&2
	exit 1
fi
note "host keys:   $(ssh-add -l | wc -l)"
note "vsock port:  $VSOCK_PORT  (guest dials CID 2)"

# The guest-side half, written out rather than inlined, so the quoting through
# `msb run -- sh -c` stays readable.
GUEST_SCRIPT="$(mktemp -d)/probe.sh"
cat >"$GUEST_SCRIPT" <<SH
#!/bin/sh
set -e

echo "guest: installing socat"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends socat

echo "guest: bridging AF_VSOCK(cid=2,port=$VSOCK_PORT) -> $GUEST_SOCK"
# VSOCK-CONNECT needs socat >= 1.7.4; Ubuntu 24.04 ships 1.8.x.
socat "UNIX-LISTEN:$GUEST_SOCK,fork,unlink-early" \\
      "VSOCK-CONNECT:2:$VSOCK_PORT" &
bridge=\$!
sleep 2

echo "guest: asking the agent for its keys"
export SSH_AUTH_SOCK="$GUEST_SOCK"
if ssh-add -l; then
	echo "RESULT: PASS — the guest can use the host agent"
	rc=0
else
	echo "RESULT: FAIL — ssh-add could not reach the agent"
	rc=1
fi

kill "\$bridge" 2>/dev/null || true
exit "\$rc"
SH
chmod +x "$GUEST_SCRIPT"

say "Running"
# Network is open here on purpose: apt must fetch socat, and mixing in egress
# restrictions would make a failure impossible to attribute. 03 covers those.
msb run \
	--vsock "$SSH_AUTH_SOCK:$VSOCK_PORT" \
	-v "$(dirname "$GUEST_SCRIPT"):/probe:ro" \
	--memory 2G \
	"$IMAGE" -- /probe/probe.sh

say "Interpreting the result"
cat <<'EOF'
   PASS  -> the agent socket crosses the VM boundary.

   FAIL, "Address family not supported" or similar from socat
         -> the guest kernel lacks vhost-vsock, or the --vsock route did not
            attach. Check `msb logs --source system <name>`.

   FAIL, socat connects but ssh-add says "error fetching identities"
         -> the route works and something is mangling the agent protocol.
            That is the interesting failure; capture it before concluding.
EOF
