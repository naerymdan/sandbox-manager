#!/usr/bin/env bash
#
# 04-persistence.sh — does a named sandbox keep its state across a stop/start?
#
# There is no `.menv` in msb 0.7.6, so the named sandbox is the only
# persistence mechanism. If installed packages do not survive a stop/start,
# the bootstrap has to run every session and the toolchain belongs in an
# image instead.
#
# PASS: a package installed before `msb stop` is still present after
#       `msb start`, and so is a file written outside the mounted workspaces.
#
# socat specifically, because the ssh-agent bridge needs it in the guest.
#
# NOT TESTED HERE, because a script cannot: survival across a HOST REBOOT.
# Do that by hand before trusting this — `msb ls` after a reboot, then
# `msb start` and re-check. A sandbox that survives stop/start but not a
# reboot would be a nasty thing to discover on a Monday.

set -euo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
NAME="${NAME:-msb-spike04}"
MARKER=/root/spike04-marker

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

cleanup() {
	msb stop "$NAME" >/dev/null 2>&1 || true
	msb rm   "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }
cleanup   # in case a previous run left one behind
note "sandbox name: $NAME"

say "Create (idle boot) and install into it"
msb create --name "$NAME" --memory 2G \
	--net-default-egress deny \
	--net-rule "allow@dns" \
	--tls-intercept \
	--net-rule "allow@*.ubuntu.com:tcp:443" \
	"$IMAGE"

msb exec "$NAME" --no-tty -- sh -c "
	set -e
	export DEBIAN_FRONTEND=noninteractive
	sed -i 's|http://\([a-z0-9.-]*ubuntu\.com\)|https://\1|g' \
		/etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list 2>/dev/null || true
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends socat
	command -v socat
	printf 'written before the stop\n' > $MARKER
	echo 'setup: done'
"

say "Stop"
msb stop "$NAME"
msb ls || true

say "Start"
if ! msb start "$NAME"; then
	echo
	echo "   'msb start' failed or does not exist. That is itself the finding:" >&2
	echo "   the lifecycle verbs are not what this script assumed. Available:" >&2
	msb --help 2>&1 | sed -n '/[Cc]ommands:/,/^$/p' | sed 's/^/     /' >&2
	exit 1
fi

say "Verify"
fail=0
if msb exec "$NAME" --no-tty -- sh -c 'command -v socat' >/dev/null 2>&1; then
	note "installed package survived:        OK"
else
	note "installed package survived:        LOST"
	fail=1
fi
if msb exec "$NAME" --no-tty -- sh -c "cat $MARKER" 2>/dev/null | grep -q 'before the stop'; then
	note "file outside the workspaces survived: OK"
else
	note "file outside the workspaces survived: LOST"
	fail=1
fi

say "Result"
if [ "$fail" -eq 0 ]; then
	cat <<-EOF
	   PASS — the named sandbox is the persistence mechanism, so the bootstrap
	   runs once at create. Still check reboot survival by hand.
	EOF
else
	cat <<-EOF
	   FAIL — state does not survive a stop/start, so the toolchain must be
	   baked into an image. microsandbox accepts a local rootfs directory,
	   and a prebuilt image already bakes this
	   toolchain.
	EOF
fi
exit "$fail"
