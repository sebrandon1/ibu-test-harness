# CLAUDE.md

## Project Overview

End-to-end automation for OpenShift Image-Based Upgrade (IBU) timing tests. Benchmarks IBU upgrade performance with and without cert-manager to quantify performance impact on certificate preservation.

## Running

```bash
./run-ibu-test.sh [OPTIONS]
# --skip-build     Skip catalog/operator builds
# --skip-seed      Skip seed image generation
# --skip-baseline  Skip baseline IBU runs
# --runs N         Number of test iterations
```

Configuration via `config.env` (see `config.env.example`).

## Linting

```bash
# CI runs these on PRs:
shellcheck            # Shell script quality (severity: warning)
shfmt                 # Shell formatting (4-space indent)
yamllint              # YAML validation (200 char line limit)
```

## Key Architecture

- **Language:** Bash shell scripts
- **Library functions:** `lib/*.sh` (certmanager, ibu, provision, seed, report)
- **Results:** Timestamped `results/` directory with timing/checksum outputs
- **Flow:** seed generation -> baseline IBU -> cert-manager IBU runs -> report generation
- **Requires:** `oc`, `podman`, `skopeo`, `kustomize`, `opm`, OpenShift hub cluster with ACM/ZTP, two spoke clusters
