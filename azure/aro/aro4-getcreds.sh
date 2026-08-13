#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro4-getcreds.sh --name CLUSTER --resource-group RESOURCE_GROUP
                         [--show-credentials]

Endpoint metadata is shown by default. Credentials are retrieved only when
--show-credentials is explicitly supplied and are never embedded in a command.
USAGE
}

CLUSTER=${ARO_CLUSTER_NAME:-}
RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-}
SHOW_CREDENTIALS=0
while (($#)); do
    case $1 in
        --name|-n) CLUSTER=${2:?Missing value for --name}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --show-credentials) SHOW_CREDENTIALS=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER" && -n "$RESOURCE_GROUP" ]] ||
    { usage >&2; aro_die "Both --name and --resource-group are required."; }

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_aro_exists "$CLUSTER" "$RESOURCE_GROUP" ||
    aro_die "ARO cluster '$CLUSTER' was not found in resource group '$RESOURCE_GROUP'."

aro_log INFO "ARO endpoint metadata for '$CLUSTER':"
az aro show --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query '{apiServer:apiserverProfile.url,console:consoleProfile.url,ingress:ingressProfiles}' \
    -o jsonc --only-show-errors

if ((SHOW_CREDENTIALS)); then
    aro_log WARNING "Displaying kubeadmin credentials in the terminal was explicitly requested."
    az aro list-credentials --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
        -o table --only-show-errors
else
    aro_log INFO "Credentials were not displayed. Use --show-credentials only in a controlled terminal."
fi
