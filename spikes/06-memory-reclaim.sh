#!/usr/bin/env bash
#
# microsandbox-memory-test.sh — does a microsandbox VM give RAM back?
#
# Guest RAM is allocated lazily, so an idle 8 GiB VM does not cost 8 GiB.
# What matters on a 32 GiB workstation is whether the host gets memory *back*
# after a spike: if a build faults in 4 GiB and frees it, does the VMM's RSS
# fall, or park at the high-water mark for the life of the machine?
#
# Current answer on 0.7.6: anonymous memory is returned (~99%, 90% of it
# within 12s); page cache is never returned on its own and needs an explicit
# drop_caches. Re-run after an msb upgrade to confirm that still holds.
#
# WHY IT MEASURES HOST RSS AND NOT `msb metrics`.  The metrics docs do not say
# whether `memory_bytes` is host-observed or guest-visible, and the guest's own
# view is exactly the thing that will look fine either way: the guest kernel
# frees the pages regardless, the question is only what the host sees.  So the
# authoritative number here is VmRSS of the host-side VMM process, with
# MemAvailable as an independent cross-check in case the guest RAM is backed by
# a mapping whose accounting RSS misses.
#
# TWO SPIKES, because they reclaim differently:
#   A  anonymous memory  — malloc, touch every page, free.  This is what
#      free-page-reporting is for and the case most likely to work.
#   B  page cache        — write files, then drop_caches.  A real build is
#      mostly this, and a guest holding clean page cache has not "freed"
#      anything from the host's point of view, so B usually needs the explicit
#      drop to move at all.  If B only recovers after drop_caches, that is a
#      finding, not a failure.
#
# Usage:  ./microsandbox-memory-test.sh [spike_gib]     (default 4)
#         VMM_PID=1234 ./microsandbox-memory-test.sh    (skip autodetect)

set -euo pipefail

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# ------------------------------------------------------------------ report
#
# Called from the EXIT trap so a run that dies partway still reports whatever
# it collected.

