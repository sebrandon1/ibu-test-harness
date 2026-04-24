# shellcheck shell=bash
# cert-manager installation and test certificate management

install_certmanager() {
    local timeout="${1:-300}"
    log_info "Installing cert-manager operator"

    spoke_oc apply -f "${SCRIPT_DIR}/manifests/cert-manager-subscription.yaml"

    wait_for "$timeout" 15 "cert-manager CSV Succeeded" \
        bash -c "spoke_oc get csv -n cert-manager-operator --no-headers 2>/dev/null | grep -q Succeeded"

    wait_for "$timeout" 15 "cert-manager pods Running" \
        bash -c '[[ $(spoke_oc get pods -n cert-manager --no-headers 2>/dev/null | grep -c Running) -ge 3 ]]'

    log_info "cert-manager installed and running"
}

create_test_certificates() {
    local timeout="${1:-120}"
    log_info "Creating test certificates"

    local manifest="${SCRIPT_DIR}/manifests/test-certificates.yaml"
    sed "s/\${SPOKE_NAME}/${SPOKE_NAME}/g" "$manifest" | spoke_oc apply -f -

    wait_for "$timeout" 10 "certificates Ready" \
        bash -c '[[ $(spoke_oc get certificates -n test-certs --no-headers 2>/dev/null | grep -c True) -ge 2 ]]'

    log_info "Test certificates created and Ready"
}

record_tls_checksums() {
    local run_label="$1"
    local outfile="${RESULTS_DIR}/checksums-${run_label}.txt"
    log_info "Recording TLS key checksums for $run_label"

    for secret in ibu-test-cert-tls ibu-test-cert-ns-tls; do
        local checksum
        checksum=$(spoke_oc get secret "$secret" -n test-certs \
            -o jsonpath='{.data.tls\.key}' | base64 -d | sha256sum | awk '{print $1}')
        echo "$secret: $checksum" >>"$outfile"
        log_info "  $secret: $checksum"
    done
}

verify_tls_checksums() {
    local run_label="$1"
    local pre_file="${RESULTS_DIR}/checksums-${run_label}-pre.txt"
    local post_file="${RESULTS_DIR}/checksums-${run_label}-post.txt"

    log_info "Verifying TLS key checksums for $run_label"
    local pass=true

    while IFS=': ' read -r secret checksum; do
        local post_checksum
        post_checksum=$(grep "^${secret}:" "$post_file" | awk '{print $2}')
        if [[ "$checksum" == "$post_checksum" ]]; then
            log_info "  $secret: MATCH"
        else
            log_error "  $secret: MISMATCH (pre=$checksum post=$post_checksum)"
            pass=false
        fi
    done <"$pre_file"

    if $pass; then
        log_info "All TLS key checksums match"
        return 0
    else
        log_error "TLS key checksum verification FAILED"
        return 1
    fi
}

setup_certmanager_test() {
    local run_label="$1"
    install_certmanager
    create_test_certificates
    record_tls_checksums "${run_label}-pre"
}
