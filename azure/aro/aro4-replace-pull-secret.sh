#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro4-replace-pull-secret.sh --file PULL_SECRET_JSON [--dry-run]

Merges the supplied Docker config JSON into the OpenShift pull-secret and
removes the legacy cloud.openshift.com entry. The existing secret is never
written to the working directory.
USAGE
}

INPUT_FILE=
DRY_RUN=0
while (($#)); do
    case $1 in
        --file|-f) INPUT_FILE=${2:?Missing value for --file}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ -n "$INPUT_FILE" ]] || { usage >&2; aro_die "--file is required."; }

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_oc_login
aro_require_cmd jq
aro_require_cmd base64
aro_require_file "$INPUT_FILE"
jq -e 'type == "object"' "$INPUT_FILE" >/dev/null ||
    aro_die "Pull-secret input is not valid JSON."

CAN_UPDATE="$(oc auth can-i update secret/pull-secret -n openshift-config)"
[[ "$CAN_UPDATE" == "yes" ]] ||
    aro_die "The current OpenShift identity cannot update the openshift-config/pull-secret."

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
chmod 700 "$TEMP_DIR"
EXISTING="$TEMP_DIR/existing.json"
MERGED="$TEMP_DIR/merged.json"

oc get secret pull-secret -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' |
    base64 --decode > "$EXISTING"
jq -e 'type == "object"' "$EXISTING" >/dev/null ||
    aro_die "The existing OpenShift pull-secret is not valid Docker config JSON."

jq -s '.[0] * .[1]' "$EXISTING" "$INPUT_FILE" |
    jq 'del(.. | objects | ."cloud.openshift.com"?)' > "$MERGED"
jq -e 'type == "object"' "$MERGED" >/dev/null ||
    aro_die "The merged pull-secret is not valid Docker config JSON."

if ((DRY_RUN)); then
    aro_log INFO "Pull-secret merge validated; no cluster changes were made."
    oc set data secret/pull-secret -n openshift-config \
        --from-file=".dockerconfigjson=$MERGED" --dry-run=client -o yaml >/dev/null
else
    aro_confirm "Update the cluster pull-secret?" "UPDATE"
    oc set data secret/pull-secret -n openshift-config \
        --from-file=".dockerconfigjson=$MERGED" >/dev/null
    aro_log INFO "OpenShift pull-secret updated successfully."
fi
