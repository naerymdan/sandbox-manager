#!/usr/bin/env bash
#
# 03-lan-allowlist.sh — does a per-port rule really mean per-port?
#
# A sandbox that needs one service on one machine should get exactly that, not
# the machine. This asserts both halves of that claim, and the negative half is
# the point: a rule set that allows ALLOW_HOST:ALLOW_PORT is worthless if it
# also allows the admin interface on the next port along.
#
# The sharpest case is SAME_HOST_DENY_PORT — a DIFFERENT PORT ON THE ALLOWED
# HOST. If a host-level allow quietly covered every port, the grammar would be
# coarser than it reads, and nothing else in this suite would notice.
#
# Set these to your own network before running. There are no defaults: a wrong
# guess would make this pass for the wrong reason.
#
#   ALLOW_HOST            an address the sandbox should reach
#   ALLOW_PORT            the one port on it that should be reachable
#   SAME_HOST_DENY_PORT   another port on ALLOW_HOST that must NOT be
#   DENY_HOST             a different address that must NOT be reachable
#   DENY_PORT             the port to try on it
#
#   ALLOW_HOST=10.0.0.10 ALLOW_PORT=22 SAME_HOST_DENY_PORT=443 \
#   DENY_HOST=10.0.0.1 DENY_PORT=443 ./03-lan-allowlist.sh
#
# PASS requires every case: the one allow works, and all three denies deny.
#
# No apt, no packages: every probe is bash's /dev/tcp. With deny-by-default in
# force the guest cannot install anything, so a probe that needed nc would be
# untestable under the very conditions it exists to test.
#
# DO NOT POINT THIS AT A HOST THAT SLEEPS. Unanswered probes can drive a
# router's neighbour entry to FAILED, where it is reaped — which breaks unicast
# Wake-on-LAN for that host. A scripted probe is a healthcheck, whatever you
# call it.

set -uo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
ALLOW_HOST="${ALLOW_HOST:?set ALLOW_HOST to an address the sandbox should reach}"
ALLOW_PORT="${ALLOW_PORT:?set ALLOW_PORT to the one port that should be open}"
SAME_HOST_DENY_PORT="${SAME_HOST_DENY_PORT:?set SAME_HOST_DENY_PORT to another port on ALLOW_HOST}"
DENY_HOST="${DENY_HOST:?set DENY_HOST to an address that must stay unreachable}"
DENY_PORT="${DENY_PORT:?set DENY_PORT to the port to try on DENY_HOST}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail=0

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }
if [ "$ALLOW_PORT" = "$SAME_HOST_DENY_PORT" ]; then
	echo "ALLOW_PORT and SAME_HOST_DENY_PORT are the same port — the test" >&2
	echo "that matters most would be comparing a rule against itself" >&2
	exit 1
fi
note "allow   ${ALLOW_HOST}:${ALLOW_PORT}"
note "deny    ${ALLOW_HOST}:${SAME_HOST_DENY_PORT}   (same host, other port)"
note "deny    ${DENY_HOST}:${DENY_PORT}"
note "deny    example.com:443        (the open internet)"

# ONE rule, naming one host and one port. Everything else is the default deny.
probe='
	try() {   # try <label> <host> <port>
		if timeout 6 bash -c "echo > /dev/tcp/$2/$3" 2>/dev/null; then
			echo "$1=open"
		else
			echo "$1=closed"
		fi
	}
	try ALLOW '"$ALLOW_HOST $ALLOW_PORT"'
	try SAMEHOST '"$ALLOW_HOST $SAME_HOST_DENY_PORT"'
	try OTHERHOST '"$DENY_HOST $DENY_PORT"'
	try INTERNET example.com 443
'

say "Running guest"
out="$(msb run --memory 2G \
	--net-default-egress deny \
	--net-rule "allow@dns" \
	--net-rule "allow@${ALLOW_HOST}:tcp:${ALLOW_PORT}" \
	"$IMAGE" -- bash -c "$probe" 2>&1 | tr -d '\r')"
printf '%s\n' "$out" | sed 's/^/   /'

field() { printf '%s' "$out" | sed -n "s/^$1=//p" | head -1 | sed 's/[[:space:]]*$//'; }

say "Verdict"
check() {   # check <field> <expected> <description>
	local got; got="$(field "$1")"
	if [ -z "$got" ]; then
		note "$3  — no result                                 FAIL"
		fail=1
	elif [ "$got" = "$2" ]; then
		note "$3  $got                                        OK"
	else
		note "$3  $got, expected $2                           FAIL"
		fail=1
	fi
}

check ALLOW     open   "the one allowed host:port       "
check SAMEHOST  closed "another port on the SAME host   "
check OTHERHOST closed "a host with no rule             "
check INTERNET  closed "the open internet               "

say "Result"
if [ "$fail" -eq 0 ]; then
	echo "   PASS — the rule grammar is per-port, not per-host. Allowing one"
	echo "   service on a machine does not expose the rest of it."
else
	echo "   FAIL — read the table above."
	echo ""
	echo "   If ALLOW came back closed, the rule or the address is wrong."
	echo "   If any DENY came back open, the policy is wider than it reads and"
	echo "   nothing built on it should be trusted until that is understood."
fi
exit "$fail"
