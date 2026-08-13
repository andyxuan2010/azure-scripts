#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

SUBSCRIPTION=${AZURE_SUBSCRIPTION_ID:-}
while (($#)); do
    case $1 in
        --subscription|-s) SUBSCRIPTION=${2:?Missing value for --subscription}; shift 2 ;;
        --help|-h)
            printf 'Usage: register-aro-resource-providers.sh [--subscription SUBSCRIPTION]\n'
            exit 0
            ;;
        *) aro_die "Unknown argument: $1" ;;
    esac
done

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
if [[ -n "$SUBSCRIPTION" ]]; then
    az account set --subscription "$SUBSCRIPTION" --only-show-errors
fi

aro_az_provider_register \
    Microsoft.RedHatOpenShift \
    Microsoft.Compute \
    Microsoft.Storage \
    Microsoft.Authorization \
    Microsoft.Network

aro_log INFO "Required ARO resource providers are registered."
