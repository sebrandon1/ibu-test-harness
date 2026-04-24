#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CONFIG_FILE="${SCRIPT_DIR}/config.env"
SKIP_BUILD=false
SKIP_SEED=false
SKIP_BASELINE=false
NUM_RUNS_OVERRIDE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run end-to-end IBU timing tests comparing upgrades with and without cert-manager.

Options:
    --config FILE     Config file (default: config.env)
    --skip-build      Skip building custom images
    --skip-seed       Skip seed image generation
    --skip-baseline   Skip baseline (no cert-manager) run
    --runs N          Override number of cert-manager runs
    -h, --help        Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-seed)
            SKIP_SEED=true
            shift
            ;;
        --skip-baseline)
            SKIP_BASELINE=true
            shift
            ;;
        --runs)
            NUM_RUNS_OVERRIDE="$2"
            shift 2
            ;;
        -h | --help) usage ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Load config — set -a exports all sourced variables for bash -c subshells
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE"
    echo "Copy config.env.example to config.env and fill in your values."
    exit 1
fi
set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

[[ -n "$NUM_RUNS_OVERRIDE" ]] && NUM_RUNS="$NUM_RUNS_OVERRIDE"

# Set up results directory
RESULTS_DIR="${SCRIPT_DIR}/results/$(date -u +%Y%m%d-%H%M%S)"
export RESULTS_DIR
mkdir -p "$RESULTS_DIR"

export SPOKE_KUBECONFIG="${RESULTS_DIR}/${SPOKE_NAME}.kubeconfig"
export SEED_KUBECONFIG="${RESULTS_DIR}/${SEED_NAME}.kubeconfig"
export SCRIPT_DIR

# Source library scripts
for lib in common hub spoke provision operators certmanager ibu seed report; do
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/${lib}.sh"
done

main() {
    log_info "=========================================="
    log_info "IBU Timing Test Harness"
    log_info "=========================================="
    log_info "Results: $RESULTS_DIR"
    log_info "Spoke: $SPOKE_NAME ($SOURCE_VERSION → $TARGET_VERSION)"
    log_info "Runs: 1 baseline + $NUM_RUNS cert-manager"
    log_info ""

    check_prerequisites
    hub_login

    # Phase 1: Build custom images
    if ! $SKIP_BUILD; then
        log_info "========== Phase 1: Build Images =========="
        build_images
    else
        log_info "Skipping image build (--skip-build)"
    fi

    # Phase 2: Seed generation
    if ! $SKIP_SEED; then
        log_info "========== Phase 2: Seed Generation =========="
        run_seed_generation
    else
        log_info "Skipping seed generation (--skip-seed)"
        verify_seed_image
    fi

    # Phase 3: Baseline IBU (no cert-manager)
    if ! $SKIP_BASELINE; then
        log_info "========== Phase 3: Baseline IBU (no cert-manager) =========="
        run_single_test "baseline" false
    else
        log_info "Skipping baseline (--skip-baseline)"
    fi

    # Phase 4: cert-manager IBU runs
    for i in $(seq 1 "$NUM_RUNS"); do
        log_info "========== Phase 4: cert-manager IBU (run $i/$NUM_RUNS) =========="
        run_single_test "certmanager-run${i}" true
    done

    # Phase 5: Generate report
    log_info "========== Phase 5: Report =========="
    local report
    report=$(generate_report)
    log_info ""
    log_info "=========================================="
    log_info "Test complete. Report: $report"
    log_info "=========================================="
    cat "$report"
}

build_images() {
    log_info "Building custom LCA image"
    (
        cd "$LCA_REPO_PATH"
        "$ENGINE" build --platform="$PLATFORM" \
            -t "$LCA_IMAGE" -f Dockerfile.multiarch .
        "$ENGINE" push "$LCA_IMAGE"
    )
    verify_image_arch "$LCA_IMAGE"

    log_info "Building custom recert image"
    (
        cd "$RECERT_REPO_PATH"
        "$ENGINE" build --platform="$PLATFORM" \
            -t "$RECERT_IMAGE" -f Dockerfile .
        "$ENGINE" push "$RECERT_IMAGE"
    )
    verify_image_arch "$RECERT_IMAGE"

    log_info "Building operator bundle"
    (
        cd "$LCA_REPO_PATH"
        make bundle IMG="$LCA_IMAGE" IMAGE_TAG_BASE="${REGISTRY}/lifecycle-agent-operator" || true
        # Strip replaces field (causes install failure on clusters without prior version)
        sed -i.bak '/^  replaces:/d' bundle/manifests/lifecycle-agent.clusterserviceversion.yaml
        rm -f bundle/manifests/lifecycle-agent.clusterserviceversion.yaml.bak

        "$ENGINE" build --platform="$PLATFORM" \
            -f bundle.Dockerfile -t "$BUNDLE_IMAGE" .
        "$ENGINE" push "$BUNDLE_IMAGE"
    )

    log_info "Building operator catalog"
    (
        cd "$LCA_REPO_PATH"
        rm -rf database/ index.Dockerfile*
        opm index add --container-tool "$ENGINE" --mode semver \
            --tag "${CATALOG_IMAGE}-tmp" --bundles "$BUNDLE_IMAGE" --generate
        # opm builds for host arch; rebuild for target platform
        "$ENGINE" build --platform="$PLATFORM" \
            -f index.Dockerfile -t "$CATALOG_IMAGE" .
        "$ENGINE" push "$CATALOG_IMAGE"
    )
    verify_image_arch "$CATALOG_IMAGE"

    log_info "All images built and pushed"
}

verify_image_arch() {
    local image="$1"
    local arch
    arch=$("$ENGINE" inspect "$image" --format '{{.Architecture}}' 2>/dev/null)
    local expected="${PLATFORM#linux/}"
    if [[ "$arch" != "$expected" ]]; then
        log_error "Image $image has wrong architecture: $arch (expected $expected)"
        return 1
    fi
    log_info "Image arch verified: $image → $arch"
}

run_single_test() {
    local run_label="$1" with_certmanager="$2"

    # Reprovision spoke
    log_info "--- Reprovisioning $SPOKE_NAME ---"
    deprovision_spoke
    provision_spoke
    fetch_spoke_kubeconfig

    # Verify container storage
    verify_container_storage_mount

    # Set up operators
    setup_spoke_operators

    # Optionally install cert-manager
    if $with_certmanager; then
        setup_certmanager_test "$run_label"
    fi

    # Run IBU
    run_ibu_test "$run_label"
    print_timing "$run_label"

    # Post-upgrade verification
    fetch_spoke_kubeconfig
    if $with_certmanager; then
        record_tls_checksums "${run_label}-post"
        verify_tls_checksums "$run_label" || true
    fi

    # Finalize
    finalize_ibu
}

main "$@"