report() {
	local csv="$1" spike="${2:-?}"
	[ -s "$csv" ] || { note "no samples in $csv"; return 0; }
	[ "$(wc -l <"$csv")" -gt 2 ] || { note "too few samples to summarise"; return 0; }

	say "Per-phase VMM RSS (MB)"
	awk -F, 'NR>1 {
		if (!(($2) in lo) || $3 < lo[$2]) lo[$2] = $3
		if (!(($2) in hi) || $3 > hi[$2]) hi[$2] = $3
		last[$2] = $3
		if (!seen[$2]++) order[++n] = $2
	}
	END {
		printf "   %-22s %8s %8s %8s\n", "phase", "min", "max", "end"
		for (i = 1; i <= n; i++) { p = order[i]
			printf "   %-22s %8d %8d %8d\n", p, lo[p], hi[p], last[p]
		}
	}' "$csv"

	say "Verdict — anonymous memory (phase A)"
	awk -F, -v spike="$spike" 'NR>1 {
		if ($2 == "idle-baseline")       base = $3
		if ($2 == "A-alloc" && $3 > pk)  pk = $3
		if ($2 == "A-idle-after-free") {
			endA = $3
			if (!t0) t0 = $1
			# Reclaim is gradual, not a step. How long it takes decides whether
			# two sandboxes can spike near each other, so measure it rather
			# than just the endpoints.
			if (!t50 && $3 <= base + (pk - base) * 0.5) t50 = $1 - t0
			if (!t90 && $3 <= base + (pk - base) * 0.1) t90 = $1 - t0
		}
	}
	END {
		if (!pk) { print "   phase A never ran"; exit }
		rise = pk - base
		kept = endA - base
		printf "   baseline %d MB  ->  peak %d MB  (+%d MB for a %s GiB spike)\n", base, pk, rise, spike
		printf "   after idle:      %d MB  (%d MB still held)\n", endA, kept
		if (t90)      printf "   decay:           50%% back at +%ds, 90%% back at +%ds into idle\n", t50, t90
		else if (t50) printf "   decay:           50%% back at +%ds, never reached 90%%\n", t50
		else          print  "   decay:           never got halfway back within the idle window"
		if (rise < 200) {
			print  "   INCONCLUSIVE: the spike never showed up in host RSS."
			print  "   Guest RAM may be backed by a mapping this PID does not account for."
			print  "   Check the host_memavail_mb column instead, and confirm the PID."
		} else if (kept < rise * 0.25) {
			print  "   RECLAIMS: the host got most of the spike back on its own."
		} else if (kept > rise * 0.75) {
			print  "   DOES NOT RECLAIM: RSS parks at the high-water mark."
			print  "   Budget peak-not-average per sandbox, or restart them between jobs."
		} else {
			print  "   PARTIAL: some came back.  Read the CSV before concluding."
		}
	}' "$csv"

	# B and C differ only in where the bytes were written, so one program, twice.
	# Single quotes are required here: this is an awk program, and $2/$3 are
	# awk field references that the shell must not touch.
	# shellcheck disable=SC2016
	local awk_cache='NR>1 {
		if ($2 == b)                           pre = $3
		if (($2 == w || $2 == w2) && $3 > pk)  pk = $3
		if ($2 == h)             held = $3
		if ($2 == d)             dropped = $3
	}
	END {
		if (!pk && !held) { print "   did not run"; exit }
		printf "   before %d MB  ->  write peak %d MB  ->  held %d MB", pre, pk, held
		if (dropped) printf "  ->  after drop_caches %d MB", dropped
		printf "\n"
		# A write phase too fast to sample is normal; a write phase that never
		# ran looks identical from here and must not read as a result.  Only
		# claim "nothing parked" when the held window also shows no rise.
		if (!pk && held <= pre + 200) {
			print "   INCONCLUSIVE: the write phase produced no samples and nothing"
			print "   parked.  Confirm the guest actually wrote files before believing it."
			exit
		}
		if (held <= pre + 200) {
			print "   Nothing parked — these writes never cost host memory."
			exit
		}
		if (!dropped) { print "   drop_caches did not run; no conclusion on cache reclaim"; exit }
		if (dropped < held - (held - pre) * 0.5)
			print "   Cache IS returned once the guest drops it — but not before."
		else
			print "   Cache is NOT returned even after drop_caches."
	}'

	say "Verdict — page cache, guest writable layer (phase B)"
	# B-pagecache is the pre-2026-10-04 name for B-write; accept both so older
	# CSVs still report.
	awk -F, -v b="A-idle-after-free" -v w="B-write" -v w2="B-pagecache" \
		-v h="B-idle-held" -v d="B-idle-after-drop" "$awk_cache" "$csv"

	say "Verdict — page cache, host bind mount over virtiofs (phase C)"
	note "this is the one that matches how we would actually run it: workspaces on the host"
	awk -F, -v b="B-idle-after-drop" -v w="C-write" -v w2="C-bindmount" \
		-v h="C-idle-held" -v d="C-idle-after-drop" "$awk_cache" "$csv"

	say "Raw data"
	note "$csv"
	note "plot:  gnuplot -p -e \"set datafile separator ','; plot '$csv' using 1:3 with lines title 'VMM RSS MB'\""
}

# --report <csv> [spike_gib] re-prints the summary for a previous run.
if [ "${1:-}" = "--report" ]; then
	report "${2:?usage: $0 --report <samples.csv> [spike_gib]}" "${3:-?}"
	exit 0
fi

SPIKE_GIB="${1:-4}"
IMAGE="${IMAGE:-python}"
NAME="${NAME:-msb-memtest-$$}"
MEM_CEILING="${MEM_CEILING:-8G}"
SAMPLE_EVERY=1   # /dev/zero fills faster than a 2s interval can sample

