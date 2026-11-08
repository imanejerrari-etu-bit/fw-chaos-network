#!/usr/bin/env python3
"""
Reproduces every statistic reported in the manuscript from the released CSV files.

Usage:   python3 analysis.py [--data DIR] [--seed 2026] [--out analysis_output.md]
Needs:   numpy, pandas, scipy (scipy >= 1.9 for the BCa bootstrap)

Conventions
  * Continuous outcomes: BCa bootstrap 95% CI of the MEAN, 10,000 resamples, fixed seed.
  * Proportions: exact Clopper-Pearson 95% intervals.
  * PXC rejoin groups are defined by duration (< 2 s, 2-15 s, > 15 s). The 'likely_sst'
    column is reported separately: its definition is not documented in the data files.
  * MongoDB latency outliers: triggered trials with RTO >= 20 s (threshold chosen
    after inspecting the data; reported explicitly).
"""
import argparse, io, os, sys
import numpy as np, pandas as pd
from scipy import stats
from scipy.stats import beta

P = argparse.ArgumentParser()
P.add_argument("--data", default=".")
P.add_argument("--seed", type=int, default=2026)
P.add_argument("--out", default="analysis_output.md")
A = P.parse_args()
buf = io.StringIO()
def out(*a):
    print(*a); print(*a, file=buf)

def rd(name):
    return pd.read_csv(os.path.join(A.data, name), encoding="utf-8-sig")

def cp(k, n, alpha=0.05):
    lo = 0.0 if k == 0 else beta.ppf(alpha / 2, k, n - k + 1)
    hi = 1.0 if k == n else beta.ppf(1 - alpha / 2, k + 1, n - k)
    return 100 * lo, 100 * hi

def bca_mean(x):
    r = stats.bootstrap((np.asarray(x, float),), np.mean, n_resamples=10000,
                        confidence_level=0.95, method="BCa", random_state=A.seed)
    return r.confidence_interval.low, r.confidence_interval.high

def prop(k, n):
    lo, hi = cp(k, n); return f"{k}/{n} ({100*k/n:.1f}%, exact 95% CI [{lo:.1f}, {hi:.1f}]%)"

out(f"# Analysis output (seed={A.seed})\n")

# ---------------------------------------------------------------- MongoDB, Scenario 1
m = rd("campaign_rpo_mongodb_n30_v3.csv")
out("## MongoDB, Scenario 1 (complete partition)")
out(f"n = {len(m)}")
for col, lab in [("rto_seconds", "RTO (s)"), ("rpo_count", "RPO (writes lost)")]:
    x = m[col].astype(float); lo, hi = bca_mean(x)
    out(f"- {lab}: mean {x.mean():.2f}, median {x.median():.2f}, sd {x.std():.2f}, "
        f"min {x.min():.2f}, max {x.max():.2f}, BCa 95% CI of the mean [{lo:.2f}, {hi:.2f}], "
        f"Shapiro-Wilk p = {stats.shapiro(x).pvalue:.4g}")
nseq = m.rpo_seq_list.fillna("").apply(lambda s: 0 if s == "" else len(s.split("|")))
out(f"- rpo_count equals the length of rpo_seq_list in {(nseq == m.rpo_count).sum()}/{len(m)} trials")
for rate in (3.7, 4.0):
    out(f"- acknowledged-but-lost window at {rate} writes/s: {m.rpo_count.mean() / rate:.1f} s")
out()

# ---------------------------------------------------------------- PXC, Scenario 1
c1 = rd("campaign_pxc_partition_campaign1_n30.csv")
c2 = rd("campaign_pxc_partition_campaign2_n30.csv")
cb = rd("campaign_pxc_partition_combined_n59.csv")
out("## PXC, Scenario 1 (complete partition)")
rej = int(c1.write_rejected.sum() + c2.write_rejected.sum()); tot = len(c1) + len(c2)
out(f"- writes rejected on the isolated node: {prop(rej, tot)}")
comb_ok = np.allclose(np.sort(cb.rejoin_seconds.values),
                      np.sort(pd.concat([c1.rejoin_seconds, c2.rejoin_seconds]).dropna().values))
out(f"- combined file equals campaign 1 (non-missing) + campaign 2: {comb_ok}; "
    f"missing rejoin times: {int(c1.rejoin_seconds.isna().sum() + c2.rejoin_seconds.isna().sum())}")
r = cb.rejoin_seconds; n = len(r)
groups = [("under 2 s", r < 2), ("2-15 s", (r >= 2) & (r <= 15)), ("over 15 s", r > 15)]
out(f"- rejoin groups by duration (n = {n}):")
for lab, mask in groups:
    x = r[mask]
    out(f"  - {lab}: {len(x)} ({100*len(x)/n:.1f}%), range {x.min():.1f}-{x.max():.1f} s")
