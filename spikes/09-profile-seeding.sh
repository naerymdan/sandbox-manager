#!/usr/bin/env bash
#
# 09-profile-seeding.sh — a central CLAUDE.md, and per-sandbox Claude state.
#
# Instead of bind-mounting the host's ~/.claude and ~/.claude.json, the manager
# uses:
#
#   --mount-dir ~/.local/state/msb/profile:/opt/msb-profile:ro  central, read-only (assembled)
#   --mount-dir ~/.local/state/msb/claude/<name>:/root/.claude:uid=,gid=
#
# and then, on EVERY start, copies the profile's CLAUDE.md into place. A copy
# rather than mounting the file over a path inside another mount: the overlay
# is unverified, the copy is not, and copy-on-start is what makes the file
# centrally controlled — edit it on the host, restart, every sandbox has it.
#
# Six things have to hold:
#
#   1. a read-only --mount-dir really is read-only from the guest
#   2. the per-sandbox state dir is writable and comes back owned by you
#   3. the copy lands
#   4. EDITING THE HOST FILE AND RESTARTING propagates the change
#   5. /root/.claude.json is seeded when absent
#   6. and is NOT overwritten when present
#
# 5 and 6 are a different file with deliberately opposite rules, which is why
# they are separate checks. CLAUDE.md is replaced on every start because being
# centrally managed is its purpose; .claude.json is created once because Claude
# Code keeps per-sandbox state in it. Getting 6 wrong silently discards that
# state on every start and nothing visibly breaks.
#
# PASS: all six.
#
# Uses a named sandbox because (3) and (4) are about the start path, not the
# create path. Cleans up after itself.

set -uo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
NAME="${NAME:-msb-spike09}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail=0

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }

msb ls 2>/dev/null | awk '{print $1}' | grep -qx "$NAME" && {
	echo "a sandbox named $NAME already exists — remove it first:" >&2
	echo "  msb stop $NAME; msb rm $NAME" >&2
	exit 1
}

PROFILE="$(mktemp -d "$HOME/.cache/msb-spike09-profile.XXXXXX")"
STATE="$(mktemp -d "$HOME/.cache/msb-spike09-state.XXXXXX")"
cleanup() {
	msb stop "$NAME" >/dev/null 2>&1
	msb rm   "$NAME" >/dev/null 2>&1
	rm -rf "$PROFILE" "$STATE"
}
trap cleanup EXIT

printf '# Managed centrally\n\nVERSION_ONE\n' >"$PROFILE/CLAUDE.md"
note "profile: $PROFILE"
note "state:   $STATE"

say "Create"
msb create --name "$NAME" \
	--memory 2G \
	--mount-dir "$PROFILE:/opt/msb-profile:ro" \
	--mount-dir "$STATE:/root/.claude:uid=$(id -u),gid=$(id -g)" \
	--net-default-egress deny \
	"$IMAGE" || { echo "create failed" >&2; exit 1; }

# ---------------------------------------------------------------- 1 and 2
say "Mount behaviour"
probe="$(msb exec "$NAME" --no-tty -- sh -c '
	printf "READ=%s\n" "$(head -1 /opt/msb-profile/CLAUDE.md 2>&1)"
	if echo tampered >> /opt/msb-profile/CLAUDE.md 2>/dev/null; then
		echo "RO_WRITE=succeeded"
	else
		echo "RO_WRITE=refused"
	fi
	if : > /root/.claude/writable-probe 2>/dev/null; then
		echo "RW_WRITE=ok"
	else
		echo "RW_WRITE=refused"
	fi
' 2>&1 | tr -d '\r')"
printf '%s\n' "$probe" | sed 's/^/   /'

field() { printf '%s' "$probe" | sed -n "s/^$1=//p" | head -1; }

case "$(field READ)" in
	"# Managed centrally") note "read-only mount is readable                OK" ;;
	*) note "read-only mount is NOT readable               FAIL"; fail=1 ;;
esac

if [ "$(field RO_WRITE)" = refused ]; then
	note ":ro really is read-only                       OK"
else
	note ":ro accepted a WRITE                          FAIL"
	note "  the guest can edit its own managed profile — drop the :ro design"
	fail=1
fi

if [ "$(field RW_WRITE)" = ok ]; then
	note "per-sandbox state dir is writable             OK"
else
	note "per-sandbox state dir is NOT writable         FAIL"; fail=1
fi