OUT="$(mktemp -d /tmp/msb-memtest.XXXXXX)"
CSV="$OUT/samples.csv"
PHASE_FILE="$OUT/phase"
GUEST="$OUT/guest"
mkdir -p "$GUEST"

# Phase C writes through a host bind mount, so its backing store must be real
# disk.  Not under $OUT: /tmp is tmpfs on Fedora, and writing 3 GiB of "files"
# straight into host RAM would measure nothing but itself.
WORKDIR="${WORKDIR:-$HOME/.cache/msb-memtest-work}"
mkdir -p "$WORKDIR"

cleanup() {
	local rc=$?
	[ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null || true
	if [ -n "${NAME:-}" ] && msb ls 2>/dev/null | grep -q "$NAME"; then
		note "removing sandbox $NAME"
		msb stop "$NAME" >/dev/null 2>&1 || true
		msb rm   "$NAME" >/dev/null 2>&1 || true
	fi
	# Report whatever was collected, including after an abort — a run that got
	# through phase A has already answered the main question.
	# Phase C leaves gigabytes of zeroes on real disk.
	[ -d "${WORKDIR:-}/cachefill" ] && rm -rf "${WORKDIR:?}/cachefill"
	if [ -z "${REPORTED:-}" ] && [ -s "${CSV:-/nonexistent}" ]; then
		REPORTED=1
		[ "$rc" -ne 0 ] && note "(run ended early, rc=$rc — reporting partial data)"
		report "$CSV" "$SPIKE_GIB"
		keep="$HOME/msb-memtest-$(date +%Y%m%d-%H%M%S).csv"
		cp "$CSV" "$keep" 2>/dev/null && note "kept: $keep"
	fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight

say "Preflight"
[ -e /dev/kvm ] || { echo "no /dev/kvm — enable VT-x in BIOS, or you are not on the host" >&2; exit 1; }
command -v msb >/dev/null || {
	echo "msb not on PATH.  Install with:" >&2
	echo "  curl -sSL https://get.microsandbox.dev | sh    # or: brew/npm/cargo/uv" >&2
	exit 1
}
note "msb:        $(msb --version 2>&1 | head -1)"
note "kvm:        $(stat -c '%A %U:%G' /dev/kvm)"
note "host RAM:   $(awk '/MemTotal/{printf "%.1f GiB total", $2/1048576}' /proc/meminfo), \
$(awk '/MemAvailable/{printf "%.1f GiB available", $2/1048576}' /proc/meminfo)"
note "spike:      ${SPIKE_GIB} GiB, ceiling ${MEM_CEILING}"
note "results:    $OUT"

WORKDIR_FS="$(stat -f -c %T "$WORKDIR")"
note "bind mount: $WORKDIR ($WORKDIR_FS)"
case "$WORKDIR_FS" in
	tmpfs|ramfs)
		echo "refusing: $WORKDIR is $WORKDIR_FS — phase C would write into host RAM" >&2
		echo "set WORKDIR=<path on real disk> and re-run" >&2
		exit 1 ;;
esac

# ------------------------------------------------------------- guest payload

# Written to a bind-mounted dir rather than passed as `python -c '...'`, which
# would need three levels of quoting through `msb exec -- sh -c`.
cat >"$GUEST/hog.py" <<'PY'
import sys, time

gib = int(sys.argv[1])
n = gib * 1024 * 1024 * 1024

# One big bytearray is a single mmap, so freeing it returns the region to the
# kernel rather than parking it in a CPython freelist.  Touch one byte per 4k
# page: allocation alone faults in nothing.
buf = bytearray(n)
for i in range(0, n, 4096):
    buf[i] = 1
print("guest: touched %d GiB" % gib, flush=True)

time.sleep(15)
del buf
print("guest: freed", flush=True)
time.sleep(5)
PY

cat >"$GUEST/cache.sh" <<'SH'
#!/bin/sh
# Fill the guest page cache the way a build does: many files, written and left.
#
# Takes MiB, not GiB; the caller sizes it against real free space. /dev/zero
# rather than /dev/urandom: page cache does not care about entropy.
set -e
mib="$1"
dir="${2:-/tmp/cachefill}"

# Refuse a non-integer or trivial size rather than quietly writing nothing and
# letting the caller conclude "no memory was parked".
case "$mib" in
	''|*[!0-9]*) echo "cache.sh: bad size '$mib'" >&2; exit 2 ;;
