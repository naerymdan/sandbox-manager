#!/usr/bin/env bash
#
# install.sh — wire msb-manager into this user's session. Idempotent.
#
#   install.sh [--dev | --package] [--prefix DIR] [--bin-dir DIR] [--no-desktop]
#   install.sh --uninstall [--yes]
#
# TWO MODES, picked by where this script is run from:
#
#   dev      (a git checkout)   symlinks msbctl and msb-picker into the checkout,
#                               so `git pull` updates them with no reinstall step.
#   package  (anything else,    COPIES the tree to <prefix>/versions/<version>/ and
#            e.g. a release)    points <prefix>/current at it. The commands in bin
#                               link through `current`, so an upgrade is one atomic
#                               switch and never depends on a checkout staying put.
#
# Either way, what you are expected to edit is a REAL file, never a link into the
# tree, and is never overwritten once it exists:
#   ~/.config/msb/config.toml         your overrides on top of defaults.toml
#   ~/.config/msb/CLAUDE.local.md     your additions to the CLAUDE.md sandboxes get
# (msb-manager's own part of that CLAUDE.md ships in the tree and is assembled with
# yours at each sandbox start.)
#
# Never reads stdin: `curl ... | sh` hands get.sh to a shell over stdin, and this
# script is run underneath it.

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
PREFIX="$DATA_HOME/msb-manager"
BIN="$HOME/.local/bin"
APPS="$DATA_HOME/applications"
CONFIG="${MSB_CONFIG_DIR:-$HOME/.config/msb}"
STATE="${MSB_STATE_DIR:-$HOME/.local/state/msb}"
KEEP_VERSIONS=2          # the current one and the one before it, to roll back to

# What a package contains, and what a checkout has that a package must not carry
# (.msb/ is THIS repo's own sandbox policy, scripts/ builds releases, CLAUDE.md is
# for working on the repo).
PAYLOAD="msbctl msb-picker bootstrap.sh install.sh get.sh defaults.toml VERSION LICENSE README.md msb-manager.desktop templates profile spikes"

MODE=""
DESKTOP=1
UNINSTALL=0
ASSUME_YES=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*" >&2; }
die()  { printf '\n   ERROR: %s\n\n' "$*" >&2; exit 1; }

usage() {
	sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<'EOF'

  --dev          symlink into this git checkout (default when run from one)
  --package      copy the tree under --prefix (default when run from a release)
  --prefix DIR   where a package install lives   [~/.local/share/msb-manager]
  --bin-dir DIR  where the msbctl / msb-picker commands go   [~/.local/bin]
  --no-desktop   do not write the desktop entry
  --uninstall    remove the commands, the installed tree and the desktop entry;
                 your config, secrets and sandboxes are left alone
  --yes          do not ask before --uninstall removes the tree
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dev) MODE=dev ;;
		--package) MODE=package ;;
		--prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX="$2"; shift ;;
		--bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a directory"; BIN="$2"; shift ;;
		--no-desktop) DESKTOP=0 ;;
		--uninstall) UNINSTALL=1 ;;
		--yes|-y) ASSUME_YES=1 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

if [ -z "$MODE" ]; then
	if [ -e "$HERE/.git" ]; then MODE=dev; else MODE=package; fi
fi

VERSION="$(cat "$HERE/VERSION" 2>/dev/null || true)"
VERSION="${VERSION:-unknown}"
CURRENT="$PREFIX/current"

