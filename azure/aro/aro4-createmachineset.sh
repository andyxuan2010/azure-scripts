#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro4-createmachineset.sh --name MACHINESET --zone 1|2|3
                                --replicas COUNT --vm-size SKU
                                [--template FILE] [--output FILE] [--apply]

Builds a machine-set manifest from an existing ARO machine set. Without
--apply, the generated manifest is validated but not submitted.
USAGE
}

TEMPLATE=machineset-template.yaml
OUTPUT=
MACHINESET=
ZONE=
REPLICAS=
VM_SIZE=
APPLY=0

while (($#)); do
    case $1 in
        --template) TEMPLATE=${2:?Missing value for --template}; shift 2 ;;
        --output) OUTPUT=${2:?Missing value for --output}; shift 2 ;;
        --name) MACHINESET=${2:?Missing value for --name}; shift 2 ;;
        --zone) ZONE=${2:?Missing value for --zone}; shift 2 ;;
        --replicas) REPLICAS=${2:?Missing value for --replicas}; shift 2 ;;
        --vm-size) VM_SIZE=${2:?Missing value for --vm-size}; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$MACHINESET" && -n "$ZONE" && -n "$REPLICAS" && -n "$VM_SIZE" ]] ||
    { usage >&2; aro_die "Name, zone, replicas, and VM size are required."; }
[[ "$MACHINESET" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    aro_die "Invalid machine-set name: $MACHINESET"
[[ "$ZONE" =~ ^[123]$ ]] || aro_die "Zone must be 1, 2, or 3."
[[ "$REPLICAS" =~ ^[0-9]+$ ]] || aro_die "Replicas must be a non-negative integer."
[[ "$VM_SIZE" =~ ^[A-Za-z0-9._-]+$ ]] || aro_die "Invalid Azure VM SKU: $VM_SIZE"
[[ -n "$OUTPUT" ]] || OUTPUT="$MACHINESET-template.yaml"

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_require_oc_login
aro_require_cmd jq
aro_require_file "$TEMPLATE"

BASE_MACHINESET="$(oc get machineset -n openshift-machine-api \
    -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$BASE_MACHINESET" ]] ||
    aro_die "No existing machine set was found in openshift-machine-api."

get_field() {
    oc get machineset "$BASE_MACHINESET" -n openshift-machine-api \
        -o "jsonpath=$1"
}

AZURE_REGION="$(get_field '{.spec.template.spec.providerSpec.value.location}')"
ARO_SKU="$(get_field '{.spec.template.spec.providerSpec.value.image.sku}')"
ARO_SKU_VERSION="$(get_field '{.spec.template.spec.providerSpec.value.image.version}')"
CLUSTER_NAME="$(get_field '{.metadata.labels.machine\.openshift\.io/cluster-api-cluster}')"
NETWORK_RG="$(get_field '{.spec.template.spec.providerSpec.value.networkResourceGroup}')"
CLUSTER_RG="$(get_field '{.spec.template.spec.providerSpec.value.resourceGroup}')"
PUBLIC_LB="$(get_field '{.spec.template.spec.providerSpec.value.publicLoadBalancer}')"
SUBNET="$(get_field '{.spec.template.spec.providerSpec.value.subnet}')"
VNET_NAME="$(get_field '{.spec.template.spec.providerSpec.value.vnet}')"

[[ -n "$AZURE_REGION" && -n "$ARO_SKU" && -n "$ARO_SKU_VERSION" &&
   -n "$CLUSTER_NAME" && -n "$NETWORK_RG" && -n "$CLUSTER_RG" &&
   -n "$PUBLIC_LB" && -n "$SUBNET" && -n "$VNET_NAME" ]] ||
    aro_die "The existing machine set did not contain all required Azure fields."

VM_JSON="$(az vm list-sizes --location "$AZURE_REGION" \
    --query "[?name=='$VM_SIZE'] | [0]" -o json --only-show-errors)"
MEMORY_MB="$(jq -r '.memoryInMb // empty' <<< "$VM_JSON")"
VCPU_CORES="$(jq -r '.numberOfCores // empty' <<< "$VM_JSON")"
[[ -n "$MEMORY_MB" && -n "$VCPU_CORES" ]] ||
    aro_die "VM size '$VM_SIZE' is not available in Azure region '$AZURE_REGION'."

cp -- "$TEMPLATE" "$OUTPUT"
escape_sed() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}
replace_placeholder() {
    local placeholder=$1
    local value
    value="$(escape_sed "$2")"
    sed -i "s|$placeholder|$value|g" "$OUTPUT"
}

replace_placeholder MEMORYMB "$MEMORY_MB"
replace_placeholder VCPUCORES "$VCPU_CORES"
replace_placeholder CLUSTERNAME "$CLUSTER_NAME"
replace_placeholder MACHINESETNAME "$MACHINESET"
replace_placeholder NETWORKRG "$NETWORK_RG"
replace_placeholder PUBLICLBNAME "$PUBLIC_LB"
replace_placeholder VNETNAME "$VNET_NAME"
replace_placeholder WHICHAZ "$ZONE"
replace_placeholder PROTECTEDRG "$CLUSTER_RG"
replace_placeholder AZUREDC "$AZURE_REGION"
replace_placeholder VMSKU "$VM_SIZE"
replace_placeholder AROSKUVERSION "$ARO_SKU_VERSION"
replace_placeholder AROSKU "$ARO_SKU"
replace_placeholder SUBNET "$SUBNET"
replace_placeholder NUMREPLICAS "$REPLICAS"

if grep -Eq 'MEMORYMB|VCPUCORES|CLUSTERNAME|MACHINESETNAME|NETWORKRG|PUBLICLBNAME|VNETNAME|WHICHAZ|PROTECTEDRG|AZUREDC|VMSKU|AROSKUVERSION|AROSKU|SUBNET|NUMREPLICAS' "$OUTPUT"; then
    aro_die "Unresolved template placeholders remain in $OUTPUT."
fi

oc apply --dry-run=server --filename "$OUTPUT" >/dev/null
aro_log INFO "Generated and validated $OUTPUT."

if ((APPLY)); then
    oc apply --server-side --field-manager=aro-scripts --filename "$OUTPUT"
    aro_log INFO "Machine set '$MACHINESET' applied."
else
    aro_log INFO "No cluster change was made. Re-run with --apply to submit the manifest."
fi
