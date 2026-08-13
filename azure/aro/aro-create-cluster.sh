#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro-create-cluster.sh --mode public|private --location LOCATION
                             --resource-group RESOURCE_GROUP
                             --cluster-resource-group RESOURCE_GROUP
                             --cluster-name NAME --pull-secret FILE
                             [--vnet-resource-group RESOURCE_GROUP]
                             [--vnet-name NAME] [--vnet-prefix CIDR]
                             [--master-subnet NAME] [--master-prefix CIDR]
                             [--worker-subnet NAME] [--worker-prefix CIDR]
                             [--domain DOMAIN] [--dns-servers "IP ..."]
                             [--worker-count COUNT]
                             [--master-vm-size SKU] [--worker-vm-size SKU]

Creates an idempotent ARO network and cluster. Existing resources are
validated and reused; conflicting subnet definitions cause a failure.
USAGE
}

MODE=${ARO_VISIBILITY:-}
LOCATION=${ARO_LOCATION:-}
RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-}
CLUSTER_RESOURCE_GROUP=${ARO_CLUSTER_RESOURCE_GROUP:-}
CLUSTER_NAME=${ARO_CLUSTER_NAME:-}
PULL_SECRET=${ARO_PULL_SECRET_FILE:-}
VNET_RESOURCE_GROUP=${ARO_VNET_RESOURCE_GROUP:-}
VNET_NAME=${ARO_VNET_NAME:-}
VNET_PREFIX=${ARO_VNET_PREFIX:-10.0.0.0/22}
MASTER_SUBNET=${ARO_MASTER_SUBNET:-}
MASTER_PREFIX=${ARO_MASTER_PREFIX:-10.0.0.0/23}
WORKER_SUBNET=${ARO_WORKER_SUBNET:-}
WORKER_PREFIX=${ARO_WORKER_PREFIX:-10.0.2.0/23}
DOMAIN=${ARO_DOMAIN:-}
DNS_SERVERS_VALUE=${ARO_DNS_SERVERS:-}
WORKER_COUNT=${ARO_WORKER_COUNT:-3}
MASTER_VM_SIZE=${ARO_MASTER_VM_SIZE:-Standard_D8s_v3}
WORKER_VM_SIZE=${ARO_WORKER_VM_SIZE:-Standard_D8s_v3}

while (($#)); do
    case $1 in
        --mode) MODE=${2:?Missing value for --mode}; shift 2 ;;
        --location|-l) LOCATION=${2:?Missing value for --location}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --cluster-resource-group) CLUSTER_RESOURCE_GROUP=${2:?Missing value for --cluster-resource-group}; shift 2 ;;
        --cluster-name|-n) CLUSTER_NAME=${2:?Missing value for --cluster-name}; shift 2 ;;
        --pull-secret) PULL_SECRET=${2:?Missing value for --pull-secret}; shift 2 ;;
        --vnet-resource-group) VNET_RESOURCE_GROUP=${2:?Missing value for --vnet-resource-group}; shift 2 ;;
        --vnet-name) VNET_NAME=${2:?Missing value for --vnet-name}; shift 2 ;;
        --vnet-prefix) VNET_PREFIX=${2:?Missing value for --vnet-prefix}; shift 2 ;;
        --master-subnet) MASTER_SUBNET=${2:?Missing value for --master-subnet}; shift 2 ;;
        --master-prefix) MASTER_PREFIX=${2:?Missing value for --master-prefix}; shift 2 ;;
        --worker-subnet) WORKER_SUBNET=${2:?Missing value for --worker-subnet}; shift 2 ;;
        --worker-prefix) WORKER_PREFIX=${2:?Missing value for --worker-prefix}; shift 2 ;;
        --domain) DOMAIN=${2:?Missing value for --domain}; shift 2 ;;
        --dns-servers) DNS_SERVERS_VALUE=${2:?Missing value for --dns-servers}; shift 2 ;;
        --worker-count) WORKER_COUNT=${2:?Missing value for --worker-count}; shift 2 ;;
        --master-vm-size) MASTER_VM_SIZE=${2:?Missing value for --master-vm-size}; shift 2 ;;
        --worker-vm-size) WORKER_VM_SIZE=${2:?Missing value for --worker-vm-size}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ "$MODE" =~ ^(public|private|Public|Private)$ ]] ||
    aro_die "--mode must be public or private."
MODE=${MODE,,}
MODE_DISPLAY=${MODE^}
[[ -n "$LOCATION" && -n "$RESOURCE_GROUP" && -n "$CLUSTER_RESOURCE_GROUP" &&
   -n "$CLUSTER_NAME" && -n "$PULL_SECRET" ]] ||
    { usage >&2; aro_die "Location, resource groups, cluster name, and pull-secret are required."; }
