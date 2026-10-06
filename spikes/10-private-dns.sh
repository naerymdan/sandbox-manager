#!/usr/bin/env bash
#
# 10-private-dns.sh — names that resolve to LAN addresses.
#
# Some networks publish PRIVATE addresses in DNS: a split-horizon resolver, or
# a public record deliberately aimed inside your own LAN. msb discards DNS
# answers that resolve into RFC1918 space — ordinary DNS-rebind protection, and
# correct by default — so such a name is unusable unless the sandbox is
# launched with
#
#   --no-dns-rebind-protection
#
# THE FAILURE IS BADLY DISGUISED, which is why this exists as a spike rather
# than a line in a README. Without the flag you get NXDOMAIN inside the guest,
# and msb also refuses the TCP connection, because it never learns which
# address belongs to the allowed name. Both symptoms read as "the egress rule
# is missing" when the rule is present and correct. `curl --resolve` does not
# work around it either: the connect is refused before any TLS handshake exists
# for the SNI to be read from.
#
# PASS: with the flag, a private-resolving name resolves AND connects; the
#       negative control still refuses an address with no rule naming it.
#
# Deliberately asserts BOTH halves. A run that only proved the name works would
# not notice if the flag had quietly opened the LAN.

set -uo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
# A name that resolves to a private address. Required — there is no sensible
# default, and a wrong one would make this spike pass for the wrong reason.
NAME="${NAME:?set NAME to a hostname that resolves to a private address}"
# Must have NO rule naming it, and must not be what NAME resolves to. This is
# the negative control: the flag must not make it reachable.
CONTROL_ADDR="${CONTROL_ADDR:?set CONTROL_ADDR to a private address with NO rule}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail=0

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }

resolved="$(getent hosts "$NAME" | awk '{print $1; exit}')"
if [ -z "$resolved" ]; then
	echo "$NAME does not resolve on this host — nothing to test" >&2
	exit 1
fi
note "$NAME resolves to $resolved on the host"
case "$resolved" in
	10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
	*) echo "$resolved is not RFC1918 — this spike tests the private case" >&2
	   exit 1 ;;
esac

# The rule names NAME literally.
#
# An earlier draft derived a wildcard from it with ${NAME#*.}, which is wrong
# in a way worth recording: for an apex name like `example.com` that yields
# `com`, and the emitted rule `allow@*.com:tcp:443` covers most of the
# internet. A spike that silently widens the policy it is testing proves
# nothing. Set RULE_TARGET to test a wildcard form deliberately.
RULE_TARGET="${RULE_TARGET:-$NAME}"
rules=(
	--net-default-egress deny
	--net-rule "allow@dns"
	--net-rule "allow@${RULE_TARGET}:tcp:443"
	--tls-intercept
)

probe='
	printf "RESOLVE=%s\n" "$(getent hosts '"$NAME"' | awk "{print \$1; exit}")"
	curl -sS -o /dev/null --max-time 12 "https://'"$NAME"'/" 2>/dev/null \
		&& echo "CONNECT=ok" || echo "CONNECT=deny"
	timeout 6 bash -c "echo > /dev/tcp/'"$CONTROL_ADDR"'/443" 2>/dev/null \
		&& echo "CONTROL=ok" || echo "CONTROL=deny"
'

run_case() {   # run_case <label> [extra flags...]
	local label="$1"; shift
	say "$label"
	msb run --memory 2G "${rules[@]}" "$@" "$IMAGE" -- bash -c "$probe" 2>&1 \
		| tr -d '\r' | tee "/tmp/spike10-$label.$$"
}

run_case without >/dev/null
run_case with --no-dns-rebind-protection >/dev/null

get() { sed -n "s/^$2=//p" "/tmp/spike10-$1.$$" | head -1; }

say "Verdict"
printf '   %-8s %-10s %-10s %s\n' case resolve connect control
for c in without with; do
	printf '   %-8s %-16s %-10s %s\n' "$c" \
		"$(get "$c" RESOLVE)" "$(get "$c" CONNECT)" "$(get "$c" CONTROL)"
done

# 1. The flag has to be what makes the difference. If the name already worked
#    without it, this host is not reproducing the condition and the result
#    below says nothing.
if [ -n "$(get without RESOLVE)" ]; then
	note ""
	note "$NAME resolved WITHOUT the flag — rebind protection is not"
	note "engaging here, so this run proves nothing about it.         INCONCLUSIVE"
	fail=1
elif [ -z "$(get with RESOLVE)" ]; then
	note ""
	note "$NAME did not resolve even WITH the flag                    FAIL"
	fail=1
else
	note ""
	note "the flag is what makes the name resolvable                  OK"
fi

if [ "$(get with CONNECT)" = ok ]; then
	note "and the connection to it is permitted                       OK"
else
	note "the name resolves but the connection is refused             FAIL"
	note "  the egress rule and the DNS answer disagree — check that the"
	note "  resolved address is the one the rule was expected to cover."
	fail=1
fi

# 2. The negative control. The flag widens what a NAME may resolve to; it must
#    not open an address that no rule mentions.
if [ "$(get with CONTROL)" = deny ]; then
	note "$CONTROL_ADDR:443 still refused with the flag on            OK"
else
	note "$CONTROL_ADDR:443 became REACHABLE with the flag on         FAIL"
	note "  --no-dns-rebind-protection is doing more than documented. Stop"
	note "  and re-read what it changes before shipping it."
	fail=1
fi

rm -f "/tmp/spike10-without.$$" "/tmp/spike10-with.$$"

say "Result"
if [ "$fail" -eq 0 ]; then
	echo "   PASS — allow_private_dns is necessary, sufficient, and does not"
	echo "   widen reachability beyond the names it lets resolve."
else
	echo "   FAIL — read the table above; the two cases should differ in"
	echo "   exactly one column."
fi
exit "$fail"
