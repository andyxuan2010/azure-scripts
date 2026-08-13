#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: oc-cli-install-common.sh --version VERSION --install-root DIRECTORY
                                [--sha256 CHECKSUM] [--persist-shell FILE]

Installs a pinned OpenShift client archive. The checksum is optional for
compatibility but should be supplied for production automation.
USAGE
}

VERSION=
INSTALL_ROOT=
EXPECTED_SHA256=
SHELL_RC=

while (($#)); do
    case $1 in
        --version) VERSION=${2:?Missing value for --version}; shift 2 ;;
        --install-root) INSTALL_ROOT=${2:?Missing value for --install-root}; shift 2 ;;
        --sha256) EXPECTED_SHA256=${2:?Missing value for --sha256}; shift 2 ;;
        --persist-shell) SHELL_RC=${2:?Missing value for --persist-shell}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$VERSION" && -n "$INSTALL_ROOT" ]] ||
    { usage >&2; aro_die "--version and --install-root are required."; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    aro_die "Version must be an exact OpenShift version such as 4.16.33."

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_cmd curl
aro_require_cmd tar
if [[ -n "$EXPECTED_SHA256" ]]; then
    aro_require_cmd sha256sum
    [[ "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]] ||
        aro_die "--sha256 must be a 64-character hexadecimal SHA-256 digest."
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
ARCHIVE="$TEMP_DIR/openshift-client-linux.tar.gz"
EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$VERSION/openshift-client-linux.tar.gz"

aro_log INFO "Downloading pinned OpenShift client $VERSION."
curl --fail --location --silent --show-error --retry 3 --output "$ARCHIVE" "$URL"
if [[ -n "$EXPECTED_SHA256" ]]; then
    printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE" | sha256sum --check --status ||
        aro_die "OpenShift client checksum validation failed."
fi

tar --extract --gzip --file "$ARCHIVE" --directory "$EXTRACT_DIR" oc kubectl

INSTALL_BIN="$INSTALL_ROOT/bin"
if mkdir -p "$INSTALL_BIN" 2>/dev/null && [[ -w "$INSTALL_BIN" ]]; then
    INSTALL_CMD=()
else
    aro_require_cmd sudo
    sudo mkdir -p "$INSTALL_BIN"
    INSTALL_CMD=(sudo)
fi
"${INSTALL_CMD[@]}" install -m 0755 "$EXTRACT_DIR/oc" "$INSTALL_BIN/oc"
"${INSTALL_CMD[@]}" install -m 0755 "$EXTRACT_DIR/kubectl" "$INSTALL_BIN/kubectl"

aro_add_path_once "$INSTALL_BIN"
if [[ -n "$SHELL_RC" ]]; then
    mkdir -p "$(dirname -- "$SHELL_RC")"
    PATH_LINE="export PATH=${PATH}:$INSTALL_BIN"
    if ! grep -Fqx "$PATH_LINE" "$SHELL_RC" 2>/dev/null; then
        printf '\n%s\n' "$PATH_LINE" >> "$SHELL_RC"
    fi
fi

"$INSTALL_BIN/oc" version --client
aro_log INFO "OpenShift client $VERSION installed in $INSTALL_BIN."
