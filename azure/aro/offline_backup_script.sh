#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: offline_backup_script.sh [--allow-data-refinery-mutation] [--skip-mail]

Required environment:
  OCP_URL, OCP_TOKEN or OCP_USERNAME/OCP_PASSWORD
  PROJECT_CPD_INST_OPERANDS, PROJECT_CPD_INST_OPERATORS
  CPD_CLI_DIR or CPD_CLI
  CPD_OPERATORS_BACKUP_CMD

Optional environment:
  BACKUP_DIR_PATH=/var/lib/aro-offline-backup
  OC_BIN=oc
  BACKUP_WAIT_TIMEOUT=900
  POST_BACKUP_HEALTH_DELAY=600
  NOTIFY_EMAILS and SMTP_SERVER

The data-refinery deletion/scale-down workflow is disabled by default.
Enable it only after reviewing the workload-specific impact.
USAGE
}

ALLOW_DATA_REFINERY_MUTATION=0
SKIP_MAIL=0
while (($#)); do
    case $1 in
        --allow-data-refinery-mutation) ALLOW_DATA_REFINERY_MUTATION=1; shift ;;
        --skip-mail) SKIP_MAIL=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

OC_BIN=${OC_BIN:-oc}
CPD_CLI=${CPD_CLI:-}
PROJECT_CPD_INST_OPERANDS=${PROJECT_CPD_INST_OPERANDS:-}
PROJECT_CPD_INST_OPERATORS=${PROJECT_CPD_INST_OPERATORS:-}
EDB_CLUSTER_NAME=${EDB_CLUSTER_NAME:-zen-metastore-edb}
OCP_URL=${OCP_URL:-}
OCP_TOKEN=${OCP_TOKEN:-}
OCP_USERNAME=${OCP_USERNAME:-}
OCP_PASSWORD=${OCP_PASSWORD:-}
BACKUP_DIR_PATH=${BACKUP_DIR_PATH:-/var/lib/aro-offline-backup}
BACKUP_WAIT_TIMEOUT=${BACKUP_WAIT_TIMEOUT:-900}
POST_BACKUP_HEALTH_DELAY=${POST_BACKUP_HEALTH_DELAY:-600}
CPD_OPERATORS_BACKUP_CMD=${CPD_OPERATORS_BACKUP_CMD:-}
NOTIFY_EMAILS=${NOTIFY_EMAILS:-}
SMTP_SERVER=${SMTP_SERVER:-}

[[ -n "$PROJECT_CPD_INST_OPERANDS" && -n "$PROJECT_CPD_INST_OPERATORS" ]] ||
    { usage >&2; aro_die "Both CPD operand and operator namespaces are required."; }
[[ -n "$CPD_CLI" ]] || {
    [[ -n "${CPD_CLI_DIR:-}" ]] ||
        { usage >&2; aro_die "Set CPD_CLI or CPD_CLI_DIR."; }
    CPD_CLI="$CPD_CLI_DIR/cpd-cli"
}
[[ -x "$CPD_CLI" ]] || aro_die "CPD CLI is not executable: $CPD_CLI"
[[ -n "$CPD_OPERATORS_BACKUP_CMD" && -x "$CPD_OPERATORS_BACKUP_CMD" ]] ||
    aro_die "CPD_OPERATORS_BACKUP_CMD must point to an executable backup helper."
