#!/bin/sh
#
# scripts/screenshots/make.sh — regenerate the README/docs screenshots.
#
#     scripts/screenshots/make.sh [OUT_DIR]     # default docs/assets/screenshots
#
# They are REAL screens: the real msbctl and msb-picker, run in a tmux of a
# fixed size, captured with their colours and rendered to SVG by render.py.
# Only the data is invented — world.py builds a throwaway HOME with three made-up
# sandboxes, and bin/msb stands in for microsandbox (no VM, no /dev/kvm; the
# bin/msbctl wrapper skips that one preflight). So a change to what a screen
# shows needs nothing here but a re-run.
#
# Needs tmux, fzf and ssh-keygen; rsvg-convert is optional and only writes PNG
# previews beside the SVGs. Timing is by sleep, so a slow machine may need
# MSB_SHOTS_DELAY raised. fzf's look varies a little by version.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-$ROOT/docs/assets/screenshots}
DELAY=${MSB_SHOTS_DELAY:-3}

for tool in tmux fzf ssh-keygen python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "make.sh: needs $tool" >&2; exit 1; }
done

WORK=$(mktemp -d)
SOCK=msb-shots-$$
trap 'tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$WORK"' EXIT
FAKE_HOME=$(python3 "$HERE/world.py" "$WORK/world")
mkdir -p "$OUT"

# Everything a screen runs goes through this, so no setting from the real HOME
# (config, sandboxes, fzf options, ssh-agent) leaks into a screenshot. fzf gets
# the plain 16-colour scheme, which render.py maps onto the docs' palette.
cat > "$WORK/run" <<EOF
#!/bin/sh
exec env -i PATH="$HERE/bin:$PATH" HOME="$FAKE_HOME" TERM=xterm-256color LANG=C.UTF-8 \\
	MSBCTL_REAL="$ROOT/msbctl" MSBCTL=msbctl MSB_NO_AUTOSTART=1 \\
	MSB_CONFIG_DIR="$FAKE_HOME/.config/msb" MSB_STATE_DIR="$FAKE_HOME/.local/state/msb" \\
	FZF_DEFAULT_OPTS=--color=16 SSH_AUTH_SOCK=/nonexistent EDITOR=nano "\$@"
EOF
chmod +x "$WORK/run"

# shoot NAME COLS ROWS TITLE KEYS COMMAND...
#   KEYS: space-separated tmux key names sent one by one, or - for none.
shoot() {
	name=$1 cols=$2 rows=$3 title=$4 keys=$5
	shift 5
	tmux -L "$SOCK" -f /dev/null new-session -d -x "$cols" -y "$rows" -s "$name" \
		"cd '$FAKE_HOME' && '$WORK/run' $*; sleep 60"
	sleep "$DELAY"
	if [ "$keys" != - ]; then
		for key in $keys; do
			tmux -L "$SOCK" send-keys -t "$name" "$key"
			sleep 0.5
		done
		sleep "$DELAY"
	fi
	tmux -L "$SOCK" capture-pane -p -e -t "$name" > "$WORK/$name.ansi"
	tmux -L "$SOCK" kill-session -t "$name"
	python3 "$HERE/render.py" "$WORK/$name.ansi" "$OUT/$name.svg" "$title" "$cols"
	if command -v rsvg-convert >/dev/null 2>&1 && [ -n "${MSB_SHOTS_PNG:-}" ]; then
		rsvg-convert -z 1.5 "$OUT/$name.svg" -o "$WORK/$name.png" && cp "$WORK/$name.png" "$MSB_SHOTS_PNG/"
	fi
	echo "$OUT/$name.svg"
}

# The main menu, with the sandbox sidebar.
shoot menu 140 22 "msbctl" - msbctl
# The picker, cursor on the sandbox with the most to show.
shoot picker 170 34 "msb-picker — manage sandboxes" "j j" "$ROOT/msb-picker"
# The add wizard down to its feature list: blank repo (so nothing asks GitHub
# about a repository that does not exist), default identity, the one key, Claude,
# then python and go ticked.
shoot add 96 46 "msbctl add api-gateway" \
	"Enter Enter Enter Space Enter Enter Down Down Down Down Space Down Down Space" \
	msbctl add api-gateway
