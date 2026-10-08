#!/usr/bin/env bash
#
# bootstrap.sh — runs ONCE, inside a guest, at `msbctl start` create time.
#
# One bootstrap for every registered sandbox. Everything a per-project
# launcher would hardcode arrives here as an environment variable, set by
# msbctl from the sandbox's resolved [versions] table and its project's
# [bootstrap] section:
#
#   MSB_NODE_MAJOR        node major line                      (default 22)
#   MSB_GITLEAKS_VERSION  pinned
#   MSB_GH_VERSION        pinned; checksum-verified below
#   MSB_BUN_VERSION       pinned; checksum-verified below
#   MSB_EXTRA_PACKAGES    space-separated apt packages for this project
#   MSB_WANT_CLAUDE       1 to install Claude Code (default 1)
#   MSB_WANT_BUN          1 to install bun
#   MSB_WANT_GITLEAKS     1 to install gitleaks
#   MSB_CONTAINERS_STORAGE  "fuse-overlayfs" to point podman at it
#   MSB_CACHE_LINKS       space-separated MOUNT:DEST pairs; DEST becomes a symlink to MOUNT
#   MSB_PROJECT_DIR       where the project is mounted (default /work)
#   MSB_PROJECT_SCRIPT    path under the project to run last, if any
#
# msbctl writes this file into the guest over stdin rather than mounting it.
# The guest can see the project and the read-only profile directory and nothing else,
# and keeping the manager's own code out of every sandbox is the point.
#
# Deliberately not `set -e`. Every step runs, records its own outcome, and the
# summary lists all failures at once — so one missing egress rule does not hide
# the next, and building an allowlist stays a bounded job rather than a series
# of round trips.
set -uo pipefail

NODE_MAJOR="${MSB_NODE_MAJOR:-22}"
GITLEAKS_VERSION="${MSB_GITLEAKS_VERSION:-8.30.1}"
GH_VERSION="${MSB_GH_VERSION:-2.102.0}"
BUN_VERSION="${MSB_BUN_VERSION:-1.4.2}"
EXTRA_PACKAGES="${MSB_EXTRA_PACKAGES:-}"
WANT_CLAUDE="${MSB_WANT_CLAUDE:-1}"
WANT_BUN="${MSB_WANT_BUN:-0}"
WANT_GITLEAKS="${MSB_WANT_GITLEAKS:-0}"
PROJECT_DIR="${MSB_PROJECT_DIR:-/work}"
PROJECT_SCRIPT="${MSB_PROJECT_SCRIPT:-}"
CONTAINERS_STORAGE="${MSB_CONTAINERS_STORAGE:-}"
CACHE_LINKS="${MSB_CACHE_LINKS:-}"

say() { printf '\n== %s\n' "$*"; }

FAILED_REQUIRED=()
FAILED_OPTIONAL=()

# step <required|optional> <name> -- <command...>
step() {
	local kind="$1" name="$2"; shift 3   # drop the literal --
	say "$name"
	if "$@"; then
		printf '   ok\n'
		return 0
	fi
	printf '   FAILED (%s)\n' "$kind"
	if [ "$kind" = required ]; then
		FAILED_REQUIRED+=("$name")
	else
		FAILED_OPTIONAL+=("$name")
	fi
	return 0
}

