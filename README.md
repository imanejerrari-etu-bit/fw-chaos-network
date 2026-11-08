# Network-fault behaviour of MongoDB and Percona XtraDB Cluster on Kubernetes

Data, scripts and analysis code for the manuscript *Network-Fault Behaviour of MongoDB and Percona XtraDB Cluster on Kubernetes: Partition, Asymmetric Degradation and Latency-Induced Failures* (I. Jerrari, I. Assayad).

Three network faults are injected in pod network namespaces on a single-host `kind` cluster (Windows/WSL2): complete partition, asymmetric single-link degradation, and latency/jitter sweeps. Systems: MongoDB (3-member replica set, `w:1`) and Percona XtraDB Cluster (3-node Galera).

## Contents (flat layout)

| File | What it is |
|---|---|
| `campaign_rpo_mongodb_n30_v3.csv` | MongoDB, Scenario 1 (partition): RTO and RPO, 30 trials |
| `campaign_pxc_partition_campaign1_n30.csv`, `campaign_pxc_partition_campaign2_n30.csv` | PXC, Scenario 1: two campaigns of 30 trials (campaign 2 was run before campaign 1; see `t0_utc`) |
| `campaign_pxc_partition_combined_n59.csv` | The two PXC campaigns combined, trials with a recorded rejoin time (59 of 60) |
| `campaign_pxc_scenario2_n9.csv` | PXC, Scenario 2 (asymmetric): 9 automated trials |
| `campaign_jitter_mongodb_FINAL_n30.csv` | MongoDB, Scenario 3 (latency/jitter): 30 trials |
| `campaign_pxc_jitter_n30.csv` | PXC, Scenario 3: 30 trials |
| `netns-tools.ps1` | PowerShell functions that inject the faults and run the campaigns |
| `analysis.py` | Reproduces every statistic in the manuscript from the CSV files |
| `make_figures.py` | Generates the manuscript figures from the CSV files |
| `controller_simulation.py` | Exploratory trace-driven simulation of an adaptive detection threshold. **Not used for any result in the manuscript.** |
| `deploy_cnpg.ps1` | **[TO DECIDE]** Deploys CloudNativePG (PostgreSQL), which is not studied in the manuscript. Move it to a different repository or remove it. |

**[TO COMPLETE before submission]** The manuscript also reports 12 MongoDB Scenario 2 trials and 2 manual PXC Scenario 2 trials (n = 11 for PXC). Their data are not in this repository yet. The MongoDB workload script (`writer.js`) is also missing.

## Reproduce the statistics and figures

```
pip install numpy pandas scipy matplotlib     # scipy >= 1.9 (BCa bootstrap)
python3 analysis.py --data . --seed 2026 --out analysis_output.md
python3 make_figures.py --data . --out figures
```

Continuous outcomes: BCa bootstrap 95 % CI of the mean (10,000 resamples, fixed seed). Proportions: exact Clopper-Pearson 95 % intervals.

## Data dictionary

Common: `trial` index; `t0_utc` start of the injection (UTC); `*_pod` Kubernetes pod name.

**`campaign_rpo_mongodb_n30_v3.csv`**
- `isolated_pod`: primary isolated from the other members. `new_primary_pod`: primary elected afterwards.
- `rto_seconds`: time from just before the partition rules were applied to the timestamp of the last "Election succeeded" log line (last two minutes of the new primary's log).
- `rpo_count`: number of operations in the most recent rollback file of the isolated pod (counted with `bsondump`). `rpo_seq_list`: their sequence numbers, `|`-separated.

**PXC partition files**
- `isolated_pod`: node isolated. `write_rejected`: a single probe INSERT on the isolated node, issued after the detection poll (2-15 s), was rejected (`ERROR 1047`).
- `detection_immediate`: `wsrep_ready` was read as OFF on the isolated node within the 15 s detection poll (polled every 2 s). It is not a measure of how soon writes were rejected.
- `rejoined`, `rejoin_seconds`: time from rule removal until the node first reported `Synced` with a cluster size of 3. The status was read immediately after removal and then every 10 s, so values are quantised by the polling interval (a value near 10.4 s is the second reading).
- `likely_sst`: the log of the isolated node contained `wsrep_sst_method` or `State Transfer`. It is **not** specific to a full SST.

**`campaign_pxc_scenario2_n9.csv`**: `pair` node pair whose direct link was cut; `witness` third node; `cluster_stayed_healthy`; `write_a_ok`, `write_b_ok`: probe writes on each side succeeded.

**`campaign_jitter_mongodb_FINAL_n30.csv`**
- `delay_ms`, `jitter_ms`: `tc netem delay` mean and jitter on the target pod's `eth0` egress (jitter 2000 ms). `target_pod`.
- `election_triggered`: an "Election succeeded" line after `t0_utc` appeared in the log of any member (last such line per member, read after the delay was removed). `new_primary`, `rto_seconds`: member and time of that election.

**`campaign_pxc_jitter_n30.csv`**
- `delay_ms`, `jitter_ms` (jitter 500 ms). `cluster_size_during`: cluster size read on a witness node at the end of the injection. `excluded`: that size was below 3. `recovered_after`: cluster size back to 3 after the delay was removed.

## Known limitations of the data

Hold times (script defaults: 25 s for the partition and the MongoDB delay, 20 s for the PXC delay) are not stored per trial. For PXC, acknowledged-write loss was not measured. See the manuscript for the full list.

## Licence

See `LICENSE`.
