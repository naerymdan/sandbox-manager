#!/bin/sh
# msb-manager installer
#
#   curl -fsSL https://github.com/@@GITHUB_REPO@@/releases/latest/download/get.sh | sh
#   curl -fsSL .../get.sh | sh -s -- --version v0.2.0        # a specific release
#   curl -fsSL .../get.sh | sh -s -- --prefix ~/tools        # extra flags go to install.sh
#
# Downloads a release of msb-manager, VERIFIES its sha256 against the checksums
# published with it, and runs the installer inside it. Nothing is installed if the
# checksum does not match.
#
# The checksum only catches a damaged download: whoever can replace the tarball
# can replace checksums.sha256 beside it. So when an authenticated `gh` is on
# PATH, the tarball's build provenance (a Sigstore-signed attestation made by this
# repository's release workflow) is verified too, and a failure installs nothing.
# Without `gh` the checksum is all that was checked, and the output says so.
#
# Needs: curl, tar, sha256sum (or shasum), bash. Optional: gh (provenance). The installer then checks for
# python3 3.11+, git, and msb itself, and says what is missing.
#
# For testing and mirrors:
#   MSB_MANAGER_REPO=owner/name       use a different repository
#   MSB_MANAGER_BASE_URL=URL          fetch assets from URL/<file> instead of GitHub
#                                     releases (file:// works); needs --version.
#                                     A mirror is not attested, so provenance is skipped.
#   MSB_MANAGER_SKIP_ATTEST=1         skip the provenance check even if gh is there
set -eu

# Filled in when this file is attached to a release by scripts/package.sh. In a
# plain checkout it is still the placeholder, and says so rather than guessing.
GITHUB_REPO="${MSB_MANAGER_REPO:-@@GITHUB_REPO@@}"

# ---------------------------------------------------------------------------
# Output (colors only on a terminal)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
    RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
else
    BOLD=''; GREEN=''; CYAN=''; RED=''; YELLOW=''; RESET=''
fi

info()    { printf "${BOLD}${CYAN}info${RESET} %s\n" "$1"; }
success() { printf "${BOLD}${GREEN}done${RESET} %s\n" "$1"; }
warn()    { printf "${BOLD}${YELLOW}warn${RESET} %s\n" "$1" >&2; }
error()   { printf "${BOLD}${RED}error${RESET} %s\n" "$1" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "required command not found: $1"
}

usage() {
    cat <<'EOF'
msb-manager installer

  curl -fsSL https://github.com/OWNER/msb-manager/releases/latest/download/get.sh | sh
  curl -fsSL .../get.sh | sh -s -- --version v0.2.0

  --version VERSION   install this release (e.g. v0.2.0) instead of the latest
  --print-version     resolve the version to install, print it, and stop
  -h, --help          this text

Any other flag (--prefix, --bin-dir, --no-desktop, ...) is passed to install.sh.
EOF
}

# ---------------------------------------------------------------------------
# Arguments. Anything not ours is rotated to the end and handed to install.sh.
# ---------------------------------------------------------------------------

VERSION="${MSB_MANAGER_VERSION:-}"
PRINT_ONLY=0

_n=$#
while [ "$_n" -gt 0 ]; do
    _arg="$1"; shift; _n=$((_n - 1))
    case "$_arg" in
        --version)
            [ "$_n" -gt 0 ] || error "--version needs a value, e.g. --version v0.2.0"
            VERSION="$1"; shift; _n=$((_n - 1)) ;;
        --version=*) VERSION="${_arg#--version=}" ;;
        --print-version) PRINT_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) set -- "$@" "$_arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Version resolution
# ---------------------------------------------------------------------------

check_repo() {
    case "$GITHUB_REPO" in
        *@@*)
            error "this copy of get.sh is not tied to a repository. Use the get.sh attached to a release, or set MSB_MANAGER_REPO=owner/name." ;;
    esac
}

