#!/usr/bin/env python3
"""
Turns the raw artefacts saved by netns-tools-v2.ps1 into per-trial metrics and summary statistics.
All timing comes from engine log timestamps and from client-side write logs, not from live polling.
The raw artefacts are kept, so patterns can be corrected and trials re-parsed without re-running.

Usage:  python3 parse_trials.py --runs runs_v2 --out trials_v2 [--seed 2026]
Needs:  numpy, pandas, scipy (>= 1.9)

Per-trial directory (written by netns-tools-v2.ps1):
  meta.json         system, trial, campaign, t_partition_ms, t_heal_ms, hold_s, isolated_pod, write_concern, pods
  writer.log        PXC:   start_ms,end_ms,seq,rc,message      (rc 0 = acknowledged, 124 = client timeout)
                    Mongo: start_ms,end_ms,seq,status          (status OK or ERR:<codeName>:<code>)
  present.txt       seq values found in the final state (one per line)
  log_<pod>.txt     engine logs since 30 s before the trial start
  status_poll.csv   (PXC only) epoch_ms,pod,text  cross-check, about 1 reading/s
"""
import argparse, glob, json, os, re, sys
from datetime import datetime, timezone
import numpy as np, pandas as pd
from scipy import stats
from scipy.stats import beta

# ------------------------------------------------------------------ patterns (validate on the first trials)
RE_PXC_SYNCED = re.compile(r"Shifting\s+\S+\s*->\s*SYNCED")
RE_PXC_NONPRIM = re.compile(r"New COMPONENT:.*primary\s*=\s*no|Received NON-PRIMARY|Shifting\s+\S+\s*->\s*OPEN")
RE_SST = re.compile(r"WSREP_SST|Running SST|SST (request|complete|failed|sent|received)|Starting SST|wsrep_sst_(donor|receive)", re.I)
RE_IST = re.compile(r"\bIST (receiver|received|sender|will|failed)|Receiving IST|Prepared IST receiver|IST received|Incremental State Transfer", re.I)
RE_PXC_CONN = re.compile(r"connection established to")
RE_PXC_SHUTDOWN = re.compile(r"Received SHUTDOWN|Shutting down mysqld|Normal shutdown", re.I)
RE_MONGO_ELECTION = "Election succeeded"
RE_MONGO_STEPDOWN = re.compile(r"[Ss]tepping down|[Ss]tep down", re.I)
ISO = re.compile(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?\s*(Z|[+-]\d\d:?\d\d)?")

def ts_to_ms(s):
    m = ISO.search(s)
    if not m: return None
    y, mo, d, h, mi, se, frac, tz = m.groups()
    ms = int((frac or "0")[:3].ljust(3, "0"))
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), tzinfo=timezone.utc)
    off = 0
    if tz and tz != "Z":
        sign = 1 if tz[0] == "+" else -1; t = tz[1:].replace(":", ""); off = sign * (int(t[:2]) * 3600 + int(t[2:]) * 60)
    return int(dt.timestamp() * 1000) - off * 1000 + ms

def cp(k, n, a=0.05):
    lo = 0.0 if k == 0 else beta.ppf(a / 2, k, n - k + 1); hi = 1.0 if k == n else beta.ppf(1 - a / 2, k + 1, n - k)
    return 100 * lo, 100 * hi

def bca(x, seed):
    x = np.asarray([v for v in x if v == v], float)
    if len(x) < 5 or np.all(x == x[0]): return (float("nan"), float("nan"))
    r = stats.bootstrap((x,), np.mean, n_resamples=10000, confidence_level=0.95, method="BCa", random_state=seed)
    return r.confidence_interval.low, r.confidence_interval.high

def restart_flag(meta):
    b, a = meta.get("restarts_before"), meta.get("restarts_after")
    if not isinstance(b, dict) or not isinstance(a, dict): return None
    return int(any(b.get(k) != a.get(k) for k in b))

def read_lines(p):
    return open(p, encoding="utf-8", errors="replace").read().splitlines() if os.path.exists(p) else []

def read_set(p):
    return {int(l.strip()) for l in read_lines(p) if l.strip().lstrip("-").isdigit()}