[[ "$BACKUP_WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ && "$POST_BACKUP_HEALTH_DELAY" =~ ^[0-9]+$ ]] ||
    aro_die "Backup timeout values must be non-negative integers."

aro_require_cmd "$OC_BIN"
aro_require_cmd jq
aro_require_cmd awk
aro_require_cmd tar
mkdir -p "$BACKUP_DIR_PATH"
LOG_FILE=${LOG_FILE:-"$BACKUP_DIR_PATH/backup_log_$(date -u +%Y%m%dT%H%M%SZ).txt"}
touch "$LOG_FILE"
TEMP_DIR="$(mktemp -d)"
POSTHOOK_REQUIRED=0
DATA_REFINERY_CHANGED=0
DATA_REFINERY_STATE="$TEMP_DIR/data-refinery-state.tsv"
trap 'rc=$?; set +e; if ((POSTHOOK_REQUIRED)); then run_posthook || rc=1; fi; restore_data_refinery || rc=1; rm -rf -- "$TEMP_DIR"; exit "$rc"' EXIT
trap 'rc=$?; aro_log ERROR "Backup failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
exec > >(tee -a "$LOG_FILE") 2>&1

log_message() {
    aro_log "$2" "$1"
}

send_mail_notification() {
    local subject=$1
    ((SKIP_MAIL)) && return 0
    [[ -n "$NOTIFY_EMAILS" && -n "$SMTP_SERVER" ]] || return 0
    aro_require_cmd mailx
    local archive="$LOG_FILE.tar.gz"
    local -a recipients
    read -r -a recipients <<< "$NOTIFY_EMAILS"
    tar -czf "$archive" -C "$(dirname -- "$LOG_FILE")" "$(basename -- "$LOG_FILE")"
    mailx -S "smtp=$SMTP_SERVER" -s "$subject" -a "$archive" "${recipients[@]}" < "$LOG_FILE" || \
        log_message "Email notification failed." WARNING
}

cluster_login() {
    if [[ -n "$OCP_TOKEN" ]]; then
        [[ -n "$OCP_URL" ]] || aro_die "OCP_URL is required with OCP_TOKEN."
        "$OC_BIN" login --server "$OCP_URL" --token "$OCP_TOKEN" >/dev/null
    elif [[ -n "$OCP_USERNAME" || -n "$OCP_PASSWORD" ]]; then
        [[ -n "$OCP_URL" && -n "$OCP_USERNAME" && -n "$OCP_PASSWORD" ]] ||
            aro_die "OCP_URL, OCP_USERNAME, and OCP_PASSWORD must be provided together."
        "$OC_BIN" login --server "$OCP_URL" --username "$OCP_USERNAME" \
            --password "$OCP_PASSWORD" >/dev/null
    else
        "$OC_BIN" whoami >/dev/null
    fi
    log_message "OpenShift authentication is valid for $("$OC_BIN" whoami)." INFO
}

cpd_login() {
    if [[ -n "$OCP_USERNAME" && -n "$OCP_PASSWORD" ]]; then
        [[ -n "$OCP_URL" ]] || aro_die "OCP_URL is required for CPD CLI login."
        "$CPD_CLI" manage login-to-ocp --server "$OCP_URL" \
            --username "$OCP_USERNAME" --password "$OCP_PASSWORD" >/dev/null
    else
        log_message "Skipping CPD CLI login; using the existing CPD CLI session." WARNING
    fi
}

get_cr_status() {
    local raw_output
    local raw_json
    local failed=0
    local seen=0
    raw_output="$(mktemp)"
    raw_json="$(mktemp)"
    if ! "$CPD_CLI" manage get-cr-status \
        --cpd_instance_ns="$PROJECT_CPD_INST_OPERANDS" > "$raw_output" 2>&1; then
        log_message "cpd-cli get-cr-status failed: $(tail -n 10 "$raw_output")" ERROR
        rm -f -- "$raw_output" "$raw_json"
        return 1
    fi
    awk '
        /Output the result in the JSON format:/ { capture=1; next }
        capture && /^\[/ { exit }
        capture { print }
    ' "$raw_output" > "$raw_json"
    if ! jq -e . "$raw_json" >/dev/null; then
        log_message "cpd-cli did not return valid CR status JSON." ERROR
        rm -f -- "$raw_output" "$raw_json"
        return 1
    fi
    while IFS=$'\t' read -r cr_name status; do
        [[ -n "$cr_name" ]] || continue
        seen=$((seen + 1))
        if [[ "$status" == "Completed" || "$status" == "Succeeded" ]]; then
            log_message "$cr_name is complete: $status" INFO
        else
            log_message "$cr_name is not complete: $status" ERROR
            failed=1
        fi
    done < <(jq -r '.[] | .[] | [."CR-name", (.Status // "")] | @tsv' "$raw_json")
    rm -f -- "$raw_output" "$raw_json"
    ((seen > 0)) || return 1
    return "$failed"
}

get_pod_status() {
    local output
    output="$("$OC_BIN" get pods --all-namespaces --no-headers | awk '
        $2 !~ /env-spec-sync-job/ {
            split($3, ready, "/")
            if ($4 !~ /^(Running|Completed|Succeeded)$/ || ready[1] != ready[2]) print
        }
    ')"
    if [[ -z "$output" ]]; then
        log_message "All pods are ready or completed." INFO
        return 0
    fi
    log_message "Non-ready pods detected:\n$output" ERROR
    return 1
}

get_cluster_status() {
    get_cr_status && get_pod_status
}

zen_metastore_edb_status() {
    local status
    status="$("$OC_BIN" cnp status "$EDB_CLUSTER_NAME" \
        --namespace "$PROJECT_CPD_INST_OPERANDS" --verbose)"
    if [[ "$status" == *"Cluster in healthy state"* ]]; then
        log_message "$EDB_CLUSTER_NAME is healthy." INFO
        return 0
    fi
    log_message "$EDB_CLUSTER_NAME is unhealthy." ERROR
    return 1
}

pod_sts_deploy_backup() {
    local backup_dir="$BACKUP_DIR_PATH/offline-backup-$(date -u +%Y%m%d)"
    mkdir -p "$backup_dir"
    log_message "Writing Kubernetes inventory to $backup_dir." INFO
    "$OC_BIN" get sts,deploy -n "$PROJECT_CPD_INST_OPERANDS" \
        > "$backup_dir/sts_deploy.cpd.$(date -u +%H%M%S).out"
    "$OC_BIN" get sts,deploy,cj -n "$PROJECT_CPD_INST_OPERATORS" \
        > "$backup_dir/sts_deploy.operators.$(date -u +%H%M%S).out"
    "$OC_BIN" get cj,po,pvc -n "$PROJECT_CPD_INST_OPERANDS" \
        > "$backup_dir/resources.cpd.$(date -u +%H%M%S).out"
}

data_refinery_jobs() {
    if (( ! ALLOW_DATA_REFINERY_MUTATION )); then
        log_message "Data-refinery mutation is disabled; no workloads were deleted or scaled." INFO
        return 0
    fi
    : > "$DATA_REFINERY_STATE"
    DATA_REFINERY_CHANGED=1
    for deployment in wdp-shaper wdp-dataprep; do
        if replicas="$("$OC_BIN" get deployment "$deployment" -n "$PROJECT_CPD_INST_OPERANDS" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null)"; then
            printf '%s\t%s\n' "$deployment" "${replicas:-1}" >> "$DATA_REFINERY_STATE"
            "$OC_BIN" scale deployment "$deployment" -n "$PROJECT_CPD_INST_OPERANDS" --replicas=0
        fi
    done
    for kind in deployment service job secret cronjob; do
        while IFS= read -r resource; do
            [[ -n "$resource" ]] || continue
            "$OC_BIN" delete "$resource" --namespace "$PROJECT_CPD_INST_OPERANDS" \
                --ignore-not-found --wait=false
        done < <("$OC_BIN" get "$kind" -n "$PROJECT_CPD_INST_OPERANDS" \
            -l type=shaper -o name)
    done
}

restore_data_refinery() {
    ((DATA_REFINERY_CHANGED)) || return 0
    [[ -f "$DATA_REFINERY_STATE" ]] || return 0
    while IFS=$'\t' read -r deployment replicas; do
        [[ -n "$deployment" ]] || continue
        "$OC_BIN" scale deployment "$deployment" -n "$PROJECT_CPD_INST_OPERANDS" \
            --replicas="$replicas" || log_message "Unable to restore $deployment to $replicas replicas." ERROR
    done < "$DATA_REFINERY_STATE"
    DATA_REFINERY_CHANGED=0
}

backup_cpd_operators_configmap() {
    log_message "Generating the CPD operators backup configuration." INFO
    "$CPD_OPERATORS_BACKUP_CMD" backup \
        --foundation-namespace "$PROJECT_CPD_INST_OPERATORS" \
        --operators-namespace "$PROJECT_CPD_INST_OPERATORS" --backup-iam-data
}

wait_for_backup() {
    local backup_name=$1
    local deadline=$((SECONDS + BACKUP_WAIT_TIMEOUT))
    local status
    while ((SECONDS < deadline)); do
        status="$("$CPD_CLI" oadp backup list | awk -v name="$backup_name" '$0 ~ name {print $2; exit}')"
        case "$status" in
            Completed) return 0 ;;
            Failed|PartiallyFailed) return 1 ;;
        esac
        sleep 15
    done
    return 1
}

backup_cpd_operators_edb_postgres() {
    local backup_name="offline-operators-edb-$(date -u +%Y%m%d%H%M%S)"
    log_message "Creating backup $backup_name." INFO
    "$CPD_CLI" oadp backup create "$backup_name" \
        --tenant-operator-namespace "$PROJECT_CPD_INST_OPERATORS" \
        --include-resources='namespaces,operatorgroups,roles,rolebindings,serviceaccounts,customresourcedefinitions.apiextensions.k8s.io,securitycontextconstraints.security.openshift.io,configmaps,namespacescopes,commonservices,clusters.postgresql.k8s.enterprisedb.io' \
        --skip-hooks --log-level=debug --verbose
    wait_for_backup "$backup_name"
}

run_prehook() {
    log_message "Starting CPD prehook." INFO
    if ! "$CPD_CLI" oadp backup prehooks \
        --tenant-operator-namespace "$PROJECT_CPD_INST_OPERATORS" --log-level=debug --verbose; then
        log_message "Prehook failed; retrying once." WARNING
        "$CPD_CLI" oadp backup prehooks \
            --tenant-operator-namespace "$PROJECT_CPD_INST_OPERATORS" --log-level=debug --verbose
    fi
}

backup_kubernetes_resources() {
    local backup_name="offline-resources-$(date -u +%Y%m%d%H%M%S)"
    log_message "Creating resource and volume backup $backup_name." INFO
    "$CPD_CLI" oadp backup create "$backup_name" \
        --tenant-operator-namespace "$PROJECT_CPD_INST_OPERATORS" \
        --exclude-tenant-operator-namespace=true \
        --exclude-resources='event,event.events.k8s.io,imagetags.openshift.io,operatorgroups,roles,rolebindings,serviceaccounts,customresourcedefinitions.apiextensions.k8s.io,securitycontextconstraints.security.openshift.io,catalogsources.operators.coreos.com,subscriptions.operators.coreos.com,clusterserviceversions.operators.coreos.com,installplans.operators.coreos.com,operandconfig,operandregistry,operandrequest,clients.oidc.security.ibm.com,authentication.operator.ibm.com,namespacescopes,commonservices,clusters.postgresql.k8s.enterprisedb.io,certificaterequests.cert-manager.io,orders.acme.cert-manager.io,challenges.acme.cert-manager.io' \
        --default-volumes-to-restic --snapshot-volumes=false --skip-hooks \
        --cleanup-completed-resources --vol-mnt-pod-mem-request=1Gi \
        --vol-mnt-pod-mem-limit=4Gi --wait-timeout=15m --log-level=debug --verbose
    wait_for_backup "$backup_name"
}

run_posthook() {
    log_message "Starting CPD posthook." INFO
    "$CPD_CLI" oadp backup posthooks \
        --tenant-operator-namespace "$PROJECT_CPD_INST_OPERATORS" --log-level=debug --verbose
    POSTHOOK_REQUIRED=0
}

main() {
    log_message "Starting CPD offline backup." INFO
    cluster_login
    cpd_login
    get_cluster_status
    zen_metastore_edb_status
    pod_sts_deploy_backup
    data_refinery_jobs
    backup_cpd_operators_configmap
    backup_cpd_operators_edb_postgres
    POSTHOOK_REQUIRED=1
    run_prehook
    backup_kubernetes_resources
    run_posthook
    restore_data_refinery
    if ((POST_BACKUP_HEALTH_DELAY > 0)); then
        sleep "$POST_BACKUP_HEALTH_DELAY"
    fi
    get_cluster_status
    zen_metastore_edb_status
    log_message "CPD offline backup completed successfully." INFO
}

main "$@"
