#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: delete_cluster.sh --name CLUSTER --resource-group RESOURCE_GROUP
                          [--delete-resource-group] [--yes] [--no-wait]

Cluster deletion is always explicit. The resource group is deleted only when
--delete-resource-group is also supplied.
USAGE
}

CLUSTER=${ARO_CLUSTER_NAME:-}
RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-}
DELETE_RESOURCE_GROUP=0
NO_WAIT=0
export ARO_ASSUME_YES=0

while (($#)); do
    case $1 in
        --name|-n) CLUSTER=${2:?Missing value for --name}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --delete-resource-group) DELETE_RESOURCE_GROUP=1; shift ;;
        --yes) ARO_ASSUME_YES=1; shift ;;
        --no-wait) NO_WAIT=1; shift ;;
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

CONFIRMATION="DELETE $CLUSTER"
if ((DELETE_RESOURCE_GROUP)); then
    CONFIRMATION="DELETE $CLUSTER AND RESOURCE GROUP $RESOURCE_GROUP"
fi
aro_confirm "This operation is destructive: $CONFIRMATION?" "$CONFIRMATION"

DELETE_ARGS=(az aro delete --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" --yes --only-show-errors)
if ((NO_WAIT)); then
    DELETE_ARGS+=(--no-wait)
fi
"${DELETE_ARGS[@]}"
aro_log INFO "ARO cluster deletion submitted."

if ((DELETE_RESOURCE_GROUP)); then
    if ((NO_WAIT)); then
        aro_log INFO "Submitting resource-group deletion without waiting."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait --only-show-errors
    else
        aro_log INFO "Deleting resource group after the ARO delete completes."
        az aro wait --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" --deleted --only-show-errors
        az group delete --name "$RESOURCE_GROUP" --yes --only-show-errors
    fi
fi