# ------------------------------------------------------------------ PXC
def parse_pxc(d, meta):
    tp, th = meta["t_partition_ms"], meta["t_heal_ms"]
    tiso, th0 = meta.get("t_isolated_ms", tp), meta.get("t_heal_start_ms", th)
    w = []
    for l in read_lines(os.path.join(d, "writer.log")):
        p = l.split(",", 4)
        if len(p) >= 4 and p[0].isdigit() and p[3].lstrip("-").isdigit():
            w.append(dict(s=int(p[0]), e=int(p[1]), seq=int(p[2]), rc=int(p[3]), msg=p[4] if len(p) > 4 else ""))
    present = read_set(os.path.join(d, "present.txt"))
    acked = {x["seq"] for x in w if x["rc"] == 0}
    during = [x for x in w if tp <= x["s"] <= th]
    ack_during = [x for x in during if x["rc"] == 0]
    ack_iso = [x for x in w if x["rc"] == 0 and tiso <= x["s"] <= th0]
    nonack = [x for x in w if x["s"] >= tp and x["rc"] != 0]
    iso_log = read_lines(os.path.join(d, f"log_{meta['isolated_pod']}.txt"))
    synced, nonprim, conn, shutdown, sst, ist = None, None, None, None, [], []
    for l in iso_log:
        t = ts_to_ms(l)
        if t is None: continue
        if t >= th0:
            if synced is None and RE_PXC_SYNCED.search(l): synced = t
            if conn is None and RE_PXC_CONN.search(l): conn = t
            if RE_SST.search(l): sst.append(l.strip()[:160])
            if RE_IST.search(l): ist.append(l.strip()[:160])
        if t >= tp and shutdown is None and RE_PXC_SHUTDOWN.search(l): shutdown = t
        if tp <= t < th and nonprim is None and RE_PXC_NONPRIM.search(l): nonprim = t
    poll_synced = None
    pf = os.path.join(d, "status_poll.csv")
    for l in read_lines(pf):
        p = l.split(",", 2)
        if len(p) == 3 and p[0].isdigit() and p[1] == meta["isolated_pod"] and int(p[0]) >= th0:
            if "Synced" in p[2] and re.search(r"wsrep_cluster_size\s+([3-9])", p[2]):
                poll_synced = int(p[0]); break
    ttype = "sst" if sst else ("ist" if ist else "none")
    return dict(
        system="pxc", campaign=meta["campaign"], trial=meta["trial"], hold_s=meta.get("hold_s"),
        n_writes=len(w), n_acked=len(acked), n_client_timeout=sum(1 for x in w if x["rc"] == 124),
        n_error=sum(1 for x in w if x["rc"] not in (0, 124)), n_err1047=sum(1 for x in w if "1047" in x["msg"]),
        n_acked_during_partition=len(ack_during), n_acked_after_isolation=len(ack_iso),
        isolation_apply_s=(tiso - tp) / 1000,
        first_nonack_after_partition_s=(min(x["s"] for x in nonack) - tp) / 1000 if nonack else np.nan,
        last_ack_in_partition_s=(max(x["e"] for x in ack_during) - tp) / 1000 if ack_during else np.nan,
        lost_acked=len(acked - present), n_timeout_present=len({x["seq"] for x in w if x["rc"] == 124} & present),
        nonprimary_log_s=(nonprim - tp) / 1000 if nonprim else np.nan,
        nonprimary_from_isolation_s=(nonprim - tiso) / 1000 if nonprim else np.nan,
        rejoin_log_s=(synced - th) / 1000 if synced else np.nan,
        rejoin_from_heal_start_s=(synced - th0) / 1000 if synced else np.nan,
        first_connection_after_heal_s=(conn - th0) / 1000 if conn else np.nan,
        mysqld_shutdown_log_s=(shutdown - tp) / 1000 if shutdown else np.nan, mysqld_shutdown_in_log=int(shutdown is not None),
        rejoin_poll_s=(poll_synced - th0) / 1000 if poll_synced else np.nan,
        transfer_type=ttype, transfer_lines=" || ".join((sst or ist)[:3]), restart_in_trial=restart_flag(meta),
        present_file=os.path.exists(os.path.join(d, "present.txt")), notes=meta.get("notes", ""))

# ------------------------------------------------------------------ MongoDB
def parse_mongo(d, meta):
    tp, th = meta["t_partition_ms"], meta["t_heal_ms"]
    tiso, th0 = meta.get("t_isolated_ms", tp), meta.get("t_heal_start_ms", th)
    w = []
    for l in read_lines(os.path.join(d, "writer.log")):
        p = l.split(",", 3)
        if len(p) == 4 and p[0].isdigit():
            w.append(dict(s=int(p[0]), e=int(p[1]), seq=int(p[2]), st=p[3].strip()))
    present = read_set(os.path.join(d, "present.txt"))
    acked = {x["seq"] for x in w if x["st"] == "OK"}
    ack_during = [x for x in w if x["st"] == "OK" and tp <= x["s"] <= th]
    ack_iso = [x for x in w if x["st"] == "OK" and tiso <= x["s"] <= th0]
    nonack = [x for x in w if x["s"] >= tp and x["st"] != "OK"]
    elections, stepdown = [], None
    for pod in meta["pods"]:
        for l in read_lines(os.path.join(d, f"log_{pod}.txt")):
            if RE_MONGO_ELECTION in l:
                t = None
                try:
                    j = json.loads(l); t = ts_to_ms(j.get("t", {}).get("$date", "")) if isinstance(j.get("t"), dict) else None
                except Exception:
                    t = ts_to_ms(l)
                if t and t >= tp: elections.append(t)
            elif pod == meta["isolated_pod"] and stepdown is None and RE_MONGO_STEPDOWN.search(l):
                t = ts_to_ms(l)
                if t and t >= tp: stepdown = t
    elections.sort()
    kinds = {}
    for x in w:
        if x["st"] != "OK": kinds[x["st"].split(":")[1] if ":" in x["st"] else x["st"]] = kinds.get(x["st"].split(":")[1] if ":" in x["st"] else x["st"], 0) + 1
    return dict(
        system="mongo", campaign=meta["campaign"], trial=meta["trial"], write_concern=meta.get("write_concern"), hold_s=meta.get("hold_s"),
        n_writes=len(w), n_acked=len(acked), n_acked_during_partition=len(ack_during), n_acked_after_isolation=len(ack_iso),
        isolation_apply_s=(tiso - tp) / 1000,
        n_error=sum(1 for x in w if x["st"] != "OK"), error_kinds=json.dumps(kinds, sort_keys=True),
        first_nonack_after_partition_s=(min(x["s"] for x in nonack) - tp) / 1000 if nonack else np.nan,
        last_ack_in_partition_s=(max(x["e"] for x in ack_during) - tp) / 1000 if ack_during else np.nan,
        lost_acked=len(acked - present), n_present_not_acked=len(present - acked),
        n_elections_after_partition=len(elections), restart_in_trial=restart_flag(meta),
        rto_first_s=(elections[0] - tp) / 1000 if elections else np.nan,
        rto_first_from_isolation_s=(elections[0] - tiso) / 1000 if elections else np.nan,
        rto_last_s=(elections[-1] - tp) / 1000 if elections else np.nan,
        stepdown_log_s=(stepdown - tp) / 1000 if stepdown else np.nan,
        present_file=os.path.exists(os.path.join(d, "present.txt")), notes=meta.get("notes", ""))

