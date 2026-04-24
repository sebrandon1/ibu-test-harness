# shellcheck shell=bash
# Spoke cluster operations

wait_for_healthy_cluster() {
    local timeout="${1:-600}"
    log_info "Waiting for all ClusterOperators to be healthy"
    wait_for "$timeout" 15 "all COs healthy" \
        bash -c '[[ -z "$(spoke_oc get co --no-headers 2>/dev/null | grep -v "True.*False.*False")" ]]'
    log_info "All ClusterOperators healthy"
}

fix_monitoring_secrets() {
    fix_monitoring_on spoke_oc
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