esac
[ "$mib" -ge 512 ] || { echo "cache.sh: size ${mib} MiB too small to measure" >&2; exit 2; }

mkdir -p "$dir"
i=0
while [ "$((i * 128))" -lt "$mib" ]; do
	dd if=/dev/zero of="$dir/f$i" bs=1M count=128 status=none
	i=$((i + 1))
done
sync
[ "$i" -gt 0 ] || { echo "cache.sh: wrote no files" >&2; exit 2; }
echo "guest: wrote $((i * 128)) MiB across $i files into $dir"
SH
chmod +x "$GUEST/cache.sh"

cat >"$GUEST/freespace.sh" <<'SH'
#!/bin/sh
# MiB available on a given guest path, for sizing the cache phases.
df -m "${1:-/tmp}" | awk 'NR==2 {print $4}'
SH
chmod +x "$GUEST/freespace.sh"

cat >"$GUEST/diag.sh" <<'SH'
#!/bin/sh
echo "--- balloon device"
if [ -d /sys/bus/virtio/drivers/virtio_balloon ]; then
	ls /sys/bus/virtio/drivers/virtio_balloon
else
	echo "NO virtio_balloon driver bound — reclaim is impossible, question answered"
fi
echo "--- free page reporting"
grep -r . /sys/kernel/mm/page_reporting/ 2>/dev/null || echo "no /sys/kernel/mm/page_reporting"
echo "--- dmesg"
dmesg 2>/dev/null | grep -i -e balloon -e "page report" || echo "(no balloon lines; dmesg may be restricted)"
echo "--- meminfo"
grep -E "MemTotal|MemFree|MemAvailable|Cached" /proc/meminfo
SH
chmod +x "$GUEST/diag.sh"

# ----------------------------------------------------------------- bring up

say "Starting sandbox"
# PID snapshot before/after so the VMM can be found without knowing whether msb
# runs a supervisor, a per-sandbox child, or both.
# A glob rather than `ls /proc | grep`: /proc entries are all well-behaved
# names, but the lint gate runs at warning level and SC2010 is a warning.
pids_now() { for d in /proc/[0-9]*; do printf '%s\n' "${d#/proc/}"; done | sort -n; }

before="$(pids_now)"

msb run -d --name "$NAME" -m "$MEM_CEILING" \
	-v "$GUEST:/t:ro" \
	-v "$WORKDIR:/w" \
	"$IMAGE" -- sleep infinity
sleep 5
msb ls || true

after="$(pids_now)"
new_pids="$(comm -13 <(echo "$before") <(echo "$after") || true)"

if [ -n "${VMM_PID:-}" ]; then
	note "using VMM_PID=$VMM_PID from the environment"
else
	say "Candidate host processes (new since start, by RSS)"
	VMM_PID=""
	best=0
	for p in $new_pids; do
		[ -r "/proc/$p/status" ] || continue
		rss="$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)"
		[ -n "$rss" ] || continue
		cmd="$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | cut -c1-80)"
		printf '   %7s  %8s kB  %s\n' "$p" "$rss" "$cmd"
		if [ "$rss" -gt "$best" ]; then best="$rss"; VMM_PID="$p"; fi
	done
	[ -n "$VMM_PID" ] || { echo "could not identify the VMM process; re-run with VMM_PID=<pid>" >&2; exit 1; }
	note "picked PID $VMM_PID — if that looks wrong, re-run with VMM_PID=<pid>"
fi

say "Guest memory-subsystem diagnostics"
msb exec "$NAME" --no-tty -- /t/diag.sh || note "(diag failed; continuing)"

