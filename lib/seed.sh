# shellcheck shell=bash
# Seed image generation

detach_seed_from_hub() {
    log_info "Detaching seed cluster $SEED_NAME from hub"
    hub_oc delete managedcluster "$SEED_NAME" --wait=false 2>/dev/null || true

    wait_for 120 10 "klusterlet removed" \
        bash -c '! seed_oc get pods -n open-cluster-management-agent --no-headers 2>/dev/null | grep -q .'

    log_info "Seed cluster detached"
}

deploy_lca_direct() {
    log_info "Deploying LCA directly on seed cluster via kustomize (bypassing OLM)"

    local lca_dir="$LCA_REPO_PATH"
    if [[ -z "$lca_dir" || ! -d "$lca_dir" ]]; then
        log_error "LCA_REPO_PATH not set or not a directory: $lca_dir"
        return 1
    fi

    kustomize build "$lca_dir/config/default" | seed_oc apply --server-side -f -

    wait_for 120 10 "LCA pod Running on seed" \
        bash -c 'seed_oc get pods -n openshift-lifecycle-agent --no-headers 2>/dev/null | grep -q Running'

    log_info "LCA deployed on seed cluster"
}

create_seedgen_secret() {
    log_info "Creating seedgen auth secret on seed cluster"
    local auth_file="${CONTAINER_AUTH_FILE:-${HOME}/.config/containers/auth.json}"

    if [[ ! -f "$auth_file" ]]; then
        log_error "Container auth file not found: $auth_file"
        return 1
    fi

    seed_oc delete secret seedgen -n openshift-lifecycle-agent --ignore-not-found
    seed_oc create secret generic seedgen \
        --from-file=seedAuth="$auth_file" \
        -n openshift-lifecycle-agent
}

fix_seed_monitoring() {
    fix_monitoring_on seed_oc

    wait_for 180 15 "monitoring CO available on seed" \
        bash -c '[[ "$(seed_oc get co monitoring -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null)" == "True" ]]'
}

generate_seed_image() {
    log_info "Starting seed image generation on $SEED_NAME"

    seed_oc apply -f - <<EOF
apiVersion: lca.openshift.io/v1
kind: SeedGenerator
metadata:
  name: seedimage
spec:
  seedImage: ${SEED_IMAGE}
  recertImage: ${RECERT_IMAGE}
EOF

    log_info "Waiting for seed generation (this takes 20-40 minutes)"

    local timeout=3600
    local deadline=$(($(date +%s) + timeout))

    while (($(date +%s) < deadline)); do
        local status
        status=$(seed_oc get seedgenerators seedimage \
            -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null)

        if [[ -z "$status" ]]; then
            log_info "Seed: API not available (node rebooting for seed capture)"
            sleep 60
            continue
        fi

        if echo "$status" | grep -q "SeedGenCompleted: True"; then
            log_info "Seed image generation completed"
            return 0
        fi

        if echo "$status" | grep -q "SeedGenCompleted: False.*Failed"; then
            local msg
            msg=$(echo "$status" | grep "SeedGenCompleted" | head -1)
            log_error "Seed generation failed: $msg"
            return 1
        fi

        local progress
        progress=$(echo "$status" | grep "SeedGenInProgress" | sed 's/SeedGenInProgress: True - //' | head -1)
        [[ -n "$progress" ]] && log_info "Seed: $progress"

        sleep 30
    done

    log_error "Seed generation timed out"
    return 1
}

verify_seed_image() {
    log_info "Verifying seed image exists in registry"
    if skopeo inspect --no-creds "docker://${SEED_IMAGE}" &>/dev/null; then
        log_info "Seed image verified: $SEED_IMAGE"
    else
        skopeo inspect --authfile="${CONTAINER_AUTH_FILE:-${HOME}/.config/containers/auth.json}" \
            "docker://${SEED_IMAGE}" &>/dev/null || {
            log_error "Seed image not found: $SEED_IMAGE"
            return 1
        }
        log_info "Seed image verified (private): $SEED_IMAGE"
    fi
}

run_seed_generation() {
    fetch_seed_kubeconfig
    detach_seed_from_hub
    fix_seed_monitoring
    deploy_lca_direct
    create_seedgen_secret
    generate_seed_image
    verify_seed_image
}
