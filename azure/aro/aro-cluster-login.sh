#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro-cluster-login.sh --name CLUSTER --resource-group RESOURCE_GROUP

Logs in to an ARO cluster as kubeadmin without printing the password.
The Azure CLI session must already be authenticated.
USAGE
}

CLUSTER=${ARO_CLUSTER_NAME:-}
RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-}

while (($#)); do
    case $1 in
        --name|-n) CLUSTER=${2:?Missing value for --name}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER" && -n "$RESOURCE_GROUP" ]] ||
    { usage >&2; aro_die "Both --name and --resource-group are required."; }

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_require_cmd oc
aro_aro_exists "$CLUSTER" "$RESOURCE_GROUP" ||
    aro_die "ARO cluster '$CLUSTER' was not found in resource group '$RESOURCE_GROUP'."

API_SERVER="$(az aro show --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query apiserverProfile.url -o tsv --only-show-errors)"
KUBEADMIN_USERNAME="$(az aro list-credentials --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query kubeadminUsername -o tsv --only-show-errors)"
KUBEADMIN_PASSWORD="$(az aro list-credentials --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query kubeadminPassword -o tsv --only-show-errors)"

[[ -n "$API_SERVER" && -n "$KUBEADMIN_USERNAME" && -n "$KUBEADMIN_PASSWORD" ]] ||
    aro_die "Unable to retrieve the ARO API endpoint or kubeadmin credentials."

aro_log INFO "Logging in to ARO cluster '$CLUSTER'. The password is not written to the log."
oc login "$API_SERVER" --username "$KUBEADMIN_USERNAME" --password "$KUBEADMIN_PASSWORD" \
    --insecure-skip-tls-verify=false >/dev/null

CONSOLE_URL="$(az aro show --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query consoleProfile.url -o tsv --only-show-errors)"
aro_log INFO "OpenShift login succeeded as $(oc whoami)."
printf 'Console URL: %s\n' "$CONSOLE_URL"
