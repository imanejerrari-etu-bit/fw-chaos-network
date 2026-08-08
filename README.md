# FW-Chaos-Network

Data, injection tooling, and simulation code for *"Beyond Node
Failures: Network-Level Fault Characterization of Kubernetes-Native
Databases"* — an empirical taxonomy of MongoDB and Percona XtraDB
Cluster (PXC) behavior under network partition, asymmetric
degradation, and latency/jitter, plus an exploratory adaptive
failure-detection threshold policy.

## Repository structure

```
.
├── paper/     # Manuscript (LaTeX source + compiled PDF)
├── data/      # Raw per-trial experimental data (CSV)
├── scripts/   # Fault-injection tooling and controller simulation
└── figures/   # Generated figures (PDF), reproducible from data/ and scripts/
```

## Data (`data/`)

| File | Scenario | System | n |
|---|---|---|---|
| `campaign_rpo_mongodb_n30_v3.csv` | Scenario 1 (complete partition) | MongoDB | 30 |
| `campaign_pxc_partition_campaign1_n30.csv` | Scenario 1 (complete partition), campaign 1 | PXC | 30 (29 with recorded rejoin time) |
| `campaign_pxc_partition_campaign2_n30.csv` | Scenario 1 (complete partition), campaign 2 | PXC | 30 |
| `campaign_pxc_partition_combined_n59.csv` | Scenario 1, both campaigns combined, valid rejoin times only | PXC | 59 |
| `campaign_pxc_scenario2_n9.csv` | Scenario 2 (asymmetric degradation), automated trials | PXC | 9 |
| `campaign_jitter_mongodb_FINAL_n30.csv` | Scenario 3 (latency/jitter sweep) | MongoDB | 30 |
| `campaign_pxc_jitter_n30.csv` | Scenario 3 (latency/jitter sweep) | PXC | 30 |

Column definitions follow directly from the field names (timestamps
in UTC, durations in seconds). See the manuscript (§4–5) for the
full experimental protocol and fault-injection procedure.

**Note on PXC Scenario 1 data:** one trial in campaign 1 (trial 7)
has a missing `rejoin_seconds` value, excluded from analysis
(§5.1.2 of the manuscript) rather than imputed. All reported
statistics for this scenario are computed on the resulting n=59.

## Scripts (`scripts/`)

- `controller_simulation.py` — Trace-driven simulation of the
  exploratory adaptive detection-threshold controller
  (Contribution 2, §6.3). Reproduces Table 6 exactly:
  ```bash
  python3 controller_simulation.py
  ```
- `deploy_cnpg.ps1` — Deployment script for the CloudNativePG /
  Kubernetes test cluster used to host the database instances under
  test.
- `netns-tools.ps1` — Network-namespace fault-injection utilities
  (`iptables`, `tc netem` wrappers) used to realize the three fault
  classes described in §4.

## Figures (`figures/`)

All three figures in the manuscript are generated directly from the
data in `data/` (Scenario 1 and 3 distributions) or from the live
output of `scripts/controller_simulation.py` (controller
comparison) — no manually-entered values.

## Reproducing the paper

```bash
cd paper/
pdflatex fw_chaos_network.tex
pdflatex fw_chaos_network.tex   # second pass for references
```

## Status

This is a working paper (draft), currently being prepared for
journal submission. Contribution 2 (adaptive controller) is
explicitly a preliminary, simulation-only exploration — see §6.3.4
of the manuscript for its stated scope and limitations.

## License

- Code (`scripts/`) is released under the [MIT License](LICENSE).
- Data (`data/`) is released under
  [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Citation

Citation details will be added upon acceptance/publication.
