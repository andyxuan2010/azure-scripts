#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro-extension-wheel-file-installation.sh [--wheel PATH_OR_URL]

The current Azure CLI normally provides the az aro command. If it is not
available, this script installs or upgrades the supported CLI extension.
Use --wheel only for an approved offline/private wheel.
USAGE
}

WHEEL_SOURCE=${ARO_EXTENSION_WHEEL_SOURCE:-}
while (($#)); do
    case $1 in
        --wheel) WHEEL_SOURCE=${2:?Missing value for --wheel}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login

if [[ -z "$WHEEL_SOURCE" ]]; then
    if az aro --help >/dev/null 2>&1; then
        aro_log INFO "The installed Azure CLI already provides the az aro command."
    else
        aro_log INFO "Installing or upgrading the Azure CLI ARO extension."
        az extension add --name aro --upgrade --only-show-errors
    fi
else
    aro_require_cmd curl
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf -- "$TEMP_DIR"' EXIT
    WHEEL_PATH="$TEMP_DIR/aro-extension.whl"
    if [[ "$WHEEL_SOURCE" =~ ^https?:// ]]; then
        curl --fail --location --silent --show-error --retry 3 \
            --output "$WHEEL_PATH" "$WHEEL_SOURCE"
    else
        aro_require_file "$WHEEL_SOURCE"
        cp -- "$WHEEL_SOURCE" "$WHEEL_PATH"
    fi
    aro_log INFO "Installing the approved ARO extension wheel."
    az extension add --source "$WHEEL_PATH" --upgrade --only-show-errors
fi

az aro --help >/dev/null 2>&1 ||
    aro_die "The az aro command is not available after installation."
aro_log INFO "Azure CLI ARO command is ready."