if [ -e "$STATE/writable-probe" ]; then
	owner="$(stat -c '%u:%g' "$STATE/writable-probe")"
	if [ "$owner" = "$(id -u):$(id -g)" ]; then
		note "guest writes come back owned by you ($owner)  OK"
	else
		note "guest writes owned by $owner, expected $(id -u):$(id -g)  FAIL"
		fail=1
	fi
else
	note "guest write never appeared on the host         FAIL"; fail=1
fi

# -------------------------------------------------------------------- 3
say "Seed"
# Exactly what the manager's ensure_profile() will run, no more.
msb exec "$NAME" --no-tty -- \
	sh -c 'cp /opt/msb-profile/CLAUDE.md /root/.claude/CLAUDE.md' >/dev/null 2>&1

if grep -q VERSION_ONE "$STATE/CLAUDE.md" 2>/dev/null; then
	note "CLAUDE.md seeded into the state dir           OK"
else
	note "CLAUDE.md did not land                        FAIL"; fail=1
fi

# -------------------------------------------------------------------- 4
say "Propagate a central edit"
# The whole reason this is a copy-on-start rather than a copy-at-create.
printf '# Managed centrally\n\nVERSION_TWO\n' >"$PROFILE/CLAUDE.md"
msb stop "$NAME"  >/dev/null 2>&1
msb start "$NAME" >/dev/null 2>&1 || { note "restart failed"; fail=1; }
msb exec "$NAME" --no-tty -- \
	sh -c 'cp /opt/msb-profile/CLAUDE.md /root/.claude/CLAUDE.md' >/dev/null 2>&1

if grep -q VERSION_TWO "$STATE/CLAUDE.md" 2>/dev/null; then
	note "host edit reached the sandbox after restart   OK"
else
	note "host edit did NOT propagate                   FAIL"
	note "  a read-only mount may be snapshotted at create rather than"
	note "  passed through live. Check with a second create."
	fail=1
fi

# ----------------------------------------------------------------- 5 and 6
say "Onboarding seed"
#
# /root/.claude.json is NOT in the mounted state dir. It lives in the sandbox's
# own writable layer, so it is read back through the guest rather than from
# $STATE, and it is gone after every rebuild — which is why the manager seeds
# it on each start rather than once at create.
#
# WHY THIS CHECK EXISTS AT ALL. Without the file, interactive `claude` runs its
# first-run login flow even though CLAUDE_CODE_OAUTH_TOKEN is bound and
# demonstrably works: the token is checked on the wire, onboarding is checked
# locally, and satisfying one does nothing for the other. `claude -p` never
# reads it, so spike 07 passes either way and cannot see this. An earlier
# version of THIS file claimed 07 covered it. It does not.
seed='[ -f /root/.claude.json ] || printf "%s\n" "{\"hasCompletedOnboarding\":true}" > /root/.claude.json'

msb exec "$NAME" --no-tty -- sh -c "$seed" >/dev/null 2>&1
got="$(msb exec "$NAME" --no-tty -- cat /root/.claude.json 2>/dev/null | tr -d '\r\n')"

case "$got" in
	*hasCompletedOnboarding*true*)
		note ".claude.json seeded when absent               OK" ;;
	"")	note ".claude.json was not created                FAIL"; fail=1 ;;
	*)	note ".claude.json has unexpected content          FAIL"
		note "  got: $got"
		fail=1 ;;
esac

# The negative half, and the one that regresses silently: a seed that runs
# unconditionally would wipe accumulated state on every single start.
msb exec "$NAME" --no-tty -- \
	sh -c 'printf "%s\n" "{\"projects\":{\"keep\":\"me\"}}" > /root/.claude.json' \
	>/dev/null 2>&1
msb exec "$NAME" --no-tty -- sh -c "$seed" >/dev/null 2>&1
kept="$(msb exec "$NAME" --no-tty -- cat /root/.claude.json 2>/dev/null | tr -d '\r\n')"

case "$kept" in
	*keep*me*)
		note "an existing .claude.json is left alone        OK" ;;
	*)	note "the seed OVERWROTE existing state             FAIL"
		note "  every start would discard the sandbox's Claude state. The"
		note "  seed must be conditional: [ -f … ] || write"
		note "  got: $kept"
		fail=1 ;;
esac

say "Result"
if [ "$fail" -eq 0 ]; then
	cat <<-'EOF'
	   PASS — the manager can hold one CLAUDE.md on the host, give every
	   sandbox its own private Claude state, and keep both in step with a
	   copy on each start.
	EOF
else
	echo "   FAIL — see which of the six failed above."
fi
exit "$fail"
