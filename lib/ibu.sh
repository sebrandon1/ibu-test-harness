# shellcheck shell=bash
# IBU execution and timing

start_prep() {
    log_info "Starting IBU Prep stage"
    spoke_oc patch imagebasedupgrades upgrade --type=merge \
        -p "{\"spec\":{\"seedImageRef\":{\"image\":\"${SEED_IMAGE}\",\"version\":\"${TARGET_VERSION}\"},\"stage\":\"Prep\"}}"
}

wait_for_prep() {
    local timeout="${1:-1800}" run_label="$2"
    local timing_file="${RESULTS_DIR}/timing-${run_label}.txt"

    echo "prep_start=$(timestamp)" >>"$timing_file"

    log_info "Waiting for Prep to complete (timeout: ${timeout}s)"
    local deadline=$(($(date +%s) + timeout))

    while (($(date +%s) < deadline)); do
        local status
        status=$(spoke_oc get imagebasedupgrades upgrade \
            -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null)

        if echo "$status" | grep -q "PrepCompleted: True"; then
            echo "prep_end=$(timestamp)" >>"$timing_file"
            log_info "Prep completed"
            return 0
        fi

        if echo "$status" | grep -q "PrepCompleted: False.*Failed"; then
            local msg
            msg=$(echo "$status" | grep "PrepCompleted" | head -1)
            log_error "Prep failed: $msg"
            return 1
        fi

        local progress
        progress=$(echo "$status" | grep "PrepInProgress" | sed 's/PrepInProgress: True - //' | head -1)
        [[ -n "$progress" ]] && log_info "Prep: $progress"

        sleep 30
    done

    log_error "Prep timed out"
    return 1
}

start_upgrade() {
    log_info "Starting IBU Upgrade stage"
    spoke_oc patch imagebasedupgrades upgrade --type=merge -p '{"spec":{"stage":"Upgrade"}}'
}

wait_for_upgrade() {
    local timeout="${1:-1800}" run_label="$2"
    local timing_file="${RESULTS_DIR}/timing-${run_label}.txt"

    echo "upgrade_start=$(timestamp)" >>"$timing_file"

    log_info "Waiting for Upgrade to complete (timeout: ${timeout}s)"
    local deadline=$(($(date +%s) + timeout))
    local api_went_down=false

    while (($(date +%s) < deadline)); do
        local status
        status=$(spoke_oc get imagebasedupgrades upgrade \
            -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null)

        if [[ -z "$status" ]]; then
            if ! $api_went_down; then
                echo "api_down=$(timestamp)" >>"$timing_file"
                api_went_down=true
                log_info "API not available (node rebooting)"
            fi
            sleep 30
            continue
        fi

        if $api_went_down; then
            echo "api_up=$(timestamp)" >>"$timing_file"
            api_went_down=false
            log_info "API is back"
        fi

        if echo "$status" | grep -q "UpgradeCompleted: True"; then
            echo "upgrade_end=$(timestamp)" >>"$timing_file"
            log_info "Upgrade completed"
            return 0
        fi

        if echo "$status" | grep -q "UpgradeCompleted: False.*Failed"; then
            local msg
            msg=$(echo "$status" | grep "UpgradeCompleted" | head -1)
            log_error "Upgrade failed: $msg"
            return 1
        fi

        local progress
        progress=$(echo "$status" | grep "UpgradeInProgress" | sed 's/UpgradeInProgress: True - //' | head -1)
        [[ -n "$progress" ]] && log_info "Upgrade: $progress"

        sleep 30
    done

    log_error "Upgrade timed out"
    return 1
}

finalize_ibu() {
    local timeout="${1:-600}"
    log_info "Finalizing IBU (returning to Idle)"

    fix_monitoring_secrets
    spoke_oc patch imagebasedupgrades upgrade --type=merge -p '{"spec":{"stage":"Idle"}}'

    wait_for "$timeout" 15 "IBU finalized to Idle" \
        bash -c '[[ "$(spoke_oc get imagebasedupgrades upgrade -o jsonpath="{.status.conditions[?(@.type==\"Idle\")].status}" 2>/dev/null)" == "True" ]]'

    log_info "IBU finalized"
}

run_ibu_test() {
    local run_label="$1"
    log_info "=== Starting IBU test: $run_label ==="

    start_prep
    wait_for_prep 1800 "$run_label"

    start_upgrade
    wait_for_upgrade 1800 "$run_label"

    local version
    version=$(spoke_oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
    log_info "Cluster upgraded to $version"

    log_info "=== IBU test $run_label complete ==="
}

print_timing() {
    local run_label="$1"
    local timing_file="${RESULTS_DIR}/timing-${run_label}.txt"

    if [[ ! -f "$timing_file" ]]; then
        log_warn "No timing file for $run_label"
        return
    fi

    local prep_start prep_end upgrade_start upgrade_end api_down api_up
    # shellcheck source=/dev/null
    source "$timing_file"

    local prep_dur upgrade_dur reboot_dur stabilize_dur
    prep_dur=$(duration_seconds "$prep_start" "$prep_end")
    upgrade_dur=$(duration_seconds "$upgrade_start" "$upgrade_end")
    reboot_dur=$(duration_seconds "$api_down" "$api_up")
    stabilize_dur=$(duration_seconds "$api_up" "$upgrade_end")

    log_info "Timing for $run_label:"
    log_info "  Prep:          $(format_duration "$prep_dur")"
    log_info "  Upgrade total: $(format_duration "$upgrade_dur")"
    log_info "    Reboot:      $(format_duration "$reboot_dur")"
    log_info "    Stabilize:   $(format_duration "$stabilize_dur")"
}