# ------------------------------------------------------------------ driver and summaries
def load(runs):
    rows = []
    for mp in sorted(glob.glob(os.path.join(runs, "*", "*", "meta.json"))):
        d = os.path.dirname(mp); meta = json.load(open(mp, encoding="utf-8-sig"))
        if meta.get("exclude"): continue
        try:
            rows.append(parse_pxc(d, meta) if meta["system"] == "pxc" else parse_mongo(d, meta))
        except Exception as ex:
            print(f"WARNING {d}: {ex}", file=sys.stderr)
    return rows

def summarize(df, seed, out):
    for camp, g in df.groupby("campaign"):
        out(f"\n### {camp} (n = {len(g)} parsed trials)")
        k = int((g.lost_acked > 0).sum()); lo, hi = cp(k, len(g))
        out(f"- trials with at least one acknowledged-then-lost write: {k}/{len(g)} (exact 95% CI [{lo:.1f}, {hi:.1f}]%); "
            f"lost writes per trial: mean {g.lost_acked.mean():.1f}, median {g.lost_acked.median():.1f}, max {int(g.lost_acked.max())}")
        out(f"- acknowledged writes during the partition: mean {g.n_acked_during_partition.mean():.1f}, "
            f"trials with at least one: {int((g.n_acked_during_partition > 0).sum())}/{len(g)}")
        for col, lab in [("last_ack_in_partition_s", "last acknowledged write after partition start (s)"),
                         ("first_nonack_after_partition_s", "first non-acknowledged write after partition start (s)"),
                         ("rto_first_s", "RTO, first election (s)"), ("rto_first_from_isolation_s", "first election, from end of rule application (s)"),
                         ("isolation_apply_s", "time to apply the rules (s)"), ("nonprimary_from_isolation_s", "PXC non-primary seen in log, from isolation (s)"),
                         ("first_connection_after_heal_s", "PXC first peer connection after heal start (s)"), ("rejoin_from_heal_start_s", "PXC rejoin from heal start (s)"), ("rto_last_s", "RTO, last election (s)"),
                         ("rejoin_log_s", "PXC rejoin from logs (s)"), ("rejoin_poll_s", "PXC rejoin from 1 Hz poll (s)")]:
            if col in g and g[col].notna().sum() >= 1:
                x = g[col].dropna(); lo, hi = bca(x, seed)
                out(f"- {lab}: n={len(x)}, mean {x.mean():.2f}, median {x.median():.2f}, min {x.min():.2f}, max {x.max():.2f}, BCa CI of mean [{lo:.2f}, {hi:.2f}]")
        if "transfer_type" in g and g.transfer_type.notna().any():
            out(f"- PXC transfer type (from logs): {g.transfer_type.value_counts().to_dict()}")
        if "n_elections_after_partition" in g and g.n_elections_after_partition.notna().any():
            out(f"- elections after the partition start: {g.n_elections_after_partition.dropna().astype(int).value_counts().sort_index().to_dict()}")

if __name__ == "__main__":
    P = argparse.ArgumentParser(); P.add_argument("--runs", default="runs_v2"); P.add_argument("--out", default="trials_v2"); P.add_argument("--seed", type=int, default=2026)
    A = P.parse_args(); rows = load(A.runs)
    if not rows: sys.exit("no trial found")
    df = pd.DataFrame(rows)
    for sysname, g in df.groupby("system"):
        g.dropna(axis=1, how="all").to_csv(f"{A.out}_{sysname}.csv", index=False)
    lines = []
    def out(*a): print(*a); lines.append(" ".join(str(x) for x in a))
    out(f"# Parsed trials (seed={A.seed})"); summarize(df, A.seed, out)
    open(f"{A.out}_summary.md", "w", encoding="utf-8").write("\n".join(lines) + "\n")
