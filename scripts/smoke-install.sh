#!/usr/bin/env bash
#
# scripts/smoke-install.sh — build the release assets and install them the way a
# user would, into a throwaway HOME. Proves that package.sh, get.sh and
# install.sh agree with each other, which no static check can. CI runs it.
#
#   scripts/smoke-install.sh
#
# Nothing outside a temporary directory is touched. msb itself is not needed:
# the installer warns that it is missing and carries on.

set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home" "$tmp/dist" "$tmp/stub"

# install.sh refuses to proceed without an msb on PATH, and nothing here runs
# it, so a stub that exists is enough.
printf '#!/bin/sh\necho "msb 0.0.0 (smoke-test stub)"\n' > "$tmp/stub/msb"
chmod +x "$tmp/stub/msb"
export PATH="$tmp/stub:$PATH"

"$ROOT/scripts/package.sh" --repo "${GITHUB_REPOSITORY:-owner/name}" --out "$tmp/dist" >/dev/null

# get.sh verifies the tarball against checksums.sha256 before installing, so a
# bad package fails here rather than being installed.
export HOME="$tmp/home"
unset XDG_DATA_HOME MSB_CONFIG_DIR MSB_STATE_DIR
MSB_MANAGER_BASE_URL="file://$tmp/dist" sh "$tmp/dist/get.sh" --version "v$VERSION" --no-desktop

fail=0
for f in .local/bin/msbctl .local/bin/msb-picker; do
	if [ -x "$HOME/$f" ]; then echo "  ok    $f installed"; else echo "  FAIL  $f missing or not executable"; fail=1; fi
done
if "$HOME/.local/bin/msbctl" --version | grep -q "$VERSION"; then
	echo "  ok    msbctl --version reports $VERSION"
else
	echo "  FAIL  msbctl --version does not mention $VERSION"; fail=1
fi
exit "$fail"
