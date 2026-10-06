#!/usr/bin/env bash
#
# 02-rw-mount-ownership.sh — do guest writes land as the right host user?
#
# A microVM has no uid mapping of its own: the guest has its own user table
# and virtiofs must be told what to present. `--mount-dir SRC:DST:uid=N,gid=N`
# is how. Without it, files the guest writes come back owned by someone else.
#
# PASS: a file created inside the guest shows up on the host owned by you, a
#       host-created file is writable from the guest, and the host can delete
#       guest-created files without sudo.

set -euo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail=0

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }

# Real disk, not /tmp: tmpfs would work for ownership but muddies the result
# if anyone later reuses this script to look at write behaviour.
SCRATCH="$(mktemp -d "$HOME/.cache/msb-spike02.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
note "scratch:  $SCRATCH ($(stat -f -c %T "$SCRATCH"))"
note "host id:  uid=$HOST_UID gid=$HOST_GID ($(id -un):$(id -gn))"

# A file that already exists, to test the guest writing to host-created content
# — the direction that actually matters when an agent edits a tracked file.
printf 'written on the host\n' >"$SCRATCH/from-host"

say "Running guest"
msb run \
	--mount-dir "$SCRATCH:/work:uid=$HOST_UID,gid=$HOST_GID" \
	-w /work --memory 2G \
	"$IMAGE" -- sh -c '
		set -e
		echo "guest: whoami=$(id -un) uid=$(id -u)"
		echo "guest: ls -ln /work"; ls -ln /work
		echo "guest: creating a file"
		printf "written in the guest\n" > /work/from-guest
		echo "guest: appending to the host-created file"
		printf "appended in the guest\n" >> /work/from-host
		echo "guest: done"
	'

say "Host-side verdict"
for f in from-guest from-host; do
	if [ ! -e "$SCRATCH/$f" ]; then
		printf '   %-12s MISSING\n' "$f"; fail=1; continue
	fi
	owner="$(stat -c '%u:%g' "$SCRATCH/$f")"
	name="$(stat -c '%U:%G' "$SCRATCH/$f")"
	if [ "$owner" = "$HOST_UID:$HOST_GID" ]; then
		printf '   %-12s %s (%s)  OK\n' "$f" "$owner" "$name"
	else
		printf '   %-12s %s (%s)  WRONG — expected %s\n' \
			"$f" "$owner" "$name" "$HOST_UID:$HOST_GID"
		fail=1
	fi
done

if grep -q 'appended in the guest' "$SCRATCH/from-host" 2>/dev/null; then
	note "guest append to a host-created file: OK"
else
	note "guest append to a host-created file: FAILED"
	fail=1
fi

# Can you delete what the guest made, without sudo? This is the specific
# misery the podman design warns about, so check it explicitly rather than
# inferring it from the uid.
if rm -f "$SCRATCH/from-guest" 2>/dev/null; then
	note "host can remove guest-created files without sudo: OK"
else
	note "host CANNOT remove guest-created files without sudo: FAILED"
	fail=1
fi

say "Result"
if [ "$fail" -eq 0 ]; then
	echo "   PASS — --mount-dir uid=/gid= presents guest writes as the host"
	echo "   user, so no keep-id mapping or SELinux relabelling is needed."
else
	echo "   FAIL — record the actual ownership above before changing anything."
	echo "   Try without uid=/gid= to see the default, and check whether"
	echo "   --volume behaves differently from --mount-dir."
fi
exit "$fail"
