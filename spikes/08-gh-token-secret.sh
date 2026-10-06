#!/usr/bin/env bash
#
# 08-gh-token-secret.sh — does a fine-grained PAT survive placeholder substitution?
#
# The manager gives each sandbox its own fine-grained PAT, bound per project:
#
#   --secret GH_TOKEN@github.com,api.github.com
#
# Substitution is HEADERS ONLY, per msb's own documentation. This spike proves
# the half that is observable from inside a guest, and is explicit about the
# half that is not:
#
#   positive  — a token sent in an Authorization header reaches GitHub, while
#               the guest's own copy of the variable is a placeholder. Both
#               halves are directly checkable and this spike checks them.
#
#   negative  — whether a placeholder in a QUERY STRING is left unsubstituted.
#               NOT DECIDABLE HERE. Such a request carries no Authorization
#               header, so GitHub rejects it identically whether the real token
#               was substituted in or not, and the guest can only see what it
#               sent, never what left the host. The probe runs and its status
#               code is reported, but a rejection is recorded as INCONCLUSIVE
#               rather than as proof of safety. Confirming it means reading the
#               host-side msb log, which this script does not parse.
#
# Note that `https://user:pass@host` is NOT the URL case — curl converts
# userinfo into an Authorization header before sending, so it is a header and
# substitution correctly applies. An earlier version of this spike tested that
# form and would have read a successful request as a leak.
#
# PASS: the guest holds a placeholder, and `curl` with an Authorization header
#       and `gh api user` both identify the account.
#
# Needs GH_TOKEN exported on the host — a fine-grained PAT with at least
# `Metadata: read` on one repository. See ../README.md.

set -uo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
GH_VERSION="${GH_VERSION:-2.102.0}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail=0

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }
[ -n "${GH_TOKEN:-}" ] || {
	echo "GH_TOKEN is not set — export a fine-grained PAT first" >&2; exit 1; }

host_sha="$(printf '%s' "$GH_TOKEN" | sha256sum | cut -c1-12)"
note "host token: ${#GH_TOKEN} chars, sha256 ${host_sha}…"

say "Running guest"
msb run \
	--memory 2G \
	--net-default-egress deny \
	--net-rule "allow@dns" \
	--net-rule "deny@public:tcp:80,deny@private:tcp:80" \
	--net-rule "allow@github.com:tcp:443" \
	--net-rule "allow@api.github.com:tcp:443" \
	--net-rule "allow@release-assets.githubusercontent.com:tcp:443" \
	--net-rule "allow@objects.githubusercontent.com:tcp:443" \
	--tls-intercept \
	--secret "GH_TOKEN@github.com,api.github.com" \
	--secret-violation-action block-and-log \
	"$IMAGE" -- bash -c '
		set -u
		# $1, not interpolation: the body is single-quoted so that every
		# $GH_TOKEN below expands in the GUEST. Interpolating the host value
		# in would defeat the entire point of the spike.
		GH_VERSION="$1"

		v="${GH_TOKEN:-}"
		if [ -z "$v" ]; then
			echo "GUEST_VAR=absent"
		else
			printf "GUEST_SHA=%s\n" "$(printf "%s" "$v" | sha256sum | cut -c1-12)"
		fi

		echo "--- positive: Authorization header ---"
		code="$(curl -sS -o /tmp/me.json -w "%{http_code}" \
			-H "Authorization: Bearer $GH_TOKEN" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			https://api.github.com/user 2>/tmp/curl.err)" || code="curl-failed"
		printf "HEADER_CODE=%s\n" "$code"
		printf "HEADER_LOGIN=%s\n" "$(sed -n "s/.*\"login\": *\"\([^\"]*\)\".*/\1/p" /tmp/me.json 2>/dev/null | head -1)"
		[ "$code" = curl-failed ] && printf "HEADER_ERR=%s\n" "$(head -c 200 /tmp/curl.err)"

		echo "--- negative: token in the query string ---"
		# A QUERY STRING, not curls userinfo syntax. This matters and is easy
		# to get wrong: `https://user:pass@host` is NOT a URL-embedded secret
		# as far as the wire is concerned — curl strips the userinfo and sends
		# an `Authorization: Basic base64(user:pass)` header instead. That is a
		# header, so substitution applies and the request SUCCEEDS, which looks
		# exactly like a leak and is not one.
		#
		# A query string is genuinely outside the headers, so it is the only
		# form that tests the boundary. It cannot authenticate to GitHub under
		# any circumstances, so the verdict is about WHETHER THE REAL VALUE
		# WENT OUT, not about the status code.
		ncode="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 \
			"https://api.github.com/user?probe=$GH_TOKEN" 2>/tmp/neg.err)" \
			|| ncode="blocked"
		printf "URL_CODE=%s\n" "$ncode"
		printf "URL_ERR=%s\n" "$(head -c 160 /tmp/neg.err | tr "\n" " ")"

		echo "--- gh ---"
		arch=amd64; [ "$(uname -m)" = aarch64 ] && arch=arm64
		base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"
		tgz="gh_${GH_VERSION}_linux_${arch}.tar.gz"
		if curl -fsSL -o "/tmp/$tgz" "$base/$tgz" \
			&& tar -xzf "/tmp/$tgz" -C /tmp \
			&& install "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh
		then
			printf "GH_API=%s\n" "$(gh api user --jq .login 2>&1 | tr "\n" " " | cut -c1-200)"
		else
			echo "GH_API=install-failed"
		fi
	' _ "$GH_VERSION" 2>&1 | tee "/tmp/spike08.$$"

