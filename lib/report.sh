# shellcheck shell=bash
# Report generation

generate_report() {
    local report_file
    report_file="${RESULTS_DIR}/report-$(date -u +%Y%m%d-%H%M%S).md"
    log_info "Generating report: $report_file"

    cat > "$report_file" <<EOF
# IBU Timing Test Report

**Generated:** $(timestamp)

## Environment

| Component | Details |
|-----------|---------|
| Hub | ${HUB_API} |
| Spoke | ${SPOKE_NAME} (SNO) |
| Source version | OCP ${SOURCE_VERSION} |
| Target version | OCP ${TARGET_VERSION} |
| Seed image | \`${SEED_IMAGE}\` |
| LCA image | \`${LCA_IMAGE}\` |
| Recert image | \`${RECERT_IMAGE}\` |

## Upgrade Stage Timing

| Run | Reboot | Stabilization | Total |
|-----|--------|---------------|-------|
EOF

    for timing_file in "${RESULTS_DIR}"/timing-*.txt; do
        [[ -f "$timing_file" ]] || continue
        local run_label
        run_label=$(basename "$timing_file" .txt | sed 's/timing-//')

        (
            local prep_start prep_end upgrade_start upgrade_end api_down api_up
            # shellcheck source=/dev/null
            source "$timing_file"
            local reboot_dur stabilize_dur total_dur
            reboot_dur=$(duration_seconds "$api_down" "$api_up")
            stabilize_dur=$(duration_seconds "$api_up" "$upgrade_end")
            total_dur=$(duration_seconds "$upgrade_start" "$upgrade_end")
            echo "| $run_label | $(format_duration "$reboot_dur") | $(format_duration "$stabilize_dur") | $(format_duration "$total_dur") |"
        ) >> "$report_file"
    done

    # Certificate checksums
    local has_checksums=false
    for f in "${RESULTS_DIR}"/checksums-*-pre.txt; do
        [[ -f "$f" ]] && has_checksums=true && break
    done

    if $has_checksums; then
        cat >> "$report_file" <<'EOF'

## Certificate Preservation

| Run | Secret | Pre-IBU | Post-IBU | Match |
|-----|--------|---------|----------|-------|
EOF

        for pre_file in "${RESULTS_DIR}"/checksums-*-pre.txt; do
            [[ -f "$pre_file" ]] || continue
            local run_label
            run_label=$(basename "$pre_file" .txt | sed 's/checksums-//' | sed 's/-pre//')
            local post_file="${RESULTS_DIR}/checksums-${run_label}-post.txt"
            [[ -f "$post_file" ]] || continue

            while IFS=': ' read -r secret checksum; do
                local post_checksum match
                post_checksum=$(grep "^${secret}:" "$post_file" | awk '{print $2}')
                if [[ "$checksum" == "$post_checksum" ]]; then
                    match="PASS"
                else
                    match="FAIL"
                fi
                echo "| $run_label | $secret | ${checksum:0:16}... | ${post_checksum:0:16}... | $match |" >> "$report_file"
            done < "$pre_file"
        done
    fi

    cat >> "$report_file" <<EOF

## Test Artifacts

| Artifact | Location |
|----------|----------|
| LCA image | \`${LCA_IMAGE}\` |
| Recert image | \`${RECERT_IMAGE}\` |
| Seed image | \`${SEED_IMAGE}\` |
| Results directory | \`${RESULTS_DIR}\` |
EOF

    log_info "Report written to $report_file"
    echo "$report_file"
}
