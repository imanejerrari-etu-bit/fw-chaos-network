# Phase 1 experiments: plan (to be committed and pushed BEFORE the first non-smoke trial)

Status: draft written on the day of preparation. Commit this file together with `netns-tools-v2.ps1` and `parse_trials.py`, push, and tag the commit `prereg-phase1`. The Git timestamp is the external evidence that the plan precedes the data.

## Why
An audit of the released code showed that (i) the PXC continuous writer ran on a healthy node and the isolated node received a single probe write per trial, so acknowledged-write loss on PXC was not measured; (ii) the PXC rejoin time was read by polling every 10 s, which quantises it; (iii) the MongoDB RTO took the last "Election succeeded" line, which can be a later election. Phase 1 removes these three limits and adds `w:majority`.

## Experiments

**E1: PXC partition with a writer on the isolated node.** Same fault as Scenario 1 (isolated node cut from the two others, both directions, 25 s). A writer running inside the isolated pod (local socket, about 4 writes/s, unique sequence numbers, 4 s client timeout) logs start time, end time, return code and message of every write. After the node has rejoined, the sequence numbers present on a non-isolated node are read. Rejoin time and transfer type come from the isolated pod's log, not from polling. A 1 Hz status poll is kept only as a cross-check. n = 30 trials.

**E2: MongoDB, `w:majority` against `w:1`, same writer.** The writer is pinned to the primary by a direct connection (`retryWrites=false`) and logs every write. The primary is isolated from the two secondaries for 25 s. `w:majority` uses `wtimeout` 2000 ms. After stabilisation, the `_id` values present on the final primary are read. The RTO is the first election after the partition start; the number of elections is recorded. n = 30 trials with `w:majority` and 15 with `w:1` (control, same writer), interleaved in a random order fixed by seed and written to `schedule_mongo_v2.csv` before the first run.

Fixed for all trials: baseline 10 s before the partition, hold 25 s, post-heal observation 45 s (MongoDB) or until Synced plus 10 s (PXC). No parameter is changed during the campaign.

## Hypotheses (stated before the data)
- H1: with `w:1`, at least one acknowledged write is lost in every trial (replication of the earlier result with a new writer).
- H2: with `w:majority`, no acknowledged write is lost in any trial.
- H3: on the isolated PXC node, no acknowledged write is lost. We state this as a hypothesis to be tested, not as a known fact.

## Primary outcomes
1. `lost_acked`: acknowledged writes absent from the final state. Reported as the number of trials with at least one lost write (exact 95 % interval) and the per-trial mean.
2. `last_ack_in_partition_s`: time from partition start to the last acknowledged write on the isolated node (the acknowledged window).
3. `first_nonack_after_partition_s`: time from partition start to the first write that is not acknowledged.
4. PXC `rejoin_log_s` and `transfer_type` from logs; MongoDB `rto_first_s` and `n_elections_after_partition`.

Tests: Fisher exact test for the proportion of trials with at least one lost write, `w:1` against `w:majority`. Intervals: BCa for means (10,000 resamples, seed 2026), Clopper-Pearson for proportions. Everything else is descriptive.

## Sample sizes
n = 30 per main arm. If the true loss probability is zero, 0 of 30 gives an exact 95 % upper bound of 11.6 %; this is the strongest statement 30 trials can support, and the paper will say so. The `w:1` control (n = 15) is a check on the writer, not a powered comparison.

## Validity and exclusions (applied without looking at outcomes)
A trial is excluded only if: (a) the writer produced no write in the 3 s before the partition; (b) the partition rules were not applied (error from `Add-PartitionRule`); (c) the cluster was not stable at the start; (d) the harness failed and artefacts are missing. Excluded trials are listed in `exclusions.csv` with the reason. No trial is excluded because of its outcome values. All other trials are analysed and reported.

## Smoke test (before the campaign)
Set `$script:V2Root = "runs_smoke"`, run 2 PXC trials and 2 MongoDB trials (one `w1`, one `wmajority`) with trial numbers 901 to 904, then run `python3 parse_trials.py --runs runs_smoke --out smoke`. Check by hand: (1) `writer.log` has lines from before the partition and shows the expected return codes; (2) `present.txt` is not empty; (3) the pod logs contain engine timestamps; (4) the lines matched by `RE_PXC_SYNCED`, `RE_SST` and `RE_IST` in `parse_trials.py` are real log lines (adjust the patterns in the parser if not, no re-run needed); (5) the MongoDB election lines parse. Keep `runs_smoke` in the repository. Reset `$script:V2Root = "runs_v2"` afterwards.