# tr -d '\r' first: msb run gives the guest a TTY, so lines arrive CRLF and
# every field below would carry a trailing carriage return — which compares
# unequal to the literal it is checked against, and overwrites the line it was
# just printed on.
out="$(tr -d '\r' < "/tmp/spike08.$$")"; rm -f "/tmp/spike08.$$"

# Trailing whitespace is stripped for the same reason as the \r above, and it
# bites in the same way. GH_API is produced by `… | tr "\n" " "`, which is there
# to flatten a multi-line error onto one line but which also turns the trailing
# newline of a SUCCESSFUL run into a trailing space. "octocat " then compares
# unequal to "octocat" and a passing run is reported as a failure.
field() { printf '%s' "$out" | sed -n "s/^$1=//p" | head -1 | sed 's/[[:space:]]*$//'; }

say "Verdict"

guest_sha="$(field GUEST_SHA)"
if [ -z "$guest_sha" ]; then
	note "the variable did not reach the guest                  FAIL"; fail=1
elif [ "$guest_sha" = "$host_sha" ]; then
	note "the guest holds the REAL token                        FAIL"
	note "  no substitution — a sandbox could exfiltrate this anywhere"
	fail=1
else
	note "guest value is a placeholder                          OK"
fi

login="$(field HEADER_LOGIN)"
if [ "$(field HEADER_CODE)" = 200 ] && [ -n "$login" ]; then
	note "Authorization header reached GitHub as '$login'       OK"
else
	note "Authorization header did NOT authenticate             FAIL"
	note "  code=$(field HEADER_CODE) err=$(field HEADER_ERR)"
	fail=1
fi

url_code="$(field URL_CODE)"
case "$url_code" in
	blocked|000)
		note "query-string placeholder refused outright             OK"
		note "  --secret-violation-action blocked it; check the host log" ;;
	401|403|404|422)
		note "query-string probe rejected by GitHub         INCONCLUSIVE"
		note "  READ THIS BEFORE TREATING IT AS A PASS. The request carries no"
		note "  Authorization header, so GitHub answers $url_code whether the"
		note "  placeholder was substituted or not. The status code cannot tell"
		note "  the two apart, and nothing inside the guest can: it sees what it"
		note "  sent, never what left the host."
		note "  This half is therefore NOT verified here. msb documents"
		note "  substitution as headers-only; to confirm it, read the host-side"
		note "  msb log for this run and check whether a violation was recorded"
		note "  for the query-string request." ;;
	*)
		note "query-string probe returned $url_code                 INVESTIGATE"
		note "  neither a block nor an obvious rejection. Confirm by hand that"
		note "  the value on the wire was the placeholder, not the token."
		fail=1 ;;
esac

gh_api="$(field GH_API)"
case "$gh_api" in
	install-failed) note "gh could not be installed — inconclusive, not a verdict" ;;
	"$login")       note "gh api user agrees ('$gh_api')                       OK" ;;
	*)              note "gh api user said: $gh_api                            FAIL"; fail=1 ;;
esac

say "Result"
if [ "$fail" -eq 0 ]; then
	echo "   PASS — per-project PATs can be bound as secrets: the guest never"
	echo "   holds the real token, and the header path authenticates."
	echo ""
	echo "   Scope. This says nothing about query strings or request bodies."
	echo "   See the INCONCLUSIVE note above: that boundary is msb's documented"
	echo "   behaviour, not something this run measured."
else
	echo "   FAIL — a header failure is a wiring problem. A guest holding the"
	echo "   real token is a substitution failure and blocks the design."
fi
exit "$fail"
