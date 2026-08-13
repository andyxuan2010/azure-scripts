#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

LOCATION=${ARO_LOCATION:-eastus}
CLUSTER_NAME=${ARO_CLUSTER_NAME:-"aro-$(id -un)-$(date -u +%Y%m%d%H%M%S)"}
RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-"$CLUSTER_NAME-$LOCATION"}
CLUSTER_RESOURCE_GROUP=${ARO_CLUSTER_RESOURCE_GROUP:-"$RESOURCE_GROUP-cluster"}
PULL_SECRET=${ARO_PULL_SECRET_FILE:-pull-secret.txt}
VNET_PREFIX=${ARO_VNET_PREFIX:-10.151.0.0/16}
WORKER_COUNT=${ARO_WORKER_COUNT:-4}
MASTER_VM_SIZE=${ARO_MASTER_VM_SIZE:-Standard_D8s_v3}
WORKER_VM_SIZE=${ARO_WORKER_VM_SIZE:-Standard_D4s_v3}
MODE=${ARO_VISIBILITY:-public}

CUSTOM_DOMAIN=
if (($# > 0)) && [[ $1 != -* ]]; then
    CUSTOM_DOMAIN=$1
    shift
fi

DEFAULT_ARGS=(
    --mode "$MODE"
    --location "$LOCATION"
    --resource-group "$RESOURCE_GROUP"
    --cluster-resource-group "$CLUSTER_RESOURCE_GROUP"
    --cluster-name "$CLUSTER_NAME"
    --pull-secret "$PULL_SECRET"
    --vnet-prefix "$VNET_PREFIX"
    --worker-count "$WORKER_COUNT"
    --master-vm-size "$MASTER_VM_SIZE"
    --worker-vm-size "$WORKER_VM_SIZE"
)
[[ -n "$CUSTOM_DOMAIN" ]] && DEFAULT_ARGS+=(--domain "$CUSTOM_DOMAIN")

exec "$SCRIPT_DIR/aro-create-cluster.sh" "${DEFAULT_ARGS[@]}" "$@"
