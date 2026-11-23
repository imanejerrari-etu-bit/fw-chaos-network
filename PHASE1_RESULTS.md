# Phase 1 results (independent recomputation)

Source: `runs_v2` of the campaign of 8 November 2026 (PXC trials 1-40, MongoDB trials 101-145). Metrics were recomputed with `independent_check.py`, written separately from `parse_trials.py`; the two agree on the quantities they share. Hypotheses and outcomes are those of `PLAN_EXPERIMENTS_V2.md` (tag `prereg-phase1`) and its amendments.

## MongoDB (isolation 25 s, writer pinned to the primary, 5 writes/s)

| | `w:1` (n = 15) | `w:majority` (n = 30) |
|---|---|---|
| trials with at least one acknowledged-then-lost write | **15/15** (exact 95 % CI 78.2-100 %) | **0/30** (0-11.6 %) |
| lost acknowledged writes per trial | 49 in every trial | 0 |
| trials with an acknowledged write after isolation | 15/15 | 0/30 |
| last acknowledged write, s after partition start | mean 10.01 (9.91-10.08) | 0.01 (isolation not yet complete) |
| first election, s after partition start | mean 10.63 (n = 14) | mean 10.57 (n = 30) |
| `WriteConcernFailed` per trial (not acknowledged) | 0 | 3.87; none survived (0 writes present but not acknowledged) |

- H1 and H2 are supported. Fisher exact test on loss (`w:1` against `w:majority`): p = 2.9e-12.
- The count of 49 lost writes is the product of the client rate (about 5 writes/s) and the acknowledged window (10.0 s); the window, not the count, is the portable quantity. It matches `electionTimeoutMillis` = 10 s.
- The first election does not differ between the two write concerns (Mann-Whitney p = 0.44).
- One `w:1` trial (116) has no election in the logs (log lost, see below); it is kept for all other metrics.

## PXC (isolated node written to locally, 5 writes/s)

Valid trials: hold 20 s n = 29, hold 30 s n = 9 (trials 1 and 2 excluded, see the data-quality log).

| | hold 20 s | hold 30 s |
|---|---|---|
| trials with an acknowledged write after isolation | 0/29 (0-11.9 %) | 0/9 (0-33.6 %) |
| trials with an acknowledged-then-lost write | 0/29 | 0/9 |
| first non-acknowledged write, s after isolation (median) | 0.16 | 0.13 |
| non-primary state in the log, s after isolation (median, range) | 6.17 (5.77-6.37) | 6.10 (5.84-6.38) |
| error 1047 per trial (median) | 57 | 98 |
| first Synced after heal start, s (median) | 2.46 (1.42-4.29) | 2.60 (2.28-4.21) |
| container restart | **0/29** (0-11.9 %) | **8/9** (51.8-99.7 %) |
| `mysqld` shutdown signal in the log, s after partition start | none | median 30.3 (28.8-32.3), 7 of 8 usable logs |
| writes failing because `mysqld` is down after heal | 0/29 | 8/9 |

- H3 holds trivially: the isolated node acknowledged no write after isolation, so none could be lost. The node does not reject writes at once: writes block from the first 0.2 s, the node leaves the primary component about 6 s after isolation, and only then returns error 1047.
- H4 is supported (0/29 restarts at 20 s) and H5 is supported (8/9 at 30 s; Fisher exact p = 1.8e-7). The shutdown signal comes about 24 s after the node left the primary component, consistent with three failed liveness probes at 10 s intervals (the probe reports `non-Primary`, see `diag/events.txt`). The cause is Kubernetes, not Galera.
- In one 20 s trial a write that timed out on the client was later found committed (outcome unknown at the client).
- At 30 s the writer stops about 13 s after heal, before the restart cycle has finished: the duration of the restart is censored and is not reported.

## Corrections to the earlier campaign

The earlier MongoDB campaign reported an acknowledged window of 13-14 s and a mean RTO of 15.15 s. The new campaign finds 10.0 s and 10.6 s. The earlier harness applied the partition with four sequential `docker exec` calls (several seconds), so `t0` preceded the actual isolation by that time; the 4.5 s difference is consistent with this. The earlier PXC rejoin times (up to 106 s) came from a 25 s hold plus rule application, which exceeds the restart threshold seen here, and were polled every 10 s: they very probably include container restarts.

## Data-quality log

- **PXC trials 1 and 2 excluded**: the rules targeted 10.244.2.4, the former IP of `pxc-cluster-pxc-db-pxc-2`, whose IP was 10.244.2.3 in all later trials (`target_ips` in `meta.json`). One of the two peer links stayed intact, the node stayed in the primary component and acknowledged 91 and 53 writes during the isolation. These were the two trials run before Amendment 2 (per-trial IP resolution).
- **PXC trial 5**: the Galera log of the isolated pod is empty (log fallback), so log-based metrics are missing. The restart counters show a restart (the counter increased by the next trial).
- **MongoDB trial 116**: the logs of the two secondaries start after the election (log rotation), so no election time is available.
- **Restart counters lag**: a shutdown can be signalled more than 10 s before the container restarts; a trial's counter is read before that (trial 26). A restart is therefore defined as a shutdown signal in the log or a counter increase up to the next trial's starting value.
- No trial was flagged `suspect_sleep`; clock offsets between host and container were within the 1 s limit in all trials.