mid = r[(r >= 2) & (r <= 15)]
out(f"  - inside 2-15 s: {int((mid < 5).sum())} trials at {mid[mid < 5].min():.1f}-{mid[mid < 5].max():.1f} s; "
    f"{int((mid >= 5).sum())} trials at {mid[mid >= 5].min():.1f}-{mid[mid >= 5].max():.1f} s "
    f"({int(((mid >= 10.4) & (mid <= 10.5)).sum())} of them at 10.4-10.5 s)")
out(f"- 'likely_sst' flag (definition undocumented): {int(cb.likely_sst.sum())}/{n} trials; "
    f"flagged rejoin times: {sorted(cb[cb.likely_sst].rejoin_seconds.tolist())}")
c1v = c1.dropna(subset=["rejoin_seconds"])
out("- campaign comparison (Fisher exact, two-sided):")
for lab, f in [("rejoin > 15 s", lambda d: d.rejoin_seconds > 15),
               ("rejoin < 2 s", lambda d: d.rejoin_seconds < 2),
               ("likely_sst flag", lambda d: d.likely_sst)]:
    a, b = int(f(c1v).sum()), int(f(c2).sum())
    p = stats.fisher_exact([[a, len(c1v) - a], [b, len(c2) - b]])[1]
    out(f"  - {lab}: campaign 1 {a}/{len(c1v)}, campaign 2 {b}/{len(c2)}, p = {p:.4f}")
u = stats.mannwhitneyu(c1v.rejoin_seconds, c2.rejoin_seconds, alternative="two-sided")
out(f"  - rejoin_seconds, Mann-Whitney p = {u.pvalue:.3f}")
out(f"- 'detection_immediate' column (definition undocumented): campaign 1 "
    f"{int(c1.detection_immediate.sum())}/{len(c1)} True, campaign 2 {int(c2.detection_immediate.sum())}/{len(c2)} True")
out()

# ---------------------------------------------------------------- MongoDB, Scenario 3
mj = rd("campaign_jitter_mongodb_FINAL_n30.csv")
out("## MongoDB, Scenario 3 (latency/jitter)")
out(f"jitter sigma (ms) values used: {sorted(mj.jitter_ms.unique().tolist())}")
for d, g in mj.groupby("delay_ms"):
    k = int(g.election_triggered.sum()); t = g[g.election_triggered]
    extra = f", mean RTO of triggered {t.rto_seconds.mean():.2f} s" if len(t) else ""
    out(f"- {d/1000:g} s: {prop(k, len(g))}{extra}")
t = mj[mj.election_triggered]
core = t[t.rto_seconds < 20].rto_seconds
out(f"- triggered trials: {len(t)}; non-outlier (RTO < 20 s): {len(core)}, mean {core.mean():.2f} s, "
    f"sd {core.std():.2f}, range {core.min():.2f}-{core.max():.2f} s")
for _, row in t[t.rto_seconds >= 20].iterrows():
    out(f"  - outlier: delay {row.delay_ms/1000:g} s, trial {int(row.trial)}, RTO {row.rto_seconds:.2f} s")
out()

# ---------------------------------------------------------------- PXC, Scenario 3
pj = rd("campaign_pxc_jitter_n30.csv")
out("## PXC, Scenario 3 (latency/jitter)")
out(f"jitter sigma (ms) values used: {sorted(pj.jitter_ms.unique().tolist())}")
for d, g in pj.groupby("delay_ms"):
    out(f"- {d/1000:g} s: excluded {prop(int(g.excluded.sum()), len(g))}")
hi_ = pj[pj.delay_ms >= 3000]
out(f"- delays >= 3 s pooled: excluded {prop(int(hi_.excluded.sum()), len(hi_))}")
out(f"- recovery after delay removal: {prop(int(pj.recovered_after.sum()), len(pj))}")
out()

# ---------------------------------------------------------------- PXC, Scenario 2
s2 = rd("campaign_pxc_scenario2_n9.csv")
out("## PXC, Scenario 2 (asymmetric degradation, automated trials only)")
out(f"n = {len(s2)}; trials per node pair: {s2.groupby('pair').size().tolist()}")
out(f"- cluster stayed healthy: {prop(int(s2.cluster_stayed_healthy.sum()), len(s2))}")
out(f"- write OK on node A / node B: {int(s2.write_a_ok.sum())}/{len(s2)} and {int(s2.write_b_ok.sum())}/{len(s2)}")
out("- NOT IN THIS REPOSITORY: the 12 MongoDB Scenario 2 trials and the 2 manual PXC trials reported in the paper")

with open(A.out, "w", encoding="utf-8") as f:
    f.write(buf.getvalue())
