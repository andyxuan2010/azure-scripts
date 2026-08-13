#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: connect-aro-as-arc.sh --name CONNECTED_CLUSTER_NAME
                              --resource-group RESOURCE_GROUP
                              --location LOCATION
                              [--workspace-resource-id RESOURCE_ID]

Connects the current OpenShift context to Azure Arc. Monitoring is installed
only when --workspace-resource-id is supplied.
USAGE
}

CLUSTER=${ARO_ARC_CLUSTER_NAME:-}
RESOURCE_GROUP=${ARO_ARC_RESOURCE_GROUP:-}
LOCATION=${ARO_ARC_LOCATION:-}
WORKSPACE_ID=${ARO_LOG_ANALYTICS_WORKSPACE_ID:-}

while (($#)); do
    case $1 in
        --name|-n) CLUSTER=${2:?Missing value for --name}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --location|-l) LOCATION=${2:?Missing value for --location}; shift 2 ;;
        --workspace-resource-id) WORKSPACE_ID=${2:?Missing value for --workspace-resource-id}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER" && -n "$RESOURCE_GROUP" && -n "$LOCATION" ]] ||
    { usage >&2; aro_die "Name, resource group, and location are required."; }

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_require_oc_login

az extension add --name connectedk8s --upgrade --only-show-errors
aro_az_provider_register Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation

if az connectedk8s show --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --only-show-errors -o none >/dev/null 2>&1; then
    aro_log INFO "Azure Arc connected-cluster resource '$CLUSTER' already exists."
else
    aro_log INFO "Connecting the current OpenShift context to Azure Arc."
    az connectedk8s connect --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" --only-show-errors
fi

if [[ -n "$WORKSPACE_ID" ]]; then
    az extension add --name k8s-extension --upgrade --only-show-errors
    aro_log INFO "Enabling Azure Monitor for containers."
    az k8s-extension create --name azuremonitor-containers \
        --cluster-name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers \
        --scope cluster --configuration-settings \
        "logAnalyticsWorkspaceResourceID=$WORKSPACE_ID" \
        "amalogs.useAADAuth=false" --only-show-errors
    az k8s-extension show --name azuremonitor-containers \
        --cluster-name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters --only-show-errors -o table
fi

aro_log INFO "Azure Arc connection completed."
az connectedk8s show --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --only-show-errors -o table
