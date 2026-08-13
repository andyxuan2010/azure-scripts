#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: connect-acr-to-aro.sh --registry NAME --resource-group RESOURCE_GROUP
                              --location LOCATION --image IMAGE[:TAG]
                              [--sku Basic|Standard|Premium]
                              [--namespace NAMESPACE] [--secret-name NAME]
                              [--enable-admin] [--create-namespace]

Creates or reuses an Azure Container Registry, pushes a pinned image, and
creates an idempotent OpenShift pull secret. Registry admin credentials are
disabled unless --enable-admin is explicitly supplied. Existing credentials
may be provided through ACR_DOCKER_USERNAME and ACR_DOCKER_PASSWORD.
USAGE
}

REGISTRY=${ARO_ACR_NAME:-}
RESOURCE_GROUP=${ARO_ACR_RESOURCE_GROUP:-}
LOCATION=${ARO_ACR_LOCATION:-}
SKU=${ARO_ACR_SKU:-Standard}
IMAGE=${ARO_IMAGE_REF:-}
NAMESPACE=${ARO_NAMESPACE:-default}
SECRET_NAME=${ARO_ACR_SECRET_NAME:-acr-pull-secret}
ENABLE_ADMIN=0
CREATE_NAMESPACE=0

while (($#)); do
    case $1 in
        --registry|-n) REGISTRY=${2:?Missing value for --registry}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --location|-l) LOCATION=${2:?Missing value for --location}; shift 2 ;;
        --sku) SKU=${2:?Missing value for --sku}; shift 2 ;;
        --image|-i) IMAGE=${2:?Missing value for --image}; shift 2 ;;
        --namespace) NAMESPACE=${2:?Missing value for --namespace}; shift 2 ;;
        --secret-name) SECRET_NAME=${2:?Missing value for --secret-name}; shift 2 ;;
        --enable-admin) ENABLE_ADMIN=1; shift ;;
        --create-namespace) CREATE_NAMESPACE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$REGISTRY" && -n "$RESOURCE_GROUP" && -n "$LOCATION" && -n "$IMAGE" ]] ||
    { usage >&2; aro_die "Registry, resource group, location, and image are required."; }
[[ "$REGISTRY" =~ ^[a-z0-9]{5,50}$ ]] ||
    aro_die "Registry name must be 5-50 lowercase alphanumeric characters."
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    aro_die "Invalid Kubernetes namespace: $NAMESPACE"
[[ "$SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    aro_die "Invalid Kubernetes secret name: $SECRET_NAME"

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_require_oc_login
aro_require_cmd docker

if ! az acr show --name "$REGISTRY" --resource-group "$RESOURCE_GROUP" \
    --only-show-errors -o none >/dev/null 2>&1; then
    aro_log INFO "Creating ACR '$REGISTRY' in '$LOCATION'."
    az acr create --name "$REGISTRY" --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" --sku "$SKU" --admin-enabled false \
        --public-network-enabled true --only-show-errors -o none
fi

if ((ENABLE_ADMIN)); then
    aro_log WARNING "Enabling ACR admin credentials was explicitly requested."
    az acr update --name "$REGISTRY" --resource-group "$RESOURCE_GROUP" \
        --admin-enabled true --only-show-errors -o none
fi

LOGIN_SERVER="$(az acr show --name "$REGISTRY" --resource-group "$RESOURCE_GROUP" \
    --query loginServer -o tsv --only-show-errors)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
export DOCKER_CONFIG="$TEMP_DIR/docker"
mkdir -p "$DOCKER_CONFIG"
ACR_DOCKER_USERNAME="${ACR_DOCKER_USERNAME:-}"
ACR_DOCKER_PASSWORD="${ACR_DOCKER_PASSWORD:-}"
if [[ -z "$ACR_DOCKER_USERNAME" || -z "$ACR_DOCKER_PASSWORD" ]] && (( ! ENABLE_ADMIN )); then
    aro_die "Set ACR_DOCKER_USERNAME and ACR_DOCKER_PASSWORD, or explicitly use --enable-admin."
fi
aro_log INFO "Authenticating Docker to $LOGIN_SERVER."
az acr login --name "$REGISTRY" --only-show-errors

IMAGE_NAME=${IMAGE##*/}
DEST_IMAGE="$LOGIN_SERVER/$IMAGE_NAME"
aro_log INFO "Pulling and pushing image '$IMAGE_NAME'."
docker pull "$IMAGE"
docker tag "$IMAGE" "$DEST_IMAGE"
docker push "$DEST_IMAGE"

ACR_DOCKER_USERNAME=${ACR_DOCKER_USERNAME:-}
ACR_DOCKER_PASSWORD=${ACR_DOCKER_PASSWORD:-}
if [[ -z "$ACR_DOCKER_USERNAME" || -z "$ACR_DOCKER_PASSWORD" ]]; then
    ((ENABLE_ADMIN)) ||
        aro_die "Set ACR_DOCKER_USERNAME and ACR_DOCKER_PASSWORD, or explicitly use --enable-admin."
    ACR_DOCKER_USERNAME="$(az acr credential show --name "$REGISTRY" \
        --query username -o tsv --only-show-errors)"
    ACR_DOCKER_PASSWORD="$(az acr credential show --name "$REGISTRY" \
        --query 'passwords[0].value' -o tsv --only-show-errors)"
fi
[[ -n "$ACR_DOCKER_USERNAME" && -n "$ACR_DOCKER_PASSWORD" ]] ||
    aro_die "Registry credentials are empty."

printf '%s' "$ACR_DOCKER_PASSWORD" |
    docker login "$LOGIN_SERVER" --username "$ACR_DOCKER_USERNAME" --password-stdin >/dev/null

if ((CREATE_NAMESPACE)); then
    oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
fi
oc get namespace "$NAMESPACE" >/dev/null ||
    aro_die "Namespace '$NAMESPACE' does not exist. Use --create-namespace if appropriate."

aro_log INFO "Applying pull secret '$SECRET_NAME' in namespace '$NAMESPACE'."
oc create secret generic "$SECRET_NAME" --namespace "$NAMESPACE" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$DOCKER_CONFIG/config.json" \
    --dry-run=client -o yaml |
    oc apply --server-side --field-manager=aro-scripts -f -

aro_log INFO "ACR image and OpenShift pull secret are ready."
printf 'Image: %s\nSecret: %s/%s\n' "$DEST_IMAGE" "$NAMESPACE" "$SECRET_NAME"
