#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro4-rotatespkey.sh --name CLUSTER --resource-group RESOURCE_GROUP
                           [--valid-years YEARS] [--yes] [--dry-run]

Appends a new service-principal credential, updates ARO to use it, and leaves
existing credentials in place. The generated secret is never printed.
USAGE
}

CLUSTER=${ARO_CLUSTER_NAME:-}
RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-}
VALID_YEARS=${ARO_SP_VALID_YEARS:-2}
DRY_RUN=0
export ARO_ASSUME_YES=0

while (($#)); do
    case $1 in
        --name|-n) CLUSTER=${2:?Missing value for --name}; shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP=${2:?Missing value for --resource-group}; shift 2 ;;
        --valid-years) VALID_YEARS=${2:?Missing value for --valid-years}; shift 2 ;;
        --yes) ARO_ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER" && -n "$RESOURCE_GROUP" ]] ||
    { usage >&2; aro_die "Both --name and --resource-group are required."; }
[[ "$VALID_YEARS" =~ ^[1-9][0-9]*$ && "$VALID_YEARS" -le 250 ]] ||
    aro_die "--valid-years must be an integer from 1 through 250."

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_azure_login
aro_aro_exists "$CLUSTER" "$RESOURCE_GROUP" ||
    aro_die "ARO cluster '$CLUSTER' was not found in resource group '$RESOURCE_GROUP'."

SP_APP_ID="$(az aro show --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query servicePrincipalProfile.clientId -o tsv --only-show-errors)"
[[ -n "$SP_APP_ID" ]] || aro_die "The ARO service-principal client ID could not be read."

EXPIRING="$(az ad sp credential list --id "$SP_APP_ID" \
    --query '[].endDate' -o tsv --only-show-errors || true)"
aro_log INFO "Service-principal client ID: $SP_APP_ID"
aro_log INFO "Existing credential expiry values: ${EXPIRING:-none reported}"

if ((DRY_RUN)); then
    aro_log INFO "Dry run complete. No credential or ARO changes were made."
    exit 0
fi

aro_confirm "Append a new ARO service-principal credential for '$CLUSTER'?" "ROTATE $CLUSTER"
aro_require_cmd jq
aro_require_cmd date

END_DATE="$(date -u -d "+$VALID_YEARS years" '+%Y-%m-%dT%H:%M:%SZ')"
DESCRIPTION="aro-rotation-$(date -u '+%Y%m%dT%H%M%SZ')"

aro_log INFO "Appending a new service-principal credential expiring at $END_DATE."
NEW_CREDENTIAL_JSON="$(az ad sp credential reset --id "$SP_APP_ID" --append \
    --end-date "$END_DATE" --display-name "$DESCRIPTION" -o json --only-show-errors)"
NEW_KEY_ID="$(jq -r '.keyId // empty' <<< "$NEW_CREDENTIAL_JSON")"
NEW_SECRET="$(jq -r '.password // empty' <<< "$NEW_CREDENTIAL_JSON")"
[[ -n "$NEW_KEY_ID" ]] || aro_die "Azure did not return the new credential key ID."
[[ -n "$NEW_SECRET" ]] || aro_die "Azure did not return the new credential secret."

if ! az aro update --name "$CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --client-id "$SP_APP_ID" --client-secret "$NEW_SECRET" \
    --only-show-errors -o none; then
    aro_log ERROR "ARO update failed. The new credential remains appended; do not revoke it until ARO is updated."
    exit 1
fi

aro_log INFO "ARO now uses the new service-principal credential (key ID $NEW_KEY_ID)."
aro_log WARNING "Revoke the old credential only after monitoring confirms the cluster is healthy."
