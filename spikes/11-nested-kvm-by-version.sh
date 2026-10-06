#!/usr/bin/env bash
#
# 11-nested-kvm-by-version.sh — does a guest see vmx / /dev/kvm, per msb version?
#
# Run on the HOST. Observed: a sandbox on the 0.7.6 runtime had /dev/kvm and 8
# vmx flags; after the host moved to 0.7.7 (which bumped libkrunfw to Linux
# 6.12.111) a fresh sandbox and a pre-0.7.7 one both had neither. Note that
# an OLD sandbox started by a NEW msb runs the NEW VMM and kernel, so
# re-starting old sandboxes proves nothing; only running the old *binary* does.
#
# This downloads each requested release's microsandbox-linux-x86_64 tarball
# (sha256-verified against the release's checksums.sha256) into its own
# directory, points MSB_HOME at a throwaway directory per version, runs one
# throwaway sandbox (removed afterwards), and prints what the guest sees. Nothing is installed and the
# real MSB_HOME is never touched.
#
# Usage:  spikes/11-nested-kvm-by-version.sh [VERSION ...]     (default: 0.7.6 0.7.7)
#         KRUNFW_FROM=0.7.6 spikes/11-nested-kvm-by-version.sh 0.7.7   (0.7.7 msb + 0.7.6 kernel bundle)
#         IMAGE=alpine CPUS=2 WORK=/tmp/msb-spike11 spikes/11-nested-kvm-by-version.sh
#
# PASS/FAIL per version: PASS = the guest has /dev/kvm. The interesting output
# is the difference between versions, so the summary line says whether they
# disagree.
#
# Requires docker.io (or whatever IMAGE lives on) to be reachable from the host.

set -uo pipefail

IMAGE="${IMAGE:-alpine}"
CPUS="${CPUS:-2}"
WORK="${WORK:-${TMPDIR:-/tmp}/msb-spike11}"
REPO="${REPO:-superradcompany/microsandbox}"
VERSIONS=("$@")
[ ${#VERSIONS[@]} -gt 0 ] || VERSIONS=(0.7.6 0.7.7)

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

echo "host: nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | tr '\n' ' ')" \
	"virt flag: $(grep -m1 -o -w -E 'vmx|svm' /proc/cpuinfo || echo none)" \
	"kernel: $(uname -r)"
[ -e /dev/kvm ] || { echo "FAIL: no /dev/kvm on this host"; exit 1; }

# fetch VERSION: unpack msb + libkrunfw of that release into $WORK/VERSION/root.
fetch() {
	local v="$1" dir="$WORK/$1" base tar so
	base="https://github.com/$REPO/releases/download/v$v"
	tar="microsandbox-linux-x86_64.tar.gz"
	mkdir -p "$dir/dl" "$dir/root/bin" "$dir/root/lib"
	# Re-extract unless both the binary and a REAL (non-symlink) libkrunfw are there.
	if [ ! -x "$dir/root/bin/msb" ] || [ -z "$(find "$dir/root/lib" -maxdepth 1 -type f -name 'libkrunfw.so.*' 2>/dev/null)" ]; then
		rm -rf "$dir/root"; mkdir -p "$dir/root/bin" "$dir/root/lib"
		( cd "$dir/dl" &&
			curl -fsSL -O "$base/$tar" -O "$base/checksums.sha256" &&
			grep " $tar\$" checksums.sha256 | sha256sum -c - &&
			tar -xzf "$tar" -C "$dir/root/bin" msb &&
			tar -xzf "$tar" -C "$dir/root/lib" --wildcards 'libkrunfw*' ) || return 1
		# The runtime looks for libkrunfw beside the binary or in ../lib.
		# The tarball ships only the fully versioned file (libkrunfw.so.5.6.1); add
		# the soname and plain links to it. Never link a name to itself: that
		# replaces the real file with a dangling symlink.
		so=$(cd "$dir/root/lib" && ls libkrunfw.so.*.*.* | head -1)
		ln -sf "$so" "$dir/root/lib/libkrunfw.so.5"
		ln -sf "libkrunfw.so.5" "$dir/root/lib/libkrunfw.so"
	fi
}

declare -A RESULT
for v in "${VERSIONS[@]}"; do
	say "msb $v"
	dir="$WORK/$v"
	home="$WORK/home-$v${KRUNFW_FROM:+-krunfw-$KRUNFW_FROM}"
	mkdir -p "$home"

	fetch "$v" || { note "FAIL: could not fetch/verify/unpack v$v"; RESULT[$v]=error; continue; }
	if [ -n "${KRUNFW_FROM:-}" ]; then
		fetch "$KRUNFW_FROM" || { note "FAIL: could not fetch v$KRUNFW_FROM"; RESULT[$v]=error; continue; }
		export MSB_LIBKRUNFW_PATH="$WORK/$KRUNFW_FROM/root/lib/libkrunfw.so.5"
		note "MIXED: msb $v runtime with libkrunfw from $KRUNFW_FROM"
	else
		unset MSB_LIBKRUNFW_PATH
	fi

	msb="$dir/root/bin/msb"
	note "binary: $("$msb" --version 2>&1 | head -1)  home: $home"

	name="spike11-${v//./-}"
	out=$(MSB_HOME="$home" "$msb" run --name "$name" --replace --cpus "$CPUS" "$IMAGE" -- sh -c '
		echo "kernel: $(uname -r)"
		echo "vcpus: $(nproc)"
		echo "vmx/svm flags: $(grep -c -w -E "vmx|svm" /proc/cpuinfo)"
		ls -l /dev/kvm 2>&1 | sed "s/^/kvm: /"' 2>&1)
	rc=$?
	printf '%s\n' "$out" | sed 's/^/   /'
	MSB_HOME="$home" "$msb" rm -f "$name" >/dev/null 2>&1 || true

	if [ $rc -ne 0 ]; then
		note "FAIL: msb run exited $rc"; RESULT[$v]=error
	elif printf '%s' "$out" | grep -q '^kvm: crw'; then
		note "PASS: guest has /dev/kvm"; RESULT[$v]=kvm
	else
		note "FAIL: guest has no /dev/kvm"; RESULT[$v]=nokvm
	fi
done

say "summary"
for v in "${VERSIONS[@]}"; do note "$v: ${RESULT[$v]:-?}"; done
if [ ${#VERSIONS[@]} -lt 2 ]; then
	note "single run: nothing to compare (KRUNFW_FROM only swaps the kernel bundle;"
	note "a guest kernel matching KRUNFW_FROM with no kvm means the VMM, not libkrunfw, hides vmx)"
elif [ "${RESULT[${VERSIONS[0]}]:-}" != "${RESULT[${VERSIONS[-1]}]:-}" ]; then
	note "versions DISAGREE: the msb runtime changes what the guest sees"
else
	note "versions agree: not the msb version, look at the host / sandbox config"
fi
note "cleanup: rm -rf $WORK"