[ -d "$PROJECT_DIR" ] || { echo "bootstrap: $PROJECT_DIR is not mounted" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

do_apt() {
	# Move apt to HTTPS before the first fetch. Not cosmetic: it changes which
	# enforcement layer applies. Over :80 nothing inspects the traffic, so a
	# hostname rule is really a rule about the addresses that name resolved to,
	# and apt reaches pool members that were never pinned. Over :443 the
	# interceptor matches the SNI and the address stops mattering.
	#
	# Ubuntu 24.04+ uses the deb822 format at sources.list.d/ubuntu.sources;
	# older images use sources.list. Rewrite whichever exists.
	#
	# The character class includes digits and hyphens because regional and CDN
	# mirrors look like mirror2.ubuntu.com and security-cdn.ubuntu.com; a
	# letters-only pattern skips both and leaves a plaintext source that then
	# fails against the :80 deny.
	local changed=0 f
	for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
		[ -f "$f" ] || continue
		if grep -q 'http://[a-z0-9.-]*ubuntu\.com' "$f"; then
			sed -i 's|http://\([a-z0-9.-]*ubuntu\.com\)|https://\1|g' "$f"
			changed=1
		fi
	done
	[ "$changed" -eq 1 ] && echo "   rewrote apt sources to https"

	# Verify rather than assume. If any plaintext source survives, apt fails
	# against the :80 deny and the error points at the network rather than here.
	if grep -rqs 'http://[a-z0-9.-]*ubuntu\.com' /etc/apt/sources.list /etc/apt/sources.list.d/; then
		echo "   WARNING: a plaintext ubuntu.com source survived the rewrite:" >&2
		grep -rns 'http://[a-z0-9.-]*ubuntu\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ >&2
	fi

	apt-get update -qq || echo "   (apt update had warnings; continuing)"

	# socat is the ssh-agent bridge. yamllint/shellcheck let an agent
	# validate the YAML and shell it writes — from apt, not pip: PyPI is not in the
	# default egress allowlist, so apt is the only route available. nano is what
	# EDITOR names in defaults.toml, so it must exist whatever the image is.
	#
	# shellcheck disable=SC2086 # deliberate word splitting: a package list
	apt-get install -y -qq --no-install-recommends \
		socat jq curl ca-certificates ripgrep fd-find tree unzip file \
		yamllint shellcheck gnupg openssh-client nano $EXTRA_PACKAGES
	command -v socat >/dev/null   # no socat, no agent bridge
	# Debian/Ubuntu name the binary fdfind to avoid a clash; everyone else's
	# docs and muscle memory say fd.
	if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
		ln -s "$(command -v fdfind)" /usr/local/bin/fd
	fi
}

# The key NodeSource signs its apt repository with. Pinned, so that what the
# download is checked against is not the download itself: the key file is
# imported, ONLY this fingerprint is exported into the keyring apt trusts, and
# the step fails if it is absent. Everything after that is apt verifying
# signatures, which is why the major line is the only pin node needs. A key
# rotation fails loudly here; update the fingerprint from nodesource.com.
NODESOURCE_KEY_FPR="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"

do_node() {
	command -v node >/dev/null && { node --version; return 0; }
	# Not NodeSource's setup_N.x script: that is an unverified `curl | bash`
	# which does exactly the following, minus the fingerprint check (same file
	# names too, so a guest set up either way ends up the same).
	local keyring=/usr/share/keyrings/nodesource.gpg tmp rc
	tmp="$(mktemp -d)"
	chmod 700 "$tmp"
	curl -fsSL -o "$tmp/key.asc" https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
		&& GNUPGHOME="$tmp" gpg --batch -q --import "$tmp/key.asc" \
		&& GNUPGHOME="$tmp" gpg --batch --export "$NODESOURCE_KEY_FPR" >"$tmp/key.gpg" \
		&& [ -s "$tmp/key.gpg" ] \
		&& install -m 644 "$tmp/key.gpg" "$keyring" \
		&& printf 'Types: deb\nURIs: https://deb.nodesource.com/node_%s.x\nSuites: nodistro\nComponents: main\nSigned-By: %s\n' \
			"$NODE_MAJOR" "$keyring" >/etc/apt/sources.list.d/nodesource.sources \
		&& apt-get update -qq \
		&& apt-get install -y -qq nodejs
	rc=$?
	rm -rf "$tmp"
	[ "$rc" -eq 0 ] || return 1
	node --version
}

do_claude() {
	command -v claude >/dev/null && { claude --version; return 0; }
	# Say so explicitly rather than letting `npm: command not found` be the
	# message. This failure is almost always DOWNSTREAM of the node step, and a
	# reader who sees only the npm error goes looking for a problem with npm.
	if ! command -v npm >/dev/null; then
		echo "   npm is absent because the node step did not succeed —" >&2
		echo "   fix that first; this failure follows from it" >&2
		return 1
	fi
	# Unpinned deliberately: `msbctl update <name> -c claude` tracks latest, and
	# pinning here would make a rebuild silently undo that. The pinned
	# components below are the ones whose absence breaks something.
	#
	# The package is pure npm: `engines: node >=22`, no dependencies, and a
	# prebuilt per-platform binary as an optionalDependency. It needs
	# registry.npmjs.org and nothing else — in particular it does NOT need bun,
	# whatever the upstream build toolchain happens to be.
	npm install -g @anthropic-ai/claude-code || return 1
	claude --version
}

# The ACP adapter, so an editor (Zed and friends) can drive Claude in this
# sandbox over stdio: `msbctl exec . -- claude-agent-acp`. Installed whenever
# claude is, unpinned for the same reason. Also pure npm, `engines: node >=22`,
# registry.npmjs.org only.
do_claude_acp() {
	command -v claude-agent-acp >/dev/null && return 0
	if ! command -v npm >/dev/null; then
		echo "   npm is absent because the node step did not succeed" >&2
		return 1
	fi
	npm install -g @agentclientprotocol/claude-agent-acp || return 1
	command -v claude-agent-acp
}

do_bun() {
	command -v bun >/dev/null && { bun --version; return 0; }
	local arch base zip tmp rc
	case "$(uname -m)" in
		x86_64)        arch=x64 ;;
		aarch64|arm64) arch=aarch64 ;;
		*) echo "   unsupported arch $(uname -m) for bun" >&2; return 1 ;;
	esac
	# A pinned release asset checked against the SHASUMS256.txt published beside
	# it, not bun.sh/install (an unverified script that fetches "latest").
	base="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}"
	zip="bun-linux-${arch}.zip"
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/$zip" "$base/$zip" \
		&& curl -fsSL -o "$tmp/sums" "$base/SHASUMS256.txt" \
		&& (cd "$tmp" && grep " $zip\$" sums | sha256sum -c --quiet) \
		&& unzip -q "$tmp/$zip" -d "$tmp" \
		&& install "$tmp/bun-linux-${arch}/bun" /usr/local/bin/bun
	rc=$?
	rm -rf "$tmp"
	[ "$rc" -eq 0 ] && bun --version
}

