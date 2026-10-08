#!/usr/bin/env bash
#
# scripts/package.sh — build the release assets for one version.
#
#   scripts/package.sh [--version X.Y.Z] [--repo owner/name] [--out DIR]
#
# Produces, in DIR (default ./dist):
#   msb-manager-X.Y.Z.tar.gz   the tree get.sh installs: only the PAYLOAD below
#   get.sh                     the `curl | sh` entry point, tied to --repo
#   checksums.sha256           sha256 of both; get.sh verifies the tarball with it
#
# Publishing is deliberately not done here. When the assets look right:
#   gh release create vX.Y.Z dist/* --title vX.Y.Z --notes "..."
#
# A package is made of REAL FILES. The build fails if the staged tree contains a
# symlink, so nothing installed can depend on a path outside itself.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
OUT="$ROOT/dist"
VERSION=""
REPO="${MSB_MANAGER_REPO:-}"

# Keep in step with PAYLOAD in install.sh. Not shipped: .msb/ (this repo's own
# sandbox policy), scripts/ (this file), AGENTS.md/CLAUDE.md (for working ON the repo), .git.
PAYLOAD="msbctl msb-picker bootstrap.sh install.sh get.sh defaults.toml VERSION LICENSE README.md msb-manager.desktop templates profile spikes"

die()  { printf 'package: %s\n' "$*" >&2; exit 1; }
note() { printf 'package: %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift ;;
		--repo)    [ $# -ge 2 ] || die "--repo needs owner/name"; REPO="$2"; shift ;;
		--out)     [ $# -ge 2 ] || die "--out needs a directory"; OUT="$2"; shift ;;
		-h|--help) sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
	shift
done

[ -n "$VERSION" ] || VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
	|| die "version '$VERSION' is not like 1.2.3 (optionally -rc1 or +build)"

# The repository get.sh will download from: --repo, $MSB_MANAGER_REPO, or origin.
if [ -z "$REPO" ] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
	REPO="$(printf '%s' "$url" | sed -nE 's#^(https://github.com/|ssh://git@github.com/|git@github.com:)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')"
fi
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
	|| die "which GitHub repository? pass --repo owner/name (or set MSB_MANAGER_REPO)"

# ------------------------------------------------------------------ sanity
note "checking the tree"
for f in $PAYLOAD; do
	[ "$f" = VERSION ] && continue
	[ "$f" = get.sh ] && continue
	[ -e "$ROOT/$f" ] || die "payload item missing: $f"
done
[ -f "$ROOT/get.sh" ] || die "get.sh is missing"
python3 -m py_compile "$ROOT/msbctl" || die "msbctl does not compile"
rm -rf "$ROOT/__pycache__"
for f in install.sh get.sh bootstrap.sh msb-picker; do
	bash -n "$ROOT/$f" || die "$f has a syntax error"
done
[ -s "$ROOT/profile/CLAUDE.md" ] || die "profile/CLAUDE.md is missing or empty — sandboxes would get no central text"

# --------------------------------------------------------------------- stage
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
NAME="msb-manager-$VERSION"
STAGE="$STAGE_ROOT/$NAME"
mkdir -p "$STAGE" "$OUT"
OUT="$(cd "$OUT" && pwd)"

for item in $PAYLOAD; do
	[ -e "$ROOT/$item" ] && cp -R "$ROOT/$item" "$STAGE/"
done
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# The copy inside the package and the release asset are the same file, tied to REPO.
sed "s#@@GITHUB_REPO@@#$REPO#g" "$ROOT/get.sh" > "$STAGE/get.sh"

# What must not be in a package.
find "$STAGE" \( -name __pycache__ -o -name '*.pyc' -o -name '.git' -o -name '*.swp' -o -name '.DS_Store' \) -prune -exec rm -rf {} +
if [ -n "$(find "$STAGE" -type l -print -quit)" ]; then
	find "$STAGE" -type l >&2
	die "the staged tree contains symbolic links (listed above); a package must be real files"
fi
if [ -n "$(find "$STAGE" \( -name '*.env' -o -name 'secrets' \) -print -quit)" ]; then
	die "the staged tree contains something that looks like a secret"
fi
if grep -rIl '@@GITHUB_REPO@@' "$STAGE" >/dev/null 2>&1; then
	die "an unreplaced @@GITHUB_REPO@@ placeholder is left in the package"
fi

# Modes are set here, not inherited: whatever the build machine's umask made the
# working files must not decide what users get. Directories 755; a file is 755 if
# it is a script (starts with #!) and 644 otherwise; nothing is group/other-writable.
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f | while IFS= read -r f; do
	if [ "$(head -c 2 "$f")" = '#!' ]; then chmod 755 "$f"; else chmod 644 "$f"; fi
done

# ------------------------------------------------------------------- archive
# Reproducible: sorted, no owners, a fixed mtime, and gzip without a timestamp, so
# building the same tree twice gives the same bytes and the same checksum.
EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}"
TARBALL="$OUT/$NAME.tar.gz"
( cd "$STAGE_ROOT" && tar --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$EPOCH" -cf - "$NAME" ) | gzip -n -9 > "$TARBALL"

cp "$STAGE/get.sh" "$OUT/get.sh"
( cd "$OUT" && sha256sum "$NAME.tar.gz" get.sh > checksums.sha256 )

note "version     $VERSION"
note "repository  $REPO"
note "contents    $(tar -tzf "$TARBALL" | wc -l) entries, $(du -h "$TARBALL" | cut -f1)"
note "wrote       $OUT/{$NAME.tar.gz,get.sh,checksums.sha256}"
echo
sed 's/^/  /' "$OUT/checksums.sha256"
echo
note "publish:    gh release create v$VERSION $OUT/* --title v$VERSION"
note "then users: curl -fsSL https://github.com/$REPO/releases/latest/download/get.sh | sh"