# ------------------------------------------------------------------ uninstall
if [ "$UNINSTALL" -eq 1 ]; then
	say "Uninstall"
	# Remove a command link only if it is OURS: pointing into the install tree or
	# this checkout. Anything else at that path belongs to someone else.
	for tool in msbctl msb-picker; do
		link="$BIN/$tool"
		[ -L "$link" ] || continue
		target="$(readlink "$link")"
		case "$target" in
			"$PREFIX"/*|"$HERE"/*) rm -f "$link"; note "removed $link" ;;
			*) note "left $link alone (points at $target)" ;;
		esac
	done
	if [ -f "$APPS/msb-manager.desktop" ]; then
		rm -f "$APPS/msb-manager.desktop"
		note "removed $APPS/msb-manager.desktop"
	fi
	if [ -d "$PREFIX" ]; then
		if [ "$ASSUME_YES" -ne 1 ]; then
			if [ -t 0 ]; then
				printf '   remove %s (every installed version)? [y/N] ' "$PREFIX"
				read -r reply || reply=n
				case "$reply" in y|Y|yes|YES) ;; *) note "kept $PREFIX"; PREFIX_KEEP=1 ;; esac
			else
				note "kept $PREFIX (not interactive: re-run with --yes to remove it)"
				PREFIX_KEEP=1
			fi
		fi
		if [ -z "${PREFIX_KEEP:-}" ]; then
			rm -rf "$PREFIX"      # fine even when this script is inside it: the open file stays readable
			note "removed $PREFIX"
		fi
	fi
	note ""
	note "Left in place — yours, and not recreated by an install:"
	note "  $CONFIG       config.toml, CLAUDE.local.md, secrets/, sandboxes/"
	note "  $STATE        Claude state, caches, agent sockets"
	note "Sandboxes themselves are msb's: \`msb ls\`, \`msb rm <name>\`, \`msb volume ls\`."
	exit 0
fi

missing=()

# ------------------------------------------------------------------ preflight
say "Preflight"

# Python's stdlib is split into subpackages on some distributions, and a
# minimal install can be missing tomllib or urllib while still running. Check
# what msbctl actually imports rather than just the interpreter version — the
# failure otherwise arrives much later, as a traceback from the picker.
PY_PREFLIGHT='
import sys
if sys.version_info < (3, 11):
    print("version %d.%d (need 3.11+ for tomllib)" % sys.version_info[:2])
    raise SystemExit
gone = []
for mod in ("tomllib", "urllib.request", "http.client", "getpass",
            "argparse", "json", "shutil", "subprocess"):
    try:
        __import__(mod)
    except ImportError:
        gone.append(mod)
print("missing modules: " + ", ".join(gone) if gone else "ok")
'

if ! command -v python3 >/dev/null; then
	missing+=("python3")
else
	py_report="$(python3 -c "$PY_PREFLIGHT" 2>/dev/null || true)"
	if [ "$py_report" = ok ]; then
		note "python3 $(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))')  ok"
	else
		warn "python3: $py_report"
		missing+=("a complete python3 stdlib (dnf install python3-libs, or apt install python3)")
	fi
fi

command -v msb >/dev/null || missing+=("msb (microsandbox) — https://github.com/superradcompany/microsandbox")
# Optional, so a warning rather than a hard stop: msbctl degrades to a
# numbered menu without it and says what it cannot do. The picker needs it.
command -v fzf >/dev/null \
	|| warn "fzf not found — the menu falls back to a numbered prompt and the
           picker will not run (dnf/apt install fzf)"
command -v git >/dev/null || missing+=("git")

TERMINAL=konsole
if ! command -v konsole >/dev/null; then
	for alt in alacritty foot gnome-terminal xterm; do
		command -v "$alt" >/dev/null && { TERMINAL="$alt"; break; }
	done
	# Also optional: only the desktop entry needs one. msbctl runs in whatever
	# terminal you already have.
	if [ "$TERMINAL" = konsole ]; then
		warn "no terminal emulator found — the desktop entry will not work"
		TERMINAL=xterm
	fi
fi
note "terminal: $TERMINAL"

EDITOR_BIN="${MSB_EDITOR:-codium}"
command -v "$EDITOR_BIN" >/dev/null \
	|| warn "$EDITOR_BIN not found — 'open editor' will fail until you set MSB_EDITOR"

[ -e /dev/kvm ] || warn "no /dev/kvm — microsandbox cannot run on this machine"

if [ "${#missing[@]}" -gt 0 ]; then
	printf '\n   Install these first:\n'
	printf '     - %s\n' "${missing[@]}"
	exit 1
fi

# ---------------------------------------------------------------------- tools
say "Tools ($MODE)"
mkdir -p "$BIN"

if [ "$MODE" = package ]; then
	for item in msbctl msb-picker bootstrap.sh defaults.toml templates profile; do
		[ -e "$HERE/$item" ] || die "this is not a complete msb-manager tree: $item is missing from $HERE"
	done
	dest="$PREFIX/versions/$VERSION"
	mkdir -p "$PREFIX/versions"
	stage="$PREFIX/versions/.stage.$$"
	rm -rf "$stage"
	mkdir "$stage"
	trap 'rm -rf "$stage"' EXIT
	for item in $PAYLOAD; do
		[ -e "$HERE/$item" ] && cp -R "$HERE/$item" "$stage/"
	done
	# A package is made of real files. A symlink in it would point out of the tree
	# it was copied from, which is exactly what installing a copy is meant to avoid.
	if [ -n "$(find "$stage" -type l -print -quit)" ]; then
		die "the source tree contains symbolic links; refusing to install a copy that depends on them"
	fi
	# Modes set here too, since this may be run from any tree: directories 755, a
	# script (starts with #!) 755, anything else 644. Nothing group/other-writable.
	find "$stage" -type d -exec chmod 755 {} +
	find "$stage" -type f | while IFS= read -r f; do
		if [ "$(head -c 2 "$f")" = '#!' ]; then chmod 755 "$f"; else chmod 644 "$f"; fi
	done
	rm -rf "$dest"
	mv "$stage" "$dest"
	trap - EXIT
	note "installed $VERSION -> $dest"

	# One atomic switch: everything in bin links through `current`.
	ln -sfn "versions/$VERSION" "$CURRENT"
	note "$CURRENT -> versions/$VERSION"
	TOOLDIR="$CURRENT"

	# Keep the new version and the previous one; drop older ones.
	# shellcheck disable=SC2012
	old_versions="$(ls -1t "$PREFIX/versions" 2>/dev/null | tail -n +$((KEEP_VERSIONS + 1)) || true)"
	for old in $old_versions; do
		if [ "$old" != "$VERSION" ]; then
			rm -rf "$PREFIX/versions/$old"
			note "removed old version $old"
		fi
	done
else
	chmod +x "$HERE/msbctl" "$HERE/msb-picker"
	TOOLDIR="$HERE"
fi

for tool in msbctl msb-picker; do
	ln -sfn "$TOOLDIR/$tool" "$BIN/$tool"
	note "$BIN/$tool -> $TOOLDIR/$tool"
done

case ":$PATH:" in
	*":$BIN:"*) ;;
	*) warn "$BIN is not on your PATH — add it to ~/.bashrc: export PATH=\"$BIN:\$PATH\"" ;;
esac

# --------------------------------------------------------------------- config
say "Configuration"
mkdir -p "$CONFIG/sandboxes" "$STATE/claude"
chmod 700 "$CONFIG"
install -d -m 0700 "$CONFIG/secrets"

# The shipped defaults (rule groups, pins) are read from the tree, so there is
# nothing to copy for them and an upgrade replaces them. config.toml is only YOUR
# overrides, written once as a short skeleton and never touched again.
if [ -f "$CONFIG/config.toml" ]; then
	note "config.toml exists — kept (yours; shipped defaults are $TOOLDIR/defaults.toml)"
else
	install -m 0644 "$TOOLDIR/templates/config.toml.in" "$CONFIG/config.toml"
	note "wrote $CONFIG/config.toml (a skeleton of overrides)"
fi

if [ -f "$CONFIG/secrets/global.env" ]; then
	note "secrets/global.env present"
else
	umask 077
	cat >"$CONFIG/secrets/global.env" <<-'EOF'
	# Shared by every sandbox. 0600. NEVER commit this file.
	#
	# A long-lived Claude Code credential. Generate with `claude setup-token`.
	# msbctl binds it as --secret CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com,
	# platform.claude.com, so the value stays on the host: the guest sees an
	# opaque placeholder and the real token is substituted into request headers
	# on the way out, only to those two Anthropic endpoints.
	#CLAUDE_CODE_OAUTH_TOKEN=

	# Optional, HOST-SIDE ONLY: raises the api.github.com rate limit for the
	# release-version probes. Never bound into a sandbox — per-project tokens
	# live in secrets/<name>.env.
	#GH_TOKEN=
	EOF
	chmod 600 "$CONFIG/secrets/global.env"
	note "wrote $CONFIG/secrets/global.env (0600)"
fi

# ------------------------------------------------------------------- launcher
if [ "$DESKTOP" -eq 1 ]; then
	say "Desktop entry"
	mkdir -p "$APPS"
	sed -e "s|^Exec=.*|Exec=$TERMINAL --separate -e $BIN/msb-picker|" \
		"$TOOLDIR/msb-manager.desktop" >"$APPS/msb-manager.desktop"
	# gnome-terminal and xterm do not take --separate.
	case "$TERMINAL" in
		konsole) ;;
		*) sed -i "s|$TERMINAL --separate -e|$TERMINAL -e|" "$APPS/msb-manager.desktop" ;;
	esac
	chmod 644 "$APPS/msb-manager.desktop"
	command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
	note "wrote $APPS/msb-manager.desktop"
fi

say "Done"
note "msb-manager $VERSION ($MODE)"
# No backticks in this unquoted heredoc: they are command substitution, and once
# ran `msbctl setup` in the middle of an install. Single quotes are text.
cat <<EOF
   Next:
     1. msbctl                     the first run walks you through your git identities,
                                   Claude login and your own network (homelab, …); all
                                   optional, and 'msbctl setup' returns to any of it
     2. cd <a project> && msbctl add
     3. msbctl start <name>        (the first start runs the bootstrap)

   Upgrade:   $( [ "$MODE" = package ] && echo "msbctl self-update" || echo "git pull" )
   Remove:    $TOOLDIR/install.sh --uninstall

   The desktop entry is "Sandboxes". It starts the autostart set and opens the
   picker; nothing in it attaches by default — Enter opens $EDITOR_BIN on the
   project and you shell in from there.
EOF