do_gitleaks() {
	command -v gitleaks >/dev/null && { gitleaks version; return 0; }
	local arch tmp
	case "$(uname -m)" in
		x86_64)        arch=x64 ;;
		aarch64|arm64) arch=arm64 ;;
		*) echo "   unsupported arch $(uname -m) for gitleaks" >&2; return 1 ;;
	esac
	tmp="$(mktemp)"
	curl -fsSL -o "$tmp" \
		"https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${arch}.tar.gz" \
		&& tar -xzf "$tmp" -C /usr/local/bin gitleaks
	local rc=$?
	rm -f "$tmp"
	[ "$rc" -eq 0 ] && gitleaks version
}

do_gh() {
	command -v gh >/dev/null && { gh --version | head -1; return 0; }
	local arch base tgz tmp rc
	case "$(uname -m)" in
		x86_64)        arch=amd64 ;;
		aarch64|arm64) arch=arm64 ;;
		*) echo "   unsupported arch $(uname -m) for gh" >&2; return 1 ;;
	esac
	base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"
	tgz="gh_${GH_VERSION}_linux_${arch}.tar.gz"
	tmp="$(mktemp -d)"
	# Checked against upstream's published checksums, not just fetched.
	curl -fsSL -o "$tmp/$tgz" "$base/$tgz" \
		&& curl -fsSL -o "$tmp/sums" "$base/gh_${GH_VERSION}_checksums.txt" \
		&& (cd "$tmp" && grep " $tgz\$" sums | sha256sum -c --quiet) \
		&& tar -xzf "$tmp/$tgz" -C "$tmp" \
		&& install "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh
	rc=$?
	rm -rf "$tmp"
	[ "$rc" -eq 0 ] && gh --version | head -1
}

