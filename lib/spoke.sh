#!/usr/bin/env bash
# Spoke cluster operations

wait_for_healthy_cluster() {
    local timeout="${1:-600}"
    log_info "Waiting for all ClusterOperators to be healthy"
    wait_for "$timeout" 15 "all COs healthy" \
        bash -c '[[ -z "$(spoke_oc get co --no-headers 2>/dev/null | grep -v "True.*False.*False")" ]]'
    log_info "All ClusterOperators healthy"
}

fix_monitoring_secrets() {
    log_info "Fixing monitoring secrets (hub detachment artifacts)"

    spoke_oc create secret generic observability-alertmanager-accessor \
        --from-literal=token=dummy -n openshift-monitoring 2>/dev/null || true

    local ca_cert
    ca_cert=$(spoke_oc get configmap kube-root-ca.crt -n openshift-monitoring \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "placeholder")
    spoke_oc create secret generic hub-alertmanager-router-ca \
        --from-literal=service-ca.crt="$ca_cert" -n openshift-monitoring 2>/dev/null || true

    spoke_oc delete pod -n openshift-monitoring -l app.kubernetes.io/name=prometheus --ignore-not-found 2>/dev/null || true
    log_info "Monitoring secrets fixed, prometheus restarted"
}

verify_container_storage_mount() {
    log_info "Checking var-lib-containers.mount on spoke"
    local node
    node=$(spoke_oc get nodes --no-headers -o custom-columns='NAME:.metadata.name' | head -1)
    local status
    status=$(spoke_oc debug "node/$node" -- chroot /host systemctl is-active var-lib-containers.mount 2>&1 | grep -E 'active|inactive' | head -1)
    if [[ "$status" == "active" ]]; then
        log_info "Container storage mount is active"
        return 0
    else
        log_error "Container storage mount is NOT active (got: $status)"
        return 1
    fi
}
