#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $(date -u +%H:%M:%S) $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(date -u +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date -u +%H:%M:%S) $*" >&2; }

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

duration_seconds() {
    local start="$1" end="$2"
    local s e
    if date --version &>/dev/null; then
        s=$(date -d "$start" +%s)
        e=$(date -d "$end" +%s)
    else
        s=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$start" +%s 2>/dev/null || date -jf '%Y-%m-%dT%T' "${start%Z}" +%s)
        e=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$end" +%s 2>/dev/null || date -jf '%Y-%m-%dT%T' "${end%Z}" +%s)
    fi
    echo $((e - s))
}

format_duration() {
    local secs="$1"
    printf '%dm%02ds' $((secs / 60)) $((secs % 60))
}

# Generic polling function.
# Usage: wait_for <timeout_sec> <interval_sec> <description> <command...>
wait_for() {
    local timeout="$1" interval="$2" desc="$3"
    shift 3
    local deadline=$(($(date +%s) + timeout))
    while true; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        if (($(date +%s) >= deadline)); then
            log_error "Timed out after ${timeout}s waiting for: $desc"
            return 1
        fi
        sleep "$interval"
    done
}

hub_oc() {
    oc --server="$HUB_API" --insecure-skip-tls-verify=true "$@"
}
export -f hub_oc

spoke_oc() {
    oc --kubeconfig="$SPOKE_KUBECONFIG" --insecure-skip-tls-verify=true "$@"
}
export -f spoke_oc

seed_oc() {
    oc --kubeconfig="$SEED_KUBECONFIG" --insecure-skip-tls-verify=true "$@"
}
export -f seed_oc

fetch_kubeconfig() {
    local name="$1" ns="$2" varname="$3"
    local path="${RESULTS_DIR}/${name}.kubeconfig"
    hub_oc get secret -n "$ns" "${name}-admin-kubeconfig" \
        -o jsonpath='{.data.kubeconfig}' | base64 -d >"$path"
    eval "export ${varname}=${path}"
    log_info "Fetched kubeconfig for $name → $path"
}

fetch_spoke_kubeconfig() {
    fetch_kubeconfig "${1:-$SPOKE_NAME}" "${2:-$SPOKE_NAMESPACE}" SPOKE_KUBECONFIG
}

fetch_seed_kubeconfig() {
    fetch_kubeconfig "${1:-$SEED_NAME}" "${2:-$SEED_NAMESPACE}" SEED_KUBECONFIG
}

# Create dummy monitoring secrets needed after hub detachment.
# Usage: fix_monitoring_on <oc_wrapper_func>
fix_monitoring_on() {
    local oc_fn="$1"
    log_info "Fixing monitoring secrets (hub detachment artifacts)"

    "$oc_fn" create secret generic observability-alertmanager-accessor \
        --from-literal=token=dummy -n openshift-monitoring 2>/dev/null || true

    local ca_cert
    ca_cert=$("$oc_fn" get configmap kube-root-ca.crt -n openshift-monitoring \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "placeholder")
    "$oc_fn" create secret generic hub-alertmanager-router-ca \
        --from-literal=service-ca.crt="$ca_cert" -n openshift-monitoring 2>/dev/null || true

    "$oc_fn" delete pod -n openshift-monitoring -l app.kubernetes.io/name=prometheus \
        --ignore-not-found 2>/dev/null || true
    log_info "Monitoring secrets fixed, prometheus restarted"
}

check_prerequisites() {
    local missing=()
    for cmd in oc "$ENGINE" skopeo kustomize jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ((${#missing[@]} > 0)); then
        log_error "Missing prerequisites: ${missing[*]}"
        return 1
    fi
    log_info "Prerequisites OK: oc, $ENGINE, skopeo, kustomize, jq"
}

hub_login() {
    log_info "Logging into hub at $HUB_API"
    oc login --server="$HUB_API" --username="$HUB_USER" --password="$HUB_PASS" \
        --insecure-skip-tls-verify=true &>/dev/null
    log_info "Hub login successful"
}
