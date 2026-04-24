#!/usr/bin/env bash
# Operator installation and management

approve_all_install_plans() {
    log_info "Approving all pending install plans"
    local count=0
    while IFS='/' read -r ns name; do
        [[ -z "$ns" ]] && continue
        spoke_oc patch installplan "$name" -n "$ns" --type=merge \
            -p '{"spec":{"approved":true}}' 2>/dev/null && count=$((count + 1))
    done < <(spoke_oc get installplan -A --no-headers 2>/dev/null \
        | grep "false$" | awk '{print $1"/"$2}')
    log_info "Approved $count install plans"
}

wait_for_operators() {
    local timeout="${1:-300}"
    log_info "Waiting for LCA and OADP operators"

    wait_for "$timeout" 15 "LCA CSV Succeeded" \
        bash -c "spoke_oc get csv -n openshift-lifecycle-agent --no-headers 2>/dev/null | grep -q Succeeded"

    wait_for "$timeout" 15 "OADP CSV Succeeded" \
        bash -c "spoke_oc get csv -n openshift-adp --no-headers 2>/dev/null | grep -q Succeeded"

    log_info "LCA and OADP operators ready"
}

create_sriov_operator_config() {
    log_info "Creating SriovOperatorConfig"
    spoke_oc apply -f "${SCRIPT_DIR}/manifests/sriov-operator-config.yaml"
}

wait_for_sriov_nodestate() {
    local timeout="${1:-180}"
    log_info "Waiting for SriovNetworkNodeState"
    wait_for "$timeout" 15 "SRIOV NodeState exists" \
        bash -c '[[ -n "$(spoke_oc get sriovnetworknodestates -A --no-headers 2>/dev/null)" ]]'
    log_info "SriovNetworkNodeState present"
}

verify_lca_image() {
    local actual
    actual=$(spoke_oc get pods -n openshift-lifecycle-agent \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
    if [[ "$actual" == "$LCA_IMAGE" ]]; then
        log_info "LCA running expected image: $actual"
    else
        log_warn "LCA image mismatch: expected=$LCA_IMAGE actual=$actual"
    fi
}

setup_spoke_operators() {
    approve_all_install_plans
    sleep 30
    approve_all_install_plans

    wait_for_operators
    create_sriov_operator_config

    sleep 60
    wait_for_sriov_nodestate
    fix_monitoring_secrets
    wait_for_healthy_cluster

    verify_lca_image
    log_info "Spoke operators fully configured"
}
