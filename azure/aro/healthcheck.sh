#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

usage() {
    cat <<'USAGE'
Usage: healthcheck.sh [--attempts COUNT] [--retry-delay SECONDS]

Required environment:
  PROJECT_CPD_INST_OPERANDS
  CPD_CLI_DIR, unless CPD_CLI is set

Authentication must already exist in the current oc context, or use
OCP_URL with OCP_TOKEN or OCP_USERNAME/OCP_PASSWORD. Notification is
disabled unless NOTIFY_EMAILS and SMTP_SERVER are supplied.
USAGE
}

MAX_ATTEMPTS=${HEALTHCHECK_ATTEMPTS:-5}
RETRY_DELAY=${HEALTHCHECK_RETRY_DELAY:-120}
OC_BIN=${OC_BIN:-oc}
CPD_CLI=${CPD_CLI:-}
PROJECT_CPD_INST_OPERANDS=${PROJECT_CPD_INST_OPERANDS:-}
PROJECT_CPD_INST_OPERATORS=${PROJECT_CPD_INST_OPERATORS:-}
EDB_CLUSTER_NAME=${EDB_CLUSTER_NAME:-zen-metastore-edb}
LOG_DIR=${LOG_DIR:-/tmp/aro-healthcheck}
LOG_FILE=${LOG_FILE:-}
OCP_URL=${OCP_URL:-}
OCP_TOKEN=${OCP_TOKEN:-}
OCP_USERNAME=${OCP_USERNAME:-}
OCP_PASSWORD=${OCP_PASSWORD:-}
NOTIFY_EMAILS=${NOTIFY_EMAILS:-}
SMTP_SERVER=${SMTP_SERVER:-}

while (($#)); do
    case $1 in
        --attempts) MAX_ATTEMPTS=${2:?Missing value for --attempts}; shift 2 ;;
        --retry-delay) RETRY_DELAY=${2:?Missing value for --retry-delay}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; aro_die "Unknown argument: $1" ;;
    esac
done

[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$RETRY_DELAY" =~ ^[0-9]+$ ]] ||
    aro_die "Attempts and retry delay must be non-negative integers."
[[ -n "$PROJECT_CPD_INST_OPERANDS" ]] ||
    { usage >&2; aro_die "PROJECT_CPD_INST_OPERANDS is required."; }
if [[ -z "$CPD_CLI" ]]; then
    [[ -n "${CPD_CLI_DIR:-}" ]] ||
        { usage >&2; aro_die "Set CPD_CLI or CPD_CLI_DIR."; }
    CPD_CLI="$CPD_CLI_DIR/cpd-cli"
fi

aro_require_cmd "$OC_BIN"
aro_require_cmd jq
aro_require_cmd awk
aro_require_file "$CPD_CLI"
mkdir -p "$LOG_DIR"
[[ -n "$LOG_FILE" ]] || LOG_FILE="$LOG_DIR/healthcheck_$(date -u +%Y%m%dT%H%M%SZ).log"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; aro_log ERROR "Health check failed at line $LINENO (exit $rc)"; exit "$rc"' ERR

log_message() {
    aro_log "$2" "$1"
}

send_mail_notification() {
    local subject=$1
    [[ -n "$NOTIFY_EMAILS" && -n "$SMTP_SERVER" ]] || return 0
    aro_require_cmd mailx
    aro_require_cmd tar
    local archive="$LOG_FILE.tar.gz"
    local -a recipients
    read -r -a recipients <<< "$NOTIFY_EMAILS"
    tar -czf "$archive" -C "$(dirname -- "$LOG_FILE")" "$(basename -- "$LOG_FILE")"
    mailx -S "smtp=$SMTP_SERVER" -s "$subject" -a "$archive" "${recipients[@]}" < "$LOG_FILE" || \
        log_message "Email notification failed." WARNING
}

cluster_login() {
    log_message "Validating OpenShift authentication." INFO
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

get_cr_status() {
    local raw_json
    local raw_output
    local failed=0
    local seen=0
    raw_output="$(mktemp)"
    raw_json="$(mktemp)"
    trap 'rm -f -- "$raw_output" "$raw_json"' RETURN

    if ! "$CPD_CLI" manage get-cr-status \
        --cpd_instance_ns="$PROJECT_CPD_INST_OPERANDS" > "$raw_output" 2>&1; then
        log_message "cpd-cli get-cr-status failed: $(tail -n 10 "$raw_output")" ERROR
        return 1
    fi
    awk '
        /Output the result in the JSON format:/ { capture=1; next }
        capture && /^\[/ { exit }
        capture { print }
    ' "$raw_output" > "$raw_json"
    jq -e . "$raw_json" >/dev/null ||
        { log_message "cpd-cli did not return valid CR status JSON." ERROR; return 1; }

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

    ((seen > 0)) || { log_message "No CR statuses were returned." ERROR; return 1; }
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

zen_metastore_edb_status() {
    log_message "Checking $EDB_CLUSTER_NAME cluster state." INFO
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

check_once() {
    get_cr_status && get_pod_status && zen_metastore_edb_status
}

main() {
    log_message "Starting ARO CPD health check." INFO
    cluster_login

    local attempt
    for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
        if check_once; then
            log_message "Health check succeeded on attempt $attempt." INFO
            return 0
        fi
        log_message "Health check failed on attempt $attempt of $MAX_ATTEMPTS." WARNING
        if ((attempt < MAX_ATTEMPTS)); then
            sleep "$RETRY_DELAY"
        fi
    done

    send_mail_notification "ARO health check failed"
    return 1
}

main "$@"
