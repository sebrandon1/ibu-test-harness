# IBU Test Harness

End-to-end automation for OpenShift Image-Based Upgrade (IBU) timing tests. Compares IBU upgrade duration with and without cert-manager installed to quantify the performance impact of cert-manager certificate preservation.

## Prerequisites

- `oc` CLI
- `podman` (or `docker`)
- `skopeo`
- `kustomize`
- `opm` (for catalog builds)
- Access to a hub cluster with ACM/ZTP
- Two spoke clusters: one for seed generation, one as the IBU target
- A container registry (e.g., quay.io) with push access

## Quick Start

```bash
cp config.env.example config.env
# Edit config.env with your environment details

./run-ibu-test.sh
```

## Usage

```
./run-ibu-test.sh [OPTIONS]

Options:
    --config FILE     Config file (default: config.env)
    --skip-build      Skip building custom images (use existing)
    --skip-seed       Skip seed image generation (use existing)
    --skip-baseline   Skip baseline (no cert-manager) IBU run
    --runs N          Number of cert-manager IBU runs (default: from config)
    -h, --help        Show help
```

### Examples

Full run from scratch:
```bash
./run-ibu-test.sh
```

Re-run just the IBU tests with existing images and seed:
```bash
./run-ibu-test.sh --skip-build --skip-seed --runs 3
```

Only cert-manager runs (skip baseline):
```bash
./run-ibu-test.sh --skip-build --skip-seed --skip-baseline --runs 2
```

## What It Does

1. **Build custom images** — LCA operator, recert, OLM bundle/catalog (all `linux/amd64`)
2. **Generate seed image** — Detach seed cluster from hub, deploy LCA, run SeedGenerator
3. **Baseline IBU** — Reprovision spoke, install operators, run IBU without cert-manager
4. **cert-manager IBU(s)** — Reprovision spoke, install operators + cert-manager + test certs, run IBU, verify TLS key preservation
5. **Generate report** — Markdown timing comparison with certificate checksum verification

## Known Gotchas (handled automatically)

- M-series Mac defaults to arm64 images; all builds forced to `linux/amd64`
- `opm index add` builds arm64 catalogs; catalog is rebuilt with explicit `--platform`
- CSV `replaces` field stripped to avoid OLM install failure on standalone catalogs
- OLM on OCP 4.21+ has stricter CSV validation; seed cluster uses direct kustomize deploy
- Monitoring operator needs dummy secrets after hub detachment
- SriovOperatorConfig must be created manually after SRIOV operator install
- All install plans auto-approved (ZTP policies set `Manual` approval)
- SeedGenerator secret requires `seedAuth` key (not `.dockerconfigjson`)
- Container storage partition (`/var/lib/containers`) required for IBU

## Output

Results are written to `results/<timestamp>/`:
- `timing-baseline.txt` — Prep/Upgrade timestamps for baseline
- `timing-certmanager-runN.txt` — Timestamps for each cert-manager run
- `checksums-certmanager-runN-{pre,post}.txt` — TLS key SHA-256 checksums
- `report-*.md` — Markdown comparison report