do_safe_directories() {
	# git refuses to operate on a repo owned by another uid ("detected dubious
	# ownership"), which is guaranteed here: the guest runs as root while
	# --mount-dir presents every file as the host user. Without this, git
	# rev-parse fails and callers report "not inside a git working tree", which
	# names the symptom rather than the cause.
	#
	# TWO LAYOUTS, both normal:
	#   <project>/.git          the project is the repo
	#   <project>/<name>/.git   the project CONTAINS repos, with .msb/ beside them
	#
	# One level only, and each checkout is added by name rather than with a
	# wildcard, so the exemption stays a list of named paths.
	git config --global --add safe.directory "$PROJECT_DIR" || return 1
	local repo
	for repo in "$PROJECT_DIR"/*/; do
		repo="${repo%/}"
		[ -d "$repo/.git" ] && { git config --global --add safe.directory "$repo" || return 1; }
	done
	return 0
}

do_project_script() {
	local script="$PROJECT_DIR/$PROJECT_SCRIPT"
	[ -f "$script" ] || { echo "   $script not found" >&2; return 1; }
	cd "$PROJECT_DIR" && bash "$script"
}

step required "apt packages${EXTRA_PACKAGES:+ (+$EXTRA_PACKAGES)}" -- do_apt
do_container_storage() {
	command -v fuse-overlayfs >/dev/null \
		|| { echo "   fuse-overlayfs is not installed — add it to packages" >&2; return 1; }
	mkdir -p /etc/containers
	cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
}

# The package caches are disk volumes mounted at a dot-free path (msb rejects a dot
# in a named disk's guest path), so the tool's own dotted directory is pointed at
# the mount. Runs on every create, which is what makes a rebuild find its cache.
do_cache_links() {
	local pair src dest rc=0
	for pair in $CACHE_LINKS; do
		src="${pair%%:*}"; dest="${pair#*:}"
		mkdir -p "$(dirname "$dest")"
		[ -L "$dest" ] || rmdir "$dest" 2>/dev/null     # an EMPTY directory is replaced
		if [ -e "$dest" ] && [ ! -L "$dest" ]; then
			echo "   $dest already has content; left alone (cache not linked)" >&2
			rc=1
			continue
		fi
		ln -sfn "$src" "$dest"
	done
	return $rc
}

[ -n "$CACHE_LINKS" ] && step optional "package cache links" -- do_cache_links

# Optional: the sandbox works without it, podman just falls back to vfs.
[ "$CONTAINERS_STORAGE" = fuse-overlayfs ] \
	&& step optional "podman storage (fuse-overlayfs)" -- do_container_storage

# node's required-ness FOLLOWS claude's, because node is here to install claude
# and nothing else in this script needs it. Reporting "REQUIRED, FAILED: node"
# in a sandbox that never asked for an agent names a problem the operator does
# not have.
#
# Required-ness means "the sandbox cannot do its job without this": the runtime
# an agent installs with, when one was asked for.
if [ "$WANT_CLAUDE" = 1 ]; then
	step required "node ${NODE_MAJOR}" -- do_node
	step optional "claude-code"        -- do_claude
	step optional "claude-agent-acp"   -- do_claude_acp
else
	step optional "node ${NODE_MAJOR}" -- do_node
fi

# Optional: commits and pushes work without gh; only PRs and CI reads need it.
# Never `gh auth login` here — pass GH_TOKEN per invocation so the --secret
# placeholder is what gh sends and the interceptor swaps it.
step optional "gh ${GH_VERSION}" -- do_gh

[ "$WANT_BUN" = 1 ] && step optional "bun ${BUN_VERSION}" -- do_bun

[ "$WANT_GITLEAKS" = 1 ] && step optional "gitleaks ${GITLEAKS_VERSION}" -- do_gitleaks

# Required: without it git refuses every repo in the project.
step required "git safe.directory" -- do_safe_directories

[ -n "$PROJECT_SCRIPT" ] && step optional "project script ($PROJECT_SCRIPT)" -- do_project_script

say "summary"
if [ "${#FAILED_OPTIONAL[@]}" -gt 0 ]; then
	printf '   optional, degraded: %s\n' "${FAILED_OPTIONAL[*]}"
fi
if [ "${#FAILED_REQUIRED[@]}" -gt 0 ]; then
	printf '   REQUIRED, FAILED:   %s\n' "${FAILED_REQUIRED[*]}"
	cat <<-'EOF'

	   The usual cause is a missing egress rule, not a broken installer: this
	   sandbox is deny-by-default and the allowlist is built from observed
	   denials. Read the error above for the host it could not reach, add it to
	   `extra_rules` in the project's .msb/sandbox.toml (or to a rule group in
	   ~/.config/msb/config.toml if more than one project needs it), then
	   rebuild.

	   Every failure is listed at once on purpose, so one round trip fixes all
	   of them rather than uncovering the next one.
	EOF
	exit 1
fi

cat <<'EOF'
   Bootstrap complete. It will not run again unless the sandbox is rebuilt.

   Not done here, deliberately:
     - git identity. msbctl applies the chosen one with `git config --system`
       on every START, not here, so changing it in config.toml takes effect on
       the next start rather than needing a rebuild. --system is the lowest
       layer, so a repo's own .git/config still wins — which is the point.
     - gh auth. GH_TOKEN is a `--secret` placeholder swapped on egress; use
       `gh` normally and never `gh auth login`.
     - the managed CLAUDE.md. msbctl copies it in on every start, not once
       here, so editing it on the host takes effect on the next start.
EOF