get_latest_version() {
    _url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    VERSION=$(curl -fsSL "$_url" | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/') || true
    [ -n "$VERSION" ] || error "could not determine the latest release of ${GITHUB_REPO} (no releases yet, or GitHub is unreachable)"
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

download() {
    _src="$1"; _dest="$2"
    if [ -t 1 ]; then
        curl -fL --progress-bar "$_src" -o "$_dest" || error "failed to download $_src"
    else
        curl -fsSL "$_src" -o "$_dest" || error "failed to download $_src"
    fi
}

verify() {   # verify <file> <checksums-file>
    _file="$1"; _sums="$2"
    _line=$(grep -F "  ${_file}" "$_sums" | head -1 || true)
    [ -n "$_line" ] || error "no checksum for ${_file} in the published checksums — refusing to install"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s\n' "$_line" | sha256sum -c --quiet - || error "checksum verification FAILED for ${_file} — nothing was installed"
    else
        _expected=$(printf '%s\n' "$_line" | awk '{print $1}')
        _actual=$(shasum -a 256 "$_file" | awk '{print $1}')
        [ "$_expected" = "$_actual" ] || error "checksum verification FAILED for ${_file} — nothing was installed"
    fi
}

# Provenance: the tarball must have been built by this repository's release
# workflow. Fails closed when gh can check and the check fails; degrades to a
# warning when it cannot be asked (no gh, not logged in, a mirror, or opted out).
verify_provenance() {   # verify_provenance <file>
    _file="$1"
    if [ -n "${MSB_MANAGER_BASE_URL:-}" ]; then
        warn "provenance not checked: assets came from MSB_MANAGER_BASE_URL, not a GitHub release"; return 0
    fi
    if [ "${MSB_MANAGER_SKIP_ATTEST:-}" = 1 ]; then
        warn "provenance not checked: MSB_MANAGER_SKIP_ATTEST=1"; return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        warn "provenance not checked (install gh to verify who built this); only the checksum was verified"; return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        warn "provenance not checked (gh is not logged in); only the checksum was verified"; return 0
    fi
    gh attestation verify "$_file" --repo "$GITHUB_REPO" \
        --signer-workflow "${GITHUB_REPO}/.github/workflows/release.yml" >/dev/null 2>&1 \
        || error "provenance verification FAILED for ${_file}: it was not built by ${GITHUB_REPO}'s release workflow — nothing was installed (MSB_MANAGER_SKIP_ATTEST=1 to override)"
    success "Provenance verified (built by ${GITHUB_REPO}'s release workflow)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    need_cmd curl
    need_cmd tar
    need_cmd bash
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || error "required command not found: sha256sum or shasum"

    if [ -z "${MSB_MANAGER_BASE_URL:-}" ]; then
        check_repo
        [ -n "$VERSION" ] || get_latest_version
        _base="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}"
    else
        [ -n "$VERSION" ] || error "MSB_MANAGER_BASE_URL needs --version: there is no API to ask for the latest"
        _base="${MSB_MANAGER_BASE_URL%/}"
    fi

    if [ "$PRINT_ONLY" -eq 1 ]; then
        printf '%s\n' "$VERSION"
        exit 0
    fi

    printf "\n  ${BOLD}msb-manager installer${RESET}\n\n"
    info "Version: $VERSION"

    _ver="${VERSION#v}"
    _bundle="msb-manager-${_ver}.tar.gz"
    _tmp=$(mktemp -d)
    trap 'rm -rf "$_tmp"' EXIT

    info "Downloading ${_bundle}..."
    download "${_base}/${_bundle}" "${_tmp}/${_bundle}"
    download "${_base}/checksums.sha256" "${_tmp}/checksums.sha256"

    info "Verifying checksum..."
    ( cd "$_tmp" && verify "$_bundle" checksums.sha256 )
    success "Checksum verified"
    verify_provenance "${_tmp}/${_bundle}"

    info "Extracting..."
    tar -xzf "${_tmp}/${_bundle}" -C "$_tmp"
    _dir="${_tmp}/msb-manager-${_ver}"
    [ -f "${_dir}/install.sh" ] || error "the release does not contain msb-manager-${_ver}/install.sh"

    # stdin is this script when run as `curl | sh`; the installer must not read it.
    bash "${_dir}/install.sh" --package "$@" </dev/null
}

main "$@"