## Amendments
Any change after the tag is recorded in `AMENDMENTS_V2.md` with the date and the reason, before it affects an analysis.

## Phase 2 (not started; decided after Phase 1)
A latency sweep on a common grid (1 to 12 s in 1 s steps), the same jitter and hold time for both systems, ten trials per level, with the observable taken from the logs for both systems. Code is not written yet.

## Known risks of the code
`netns-tools-v2.ps1` was written without access to the cluster and has not been run. It assumes: GNU `date`, `timeout`, `base64` and `mysql` in the PXC container `pxc`; `mongosh`, `sh` and `base64` in the client pod; an `xtrabackup` password without a single quote; and that the `xtrabackup` account can create `rpo_test_pxc.writes_v2` (otherwise create it once with an admin account). The smoke test is meant to find the first problems.

---

## Amendment 1 (written after the first smoke tests, before any campaign data)

Findings from the smoke tests that change the design (data in `runs_smoke*`, kept in the repository):

1. **The isolation was not instantaneous.** `Add-PartitionRule` resolves the pod PID and runs one `docker exec` per rule, four calls per partition. The writes of an isolated PXC node stopped being acknowledged about 1 s after the rule calls started, and a `w:majority` MongoDB primary kept acknowledging for about 1.7 s. Change: all rules are now applied in a single `docker exec` after the PID is resolved, and four timestamps are saved: `t_partition_ms` (before the call), `t_isolated_ms` (after it returns), `t_heal_start_ms` (before removal), `t_heal_ms` (after removal). Windows are measured from `t_isolated_ms`; the RTO is reported from both `t_partition_ms` (comparable with the earlier campaigns) and `t_isolated_ms`.
2. **A PXC pod was killed by Kubernetes after about 22 s without Primary status.** In a 31.5 s isolation, `mysqld` received a shutdown signal about 22 s after the node left the Primary component, and a restart with crash recovery followed (two smoke trials found the node down for about 390 s). This is very probably the liveness probe, not Galera. It means that a 25 s hold, as used in the earlier PXC campaign, can include a container restart in the measured rejoin time. Change: the primary PXC arm uses a hold of **20 s** (n = 30), and a second arm uses **30 s** (n = 10) to quantify the restart effect. The two arms are interleaved in a random order fixed by seed (`schedule_pxc_v2.csv`). Restart counters of all pods are saved before and after each trial, and `parse_trials.py` flags `restart_in_trial` and `mysqld_shutdown_in_log`. The liveness probe configuration is saved with the environment description (`kubectl get pod ... -o yaml`).
3. **Health precondition.** The liveness probe of the `pxc` container is `exec /var/lib/mysql/liveness-check.sh` with `initialDelaySeconds` 300, `periodSeconds` 10, `timeoutSeconds` 5 and `failureThreshold` 3 (saved in `diag/pxc1_pod.yaml`): it cannot act during the first 300 s of a container's life, and it can kill a container after three consecutive failures, that is after 20 to 30 s. A trial therefore starts only if all three PXC pods are Synced with a cluster size of 3 for three consecutive readings and the isolated pod's `pxc` container has been running for at least 310 s (up to 15 minutes of waiting). Otherwise the trial is recorded as failed (`FAILED.txt`) and is not counted. A writer pre-check requires at least one acknowledged write before the partition (PXC and MongoDB); the MongoDB writer now logs the connection error message.
4. **MongoDB verification.** The final state is read with `print` per `_id` and logs and metadata are saved before the verification; a missing primary raises an explicit error.

Additional hypotheses (stated before the data): H4: with a 20 s hold, no PXC pod restart occurs in any trial (0 of 30); H5: with a 30 s hold, a restart of the isolated pod occurs in at least one of the 10 trials. Additional secondary outcomes: `restart_in_trial`, `rejoin_from_heal_start_s`, `first_connection_after_heal_s`, `nonprimary_from_isolation_s`. The rejoin time is defined as the time from heal start to the first `Shifting ... -> SYNCED` line in `mysqld-error.log`.

Exclusions (added to the list above): trials in which the cluster was not healthy at the start, or the writer pre-check failed, are not run and are listed with their reason. Trials with a restart are not excluded: they are analysed and reported separately.

Sample sizes after the amendment: PXC 30 trials at 20 s and 10 trials at 30 s; MongoDB 30 trials with `w:majority` and 15 with `w:1` (hold 25 s).