# ----------------------------------------------------------------- sampling

echo "elapsed_s,phase,vmm_rss_mb,host_memavail_mb" >"$CSV"
echo "idle-baseline" >"$PHASE_FILE"

(
	start="$(date +%s)"
	while :; do
		now="$(date +%s)"
		rss="$(awk '/^VmRSS:/{print int($2/1024)}' "/proc/$VMM_PID/status" 2>/dev/null || echo "")"
		[ -n "$rss" ] || break   # VMM gone
		avail="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
		printf '%s,%s,%s,%s\n' "$((now - start))" "$(cat "$PHASE_FILE")" "$rss" "$avail" >>"$CSV"
		sleep "$SAMPLE_EVERY"
	done
) &
SAMPLER_PID=$!

phase() { echo "$1" >"$PHASE_FILE"; say "Phase: $1"; }

# Every exec below is non-fatal.  A phase that cannot run is worth less than a
# phase that ran, but both are worth more than an aborted script.
run_in_guest() { msb exec "$NAME" --no-tty -- "$@" || note "(phase step failed; continuing)"; }

phase "idle-baseline";      sleep 20

phase "A-alloc";            run_in_guest python /t/hog.py "$SPIKE_GIB"
phase "A-idle-after-free";  note "watching for 120s"; sleep 120

# fit_cache <guest-path> — MiB to write there, capped to free space less 512 of
# headroom.  Echoes 0 when there is not enough room to be worth measuring.
#
# Every human-readable line goes to stderr: only the integer may reach stdout,
# or the command substitution captures prose along with the number.
fit_cache() {
	local path="$1" free want
	free="$(msb exec "$NAME" --no-tty -- /t/freespace.sh "$path" 2>/dev/null | tr -dc '0-9' || echo 0)"
	want=$((SPIKE_GIB * 1024))
	[ "${free:-0}" -gt 0 ] || { echo 0; return; }
	if [ "$((free - 512))" -lt "$want" ]; then
		[ "$((free - 512))" -lt 512 ] && { echo 0; return; }
		note "$path has ${free} MiB free — capping at $((free - 512)) MiB" >&2
		echo "$((free - 512))"
	else
		echo "$want"
	fi
}

# cache_phase <letter> <guest-path> <fill-dir> — write, hold, drop, watch.
# The hold and drop phases only run if the write actually happened, so a failed
# write leaves no samples for the report to misread as "nothing parked".
cache_phase() {
	local tag="$1" path="$2" dir="$3" mib
	mib="$(fit_cache "$path")"
	if [ "${mib:-0}" -lt 512 ] 2>/dev/null; then
		note "$path too small or unreadable — skipping phase $tag"
		return 0
	fi
	phase "${tag}-write"
	if ! msb exec "$NAME" --no-tty -- /t/cache.sh "$mib" "$dir"; then
		note "phase $tag write failed — skipping its hold and drop phases"
		return 0
	fi
	phase "${tag}-idle-held";       note "watching for 60s (cache still held)"; sleep 60
	phase "${tag}-drop-caches";     run_in_guest sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo dropped'
	phase "${tag}-idle-after-drop"; note "watching for 120s"; sleep 120
	run_in_guest rm -rf "$dir"
}

# B: writes land on the guest's own writable layer.
cache_phase B /tmp /tmp/cachefill

# C: writes land on a host bind mount over virtiofs.  This is the case that
# matches the real design — the fork is checked out on the host and mounted in,
# so a build's output never touches the guest's own disk.  If these pages are
# accounted host-side rather than in guest page cache, phase B's parking
# behaviour simply does not apply to us.
cache_phase C /w /w/cachefill

kill "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""

# ------------------------------------------------------------------ report

note "measurement complete — summary and CSV path follow on exit"
# The EXIT trap prints the report, so a run that aborts mid-phase still
# reports what it collected.  Nothing more to do here.
