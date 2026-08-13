#!/usr/bin/env bash
# Shared helpers for the production ARO scripts.
# Source this file; do not execute it directly.

if [[ ${ARO_LIB_LOADED:-0} == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi
ARO_LIB_LOADED=1

aro_log() {
    local level=$1
    shift
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}

aro_die() {
    aro_log ERROR "$*"
    exit 1
}

aro_require_cmd() {
    local command_name=$1
    command -v "$command_name" >/dev/null 2>&1 ||
        aro_die "Required command not found: $command_name"
}

aro_require_file() {
    local file_path=$1
    [[ -f "$file_path" ]] ||
        aro_die "Required file not found: $file_path"
}

aro_require_azure_login() {
    aro_require_cmd az
    az account show --only-show-errors -o none >/dev/null 2>&1 ||
        aro_die "Azure CLI is not authenticated. Run 'az login' or use a workload identity before continuing."
}

aro_require_oc_login() {
    aro_require_cmd oc
    oc whoami >/dev/null 2>&1 ||
        aro_die "OpenShift CLI is not authenticated. Run 'oc login' before continuing."
}

aro_confirm() {
    local prompt=$1
    local expected=$2
    local answer

    if [[ ${ARO_ASSUME_YES:-0} == 1 ]]; then
        return 0
    fi

    read -r -p "$prompt Type '$expected' to continue: " answer
    [[ "$answer" == "$expected" ]] ||
        aro_die "Confirmation did not match. No changes were made."
}

aro_az_provider_register() {
    local provider
    for provider in "$@"; do
        aro_log INFO "Ensuring Azure resource provider is registered: $provider"
        az provider register --namespace "$provider" --wait --only-show-errors -o none
        [[ "$(az provider show --namespace "$provider" --query registrationState -o tsv)" == "Registered" ]] ||
            aro_die "Azure resource provider is not registered: $provider"
    done
}

aro_aro_exists() {
    local cluster=$1
    local resource_group=$2
    [[ "$(az aro show --name "$cluster" --resource-group "$resource_group" --query name -o tsv 2>/dev/null)" == "$cluster" ]]
}

aro_add_path_once() {
    local directory=$1
    case ":${PATH}:" in
        *:"$directory":*) ;;
        *) PATH="${PATH}:$directory"; export PATH ;;
    esac
}
