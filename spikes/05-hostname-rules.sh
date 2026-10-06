#!/usr/bin/env bash
#
# 05-hostname-rules.sh — are hostname allow rules actually reliable?
#
# Checks that hostname allow rules actually hold, since the internet half of
# every config here is granted by hostname and those hosts are CDN-backed with
# rotating addresses.
#
# WHAT IT TESTS, in one guest, so conditions are identical:
#   - a hostname with ONE address          (control)
#   - hostnames with MANY addresses        (the suspected failure)
#   - each fetched repeatedly, because intermittent is the whole hypothesis
#   - over both :443 and :80, since strict-mode authority inspection differs
#     between the two (TLS SNI vs the plain-HTTP Host header)
#
# PASS: every allowed host succeeds on every attempt.
# FAIL: any allowed host fails even once. Then the allowlist cannot be written
#       in hostnames alone, and the options are `--net-strict=false`, CIDR
#       rules for the big CDNs, or accepting a proxy. Decide with evidence.

set -euo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
ROUNDS="${ROUNDS:-5}"

# MODE=intercept  turn TLS interception on so HTTPS hostname rules are
#                 inspectable. This is what the real config will do.
# MODE=nostrict   drop the strictness requirement instead. Cheaper, but
#                 hostname rules stop being enforceable for HTTPS.
# MODE=plain      neither — reproduces the original failing run.
MODE="${MODE:-intercept}"
case "$MODE" in
	intercept) MSB_MODE_FLAGS="--tls-intercept" ;;
	nostrict)  MSB_MODE_FLAGS="--net-strict=false" ;;
	plain)     MSB_MODE_FLAGS="" ;;
	*) echo "MODE must be intercept, nostrict or plain" >&2; exit 2 ;;
esac

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — run on the host" >&2; exit 1; }
command -v msb >/dev/null || { echo "msb not on PATH" >&2; exit 1; }

say "Address counts as the host sees them"
for h in security.ubuntu.com archive.ubuntu.com github.com registry.npmjs.org \
         pypi.org api.anthropic.com; do
	n="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | wc -l)"
	printf '   %-26s %s address(es)\n' "$h" "$n"
done
echo "   (a failure correlating with this count is the hypothesis)"

PROBE="$(mktemp -d)/probe.sh"
cat >"$PROBE" <<SH
#!/usr/bin/env bash
# Each host is fetched $ROUNDS times. curl is in the base image; no apt, so
# this works under deny-by-default without needing its own exemption.
rounds=$ROUNDS
fail=0

check() { # <scheme> <host> <path>
	local scheme="\$1" host="\$2" path="\$3" ok=0 i rc last=0
	for i in \$(seq 1 \$rounds); do
		curl -sS -o /dev/null --max-time 10 "\$scheme://\$host\$path" 2>/dev/null
		rc=\$?
		if [ "\$rc" -eq 0 ]; then ok=\$((ok + 1)); else last=\$rc; fi
	done
	if [ "\$ok" -eq "\$rounds" ]; then
		printf '   %-34s %d/%d  OK\n' "\$scheme://\$host" "\$ok" "\$rounds"
		return
	fi
	# The exit code is the whole diagnosis, so print it rather than a verdict.
	# 60/77/35 mean the connection was ALLOWED and TLS was rejected — the
	# guest does not trust the interceptor's CA, which is a trust-store
	# problem, not a firewall one. 7/28 mean it never got through at all.
	local why
	case "\$last" in
		60|77|35) why="TLS/cert rejected — route OK, CA not trusted" ;;
		7)        why="connection refused — blocked" ;;
		28)       why="timed out — blocked (silent drop)" ;;
		6)        why="DNS failed — check allow@dns" ;;
		*)        why="curl exit \$last" ;;
	esac
	printf '   %-34s %d/%d  FAIL: %s\n' "\$scheme://\$host" "\$ok" "\$rounds" "\$why"
	fail=1
}

echo "guest: \$rounds attempts per host"
check https github.com            /
check https registry.npmjs.org    /
check https pypi.org              /simple/
check https api.anthropic.com     /
check http  archive.ubuntu.com    /ubuntu/dists/
check http  security.ubuntu.com   /ubuntu/dists/

echo
if [ "\$fail" -eq 0 ]; then
	echo "RESULT: PASS — hostname rules held for every host, every attempt"
else
	echo "RESULT: FAIL — hostname rules are not dependable; see above"
fi
exit "\$fail"
SH
chmod +x "$PROBE"

say "Running (mode: $MODE)"
# api.anthropic.com is included because it is the one host the dev sandbox
# genuinely cannot work without, so its reliability is not academic.
#
# `--net-strict` defaults to true: a hostname allow needs an inspectable
# request authority. Plain HTTP puts it in the Host header; HTTPS only exposes
# it when TLS interception is on, so an HTTPS hostname rule without
# interception is silently a deny rule. `intercept` is the default mode here
# because that is the shipping configuration — secret substitution needs it
# too. Use MODE=plain to see the failure it prevents.
msb run \
	$MSB_MODE_FLAGS \
	--net-default-egress deny \
	--net-rule "allow@dns" \
	--net-rule "allow@github.com:tcp:443" \
	--net-rule "allow@registry.npmjs.org:tcp:443" \
	--net-rule "allow@pypi.org:tcp:443" \
	--net-rule "allow@api.anthropic.com:tcp:443" \
	--net-rule "allow@archive.ubuntu.com:tcp:80" \
	--net-rule "allow@security.ubuntu.com:tcp:80" \
	-v "$(dirname "$PROBE"):/probe:ro" \
	--memory 2G \
	"$IMAGE" -- /probe/probe.sh

say "Reading the result"
cat <<'EOF'
   Compare modes rather than reading one run in isolation:

     MODE=plain     ./05-hostname-rules.sh     expect :443 to fail
     MODE=intercept ./05-hostname-rules.sh     the shipping configuration
     MODE=nostrict  ./05-hostname-rules.sh     the cheap alternative

   If intercept shows "TLS/cert rejected — route OK, CA not trusted", that is
   PROGRESS, not a regression: the firewall is now letting the connection
   through and the guest simply does not trust the interception CA. Fix the
   trust store, not the rules. --trust-host-cas, or patch the CA into the
   rootfs at bootstrap; --tls-intercept-ca-cert lets you supply your own.

   If nostrict passes and intercept does not, the honest trade is on the
   table: nostrict means hostname rules are NOT enforceable for HTTPS, so the
   internet half of the allowlist becomes decorative. The LAN half still
   works — it is written in IPs and enforced per-port — and the LAN
   half is the part that is genuinely enforced.
   Shipping with "LAN locked down, internet open" is defensible; shipping
   with a hostname list that reads as enforcement and is not, is not.
EOF