[[ "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] ||
    aro_die "Cluster name must use lowercase letters, numbers, and hyphens only."
[[ -n "$VNET_RESOURCE_GROUP" ]] && : || VNET_RESOURCE_GROUP="$RESOURCE_GROUP"
[[ -n "$VNET_NAME" ]] && : || VNET_NAME="$CLUSTER_NAME-vnet"
[[ -n "$MASTER_SUBNET" ]] && : || MASTER_SUBNET="$CLUSTER_NAME-master-subnet"
[[ -n "$WORKER_SUBNET" ]] && : || WORKER_SUBNET="$CLUSTER_NAME-worker-subnet"
[[ "$WORKER_COUNT" =~ ^[1-9][0-9]*$ ]] ||
    aro_die "--worker-count must be a positive integer."
for cidr in "$VNET_PREFIX" "$MASTER_PREFIX" "$WORKER_PREFIX"; do
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] ||
        aro_die "Invalid network prefix: $cidr"
done

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_require_file "$PULL_SECRET"
aro_az_provider_register \
    Microsoft.RedHatOpenShift Microsoft.Compute Microsoft.Storage \
    Microsoft.Authorization Microsoft.Network

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --only-show-errors -o none
if az network vnet show --resource-group "$VNET_RESOURCE_GROUP" --name "$VNET_NAME" \
    --only-show-errors -o none >/dev/null 2>&1; then
    VNET_HAS_PREFIX="$(az network vnet show --resource-group "$VNET_RESOURCE_GROUP" \
        --name "$VNET_NAME" --query "contains(addressSpace.addressPrefixes, '$VNET_PREFIX')" \
        -o tsv --only-show-errors)"
    [[ "$VNET_HAS_PREFIX" == "true" ]] ||
        aro_die "VNet '$VNET_NAME' exists but does not contain prefix '$VNET_PREFIX'."
    aro_log INFO "Reusing VNet '$VNET_NAME'."
else
    az network vnet create --resource-group "$VNET_RESOURCE_GROUP" --name "$VNET_NAME" \
        --address-prefixes "$VNET_PREFIX" --only-show-errors -o none
fi

ensure_subnet() {
    local name=$1
    local prefix=$2
    local existing
    existing="$(az network vnet subnet show --resource-group "$VNET_RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" --name "$name" --query addressPrefix \
        -o tsv --only-show-errors 2>/dev/null || true)"
    if [[ -z "$existing" ]]; then
        existing="$(az network vnet subnet show --resource-group "$VNET_RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" --name "$name" --query addressPrefixes[0] \
            -o tsv --only-show-errors 2>/dev/null || true)"
    fi
    if [[ -n "$existing" ]]; then
        [[ "$existing" == "$prefix" ]] ||
            aro_die "Subnet '$name' exists with prefix '$existing', expected '$prefix'."
        aro_log INFO "Reusing subnet '$name'."
    else
        az network vnet subnet create --resource-group "$VNET_RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" --name "$name" --address-prefixes "$prefix" \
            --service-endpoints Microsoft.ContainerRegistry --only-show-errors -o none
    fi
}

ensure_subnet "$MASTER_SUBNET" "$MASTER_PREFIX"
ensure_subnet "$WORKER_SUBNET" "$WORKER_PREFIX"
az network vnet subnet update --resource-group "$VNET_RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name "$MASTER_SUBNET" \
    --disable-private-link-service-network-policies true --only-show-errors -o none

if aro_aro_exists "$CLUSTER_NAME" "$RESOURCE_GROUP"; then
    aro_log INFO "ARO cluster '$CLUSTER_NAME' already exists; no create operation was submitted."
else
    VALIDATE_ARGS=(az aro validate --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
        --vnet "$VNET_NAME" --vnet-resource-group "$VNET_RESOURCE_GROUP" \
        --master-subnet "$MASTER_SUBNET" --worker-subnet "$WORKER_SUBNET" \
        --cluster-resource-group "$CLUSTER_RESOURCE_GROUP")
    "${VALIDATE_ARGS[@]}" --only-show-errors

    CREATE_ARGS=(az aro create --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
        --cluster-resource-group "$CLUSTER_RESOURCE_GROUP" \
        --vnet "$VNET_NAME" --vnet-resource-group "$VNET_RESOURCE_GROUP" \
        --master-subnet "$MASTER_SUBNET" --worker-subnet "$WORKER_SUBNET" \
        --apiserver-visibility "$MODE_DISPLAY" --ingress-visibility "$MODE_DISPLAY" \
        --worker-count "$WORKER_COUNT" --master-vm-size "$MASTER_VM_SIZE" \
        --worker-vm-size "$WORKER_VM_SIZE" --pull-secret "$PULL_SECRET" \
        --only-show-errors)
    [[ -n "$DOMAIN" ]] && CREATE_ARGS+=(--domain "$DOMAIN")
    if [[ -n "$DNS_SERVERS_VALUE" ]]; then
        DNS_ARGS=()
        IFS=' ' read -r -a DNS_ARGS <<< "$DNS_SERVERS_VALUE"
        CREATE_ARGS+=(--dns-servers "${DNS_ARGS[@]}")
    fi
    "${CREATE_ARGS[@]}"
fi

az aro show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
    --query '{name:name,state:provisioningState,api:apiserverProfile.url,console:consoleProfile.url}' \
    -o jsonc --only-show-errors
