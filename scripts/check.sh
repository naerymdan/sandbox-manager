#!/usr/bin/env bash
#
# scripts/check.sh — the repo's static checks. CI runs exactly this, so a green
# run here is a green run there.
#
#   scripts/check.sh
#
# Needs no msb, no KVM and no network: Python 3.11+, bash, git, and (if
# installed; CI has them) shellcheck, ruff and gitleaks. Each check records its
# outcome and the failures are summarized together, same as bootstrap.sh, so
# one run shows everything that is wrong rather than the first thing.

set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  skip  %s\n' "$*"; }

# -I: do not let a stray .py in the cwd shadow the stdlib.
echo "python"
if python3 -I -c 'import ast,sys; ast.parse(open("msbctl").read(), "msbctl")' 2>/tmp/check.$$; then
	ok "msbctl parses"
else
	bad "msbctl: $(tail -n1 /tmp/check.$$)"
fi
rm -f /tmp/check.$$

echo "shell syntax"
for f in $(git ls-files '*.sh' msb-picker); do
	if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f: bash -n failed"; fi
done

echo "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	# shellcheck disable=SC2046  # the file list has no spaces
	if shellcheck -S warning $(git ls-files '*.sh' msb-picker); then
		ok "no warnings"
	else
		bad "shellcheck reported warnings"
	fi
else
	skip "shellcheck not installed"
fi

echo "ruff"
# ruff.toml says which rules and why. Python files without a .py (msbctl, the
# screenshot wrappers) are found by their shebang and passed by name.
if command -v ruff >/dev/null 2>&1; then
	mapfile -t py < <({ git ls-files '*.py'; git grep -lI '^#!.*python' -- ':!*.py'; } | sort -u)
	if ruff check --no-cache --quiet "${py[@]}"; then
		ok "no findings in ${#py[@]} files"
	else
		bad "ruff reported findings"
	fi
else
	skip "ruff not installed"
fi

echo "toml"
for f in defaults.toml .msb/sandbox.toml; do
	if python3 -I -c 'import sys,tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$f" 2>/dev/null; then
		ok "$f"
	else
		bad "$f does not parse"
	fi
done

echo "docs"
# Builds the site into a throwaway directory and fails on a broken internal link,
# a missing anchor, or an msbctl subcommand with no section on the Commands page.
docs_out=$(mktemp -d)
if python3 -I docs/build.py --check --out "$docs_out" >/tmp/check.$$ 2>&1; then
	ok "$(tail -n1 /tmp/check.$$)"
else
	bad "docs/build.py --check:"
	sed 's/^/        /' /tmp/check.$$
fi
rm -rf "$docs_out" /tmp/check.$$

echo "payload"
# install.sh and scripts/package.sh each carry the list of what ships; if they
# disagree, a package installs something different from a checkout.
a=$(grep '^PAYLOAD=' install.sh)
b=$(grep '^PAYLOAD=' scripts/package.sh)
if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "install.sh and package.sh agree"; else bad "PAYLOAD differs between install.sh and scripts/package.sh"; fi

echo "modes"
# A script git records as 644 shows as modified the moment anyone makes it
# executable, and the other way round. The rule: a file with a shebang is 755,
# anything else 644. bootstrap.sh is the exception — msbctl pipes it into the
# guest over stdin, so it is never executed from disk and stays 644.
mode_fails=0
while read -r mode _ _ path; do
	want=100644
	if [ "$(head -c2 "$path")" = '#!' ] && [ "$path" != bootstrap.sh ]; then want=100755; fi
	if [ "$mode" != "$want" ]; then bad "$path is $mode in git, want $want"; mode_fails=1; fi
done < <(git ls-files -s)
[ "$mode_fails" -eq 0 ] && ok "tracked modes follow the rule"

echo "secrets"
if command -v gitleaks >/dev/null 2>&1; then
	if gitleaks detect --no-banner --redact >/dev/null 2>&1; then ok "gitleaks clean"; else bad "gitleaks flagged something"; fi
else
	skip "gitleaks not installed"
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
