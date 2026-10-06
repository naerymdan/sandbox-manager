#!/usr/bin/env bash
#
# 07-claude-token-secret.sh — can Claude Code authenticate from a placeholder?
#
# THE LOAD-BEARING SPIKE for this manager. It
# stops bind-mounting ~/.claude and ~/.claude.json into every sandbox — those
# carry the host's real credentials and every other project's transcripts — and
# binds a long-lived token instead:
#
#   --secret CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com
#
# microsandbox then puts an opaque placeholder in the guest environment and
# substitutes the real value host-side, into request HEADERS, only on egress to
# api.anthropic.com. The token never enters the VM.
#
# That works only if Claude Code treats the variable as an opaque string it
# forwards. If it parses the token, checks a prefix, or validates a length
# before sending, the placeholder fails and the whole credential design has to
# fall back to the bind mount.
#
# PASS: the guest sees a placeholder rather than the real token, AND
#       `claude -p` gets a real answer back from the API.
#
# Needs CLAUDE_CODE_OAUTH_TOKEN exported on the host:
#   claude setup-token        # then paste into ~/.config/msb/secrets/global.env
#
# This script never prints the token. It compares lengths and a truncated
# sha256 so a failure is still diagnosable from a pasted terminal.

set -uo pipefail

# Already has node, so the spike is one npm install rather than a NodeSource
# bootstrap. Nothing here depends on the devcontainers base image.
IMAGE="${IMAGE:-node:22-bookworm-slim}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail=0

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
	cat >&2 <<-'EOF'
	CLAUDE_CODE_OAUTH_TOKEN is not set.

	  claude setup-token          # on the host, generates a long-lived token
	  export CLAUDE_CODE_OAUTH_TOKEN=<the token>

	Nothing here works without it, and it must be in the environment rather
	than on the command line: `--secret` stores only a REFERENCE to the
	variable and msb rejects an inline `ENV=VALUE@HOST` outright.
	EOF
	exit 1
fi

host_len="${#CLAUDE_CODE_OAUTH_TOKEN}"
host_sha="$(printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | sha256sum | cut -c1-12)"
note "host token: ${host_len} chars, sha256 ${host_sha}…"
note "image:      $IMAGE"

say "Running guest"
# Deliberately the full policy the manager will use, not a relaxed one. A
# placeholder that works under an open network and fails under deny-by-default
# would be a result that does not transfer.
#
# --tls-intercept is required twice over: once because every HTTPS hostname
# rule is a silent deny without it, and once because substitution needs
# something to rewrite the headers of.
msb run \
	--memory 4G \
	--net-default-egress deny \
	--net-rule "allow@dns" \
	--net-rule "deny@public:tcp:80,deny@private:tcp:80" \
	--net-rule "allow@api.anthropic.com:tcp:443" \
	--net-rule "allow@registry.npmjs.org:tcp:443" \
	--tls-intercept \
	--secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
	--secret-violation-action block-and-log \
	"$IMAGE" -- bash -c '
		set -u

		echo "--- placeholder shape ---"
		# Never echo the value itself: if substitution is NOT working this is
		# the real token and it would land in a terminal and a scrollback.
		v="${CLAUDE_CODE_OAUTH_TOKEN:-}"
		if [ -z "$v" ]; then
			echo "GUEST_VAR=absent"
		else
			printf "GUEST_LEN=%s\n" "${#v}"
			printf "GUEST_SHA=%s\n" "$(printf "%s" "$v" | sha256sum | cut -c1-12)"
			# The documented form is $MSB_<NAME>. Report what it actually is
			# rather than asserting, so a changed convention is visible.
			case "$v" in
				*MSB_CLAUDE_CODE_OAUTH_TOKEN*) echo "GUEST_SHAPE=placeholder" ;;
				*)                             echo "GUEST_SHAPE=other" ;;
			esac
		fi

		echo "--- installing claude-code ---"
		npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 \
			|| { echo "NPM_INSTALL=failed"; exit 0; }
		echo "NPM_INSTALL=ok ($(claude --version 2>&1 | head -1))"

		echo "--- the actual question ---"
		# -p is non-interactive. A fresh container has no ~/.claude.json, so
		# this also answers whether the token alone is enough to skip
		# onboarding — which spike 09 depends on.
		out="$(claude -p "Reply with exactly the word PONG and nothing else." 2>&1)"
		rc=$?
		printf "CLAUDE_RC=%s\n" "$rc"
		printf "CLAUDE_OUT=%s\n" "$(printf "%s" "$out" | tr "\n" " " | cut -c1-300)"
	' 2>&1 | tee /tmp/spike07.$$

# tr -d '\r', and it is load-bearing. msb run gives the guest a TTY, so every
# line comes back CRLF-terminated and `rc` parses as "0<CR>" rather than "0" —
# which compares unequal to 0 and reports a passing run as a failure. Worse,
# printing such a value returns the cursor to column 0 and overwrites the line
# just written, so the verdict becomes unreadable at exactly the moment it
# matters.
out="$(tr -d '\r' < "/tmp/spike07.$$")"
rm -f "/tmp/spike07.$$"

say "Verdict"

guest_sha="$(printf '%s' "$out" | sed -n 's/^GUEST_SHA=//p' | head -1)"
shape="$(printf '%s' "$out" | sed -n 's/^GUEST_SHAPE=//p' | head -1)"

# 1. The token must not have crossed. This check stands on its own: even if
#    Claude Code turns out not to work this way, a leaked token is the thing
#    that would make the design unsafe rather than merely inconvenient.
if [ -z "$guest_sha" ]; then
	note "the variable did not reach the guest at all           FAIL"
	fail=1
elif [ "$guest_sha" = "$host_sha" ]; then
	note "the guest holds the REAL token (sha matches the host) FAIL"
	note "  substitution is not happening — do not ship this binding"
	fail=1
else
	note "guest value differs from the host token (${shape})    OK"
fi

# 2. And it must still authenticate.
rc="$(printf '%s' "$out" | sed -n 's/^CLAUDE_RC=//p' | head -1)"
if printf '%s' "$out" | grep -q 'NPM_INSTALL=failed'; then
	note "npm install failed — egress, not auth. Result inconclusive"
	fail=1
elif [ "${rc:-1}" = 0 ] && printf '%s' "$out" | grep -qi 'CLAUDE_OUT=.*PONG'; then
	note "claude -p authenticated and answered                  OK"
else
	note "claude -p did not answer (rc=${rc:-?})                FAIL"
	note "  read CLAUDE_OUT above: an auth error means the placeholder is"
	note "  rejected client-side, a network error means a missing rule."
	fail=1
fi

say "Result"
if [ "$fail" -eq 0 ]; then
	cat <<-'EOF'
	   PASS — Claude Code forwards the variable without inspecting it, so the
	   manager can bind it as a secret and stop mounting ~/.claude.json.
	EOF
else
	cat <<-'EOF'
	   FAIL — fall back to bind-mounting the host's ~/.claude and
	   ~/.claude.json, and set claude_auth = "mount" in
	   ~/.config/msb/config.toml.

	   That fallback is a real loss, not a cosmetic one: every sandbox then
	   holds the host's Claude credentials and every project's transcripts.
	   Worth re-running this after a claude-code upgrade.
	EOF
fi
exit "$fail"
