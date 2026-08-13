#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: aro4-applysc.sh [--dry-run] [STORAGE_CLASS_YAML ...]

Applies storage-class manifests to the current OpenShift context. When no
files are supplied, the three historical manifest names are used.
USAGE
}

DRY_RUN=0
FILES=()
while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --) shift; FILES+=($@); break ;;
        -*) usage >&2; aro_die "Unknown argument: $1" ;;
        *) FILES+=($1); shift ;;
    esac
done

if ((${#FILES[@]} == 0)); then
    FILES=(managed-std-hdd.yaml managed-std-ssd.yaml managed-ultra-ssd.yaml)
fi

trap 'rc=$?; aro_log ERROR "Command failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
aro_require_oc_login

for file in "${FILES[@]}"; do
    aro_require_file "$file"
    if ((DRY_RUN)); then
        aro_log INFO "Validating storage-class manifest: $file"
        oc apply --dry-run=server --filename "$file" >/dev/null
    else
        aro_log INFO "Applying storage-class manifest: $file"
        oc apply --server-side --field-manager=aro-scripts --filename "$file"
    fi
done

aro_log INFO "Current storage classes:"
oc get storageclass
