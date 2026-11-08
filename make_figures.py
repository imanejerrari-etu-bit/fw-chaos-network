#!/usr/bin/env python3
"""Generates the manuscript figures from the released CSV files.
Usage: python3 make_figures.py [--data DIR] [--out DIR]"""
import argparse, os
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.stats import beta

P = argparse.ArgumentParser(); P.add_argument("--data", default="."); P.add_argument("--out", default="figures")
A = P.parse_args(); os.makedirs(A.out, exist_ok=True)
rd = lambda n: pd.read_csv(os.path.join(A.data, n), encoding="utf-8-sig")
def cp(k, n):
    lo = 0.0 if k == 0 else beta.ppf(0.025, k, n - k + 1); hi = 1.0 if k == n else beta.ppf(0.975, k + 1, n - k)
    return 100 * lo, 100 * hi
plt.rcParams.update({"font.size": 9, "axes.grid": True, "grid.alpha": 0.25, "axes.spines.top": False, "axes.spines.right": False})

# Figure 1: Scenario 1 distributions
m = rd("campaign_rpo_mongodb_n30_v3.csv"); cb = rd("campaign_pxc_partition_combined_n59.csv")
fig, ax = plt.subplots(1, 3, figsize=(10, 2.9))
ax[0].hist(m.rto_seconds, bins=np.arange(11, 25, 1.0), color="#3b7dbf", edgecolor="white")
ax[0].axvline(m.rto_seconds.mean(), color="k", ls=":", lw=1); ax[0].set(title=f"MongoDB RTO (n={len(m)})", xlabel="RTO (s)", ylabel="Trial count")
ax[1].hist(m.rpo_count, bins=np.arange(43, 80, 3), color="#f08c2a", edgecolor="white")
ax[1].axvline(m.rpo_count.mean(), color="k", ls=":", lw=1); ax[1].set(title=f"MongoDB RPO (n={len(m)})", xlabel="RPO (writes lost)")
r = cb.rejoin_seconds
ax[2].hist(r, bins=np.logspace(np.log10(0.15), np.log10(120), 22), color="#4aa24a", edgecolor="white")
ax[2].set_xscale("log"); ax[2].set(title=f"PXC rejoin (n={len(r)}, polled every 10 s)", xlabel="Rejoin time (s, log scale)")
fig.tight_layout(); fig.savefig(os.path.join(A.out, "fig_scenario1.pdf")); plt.close(fig)

# Figure 2: Scenario 3 transition
mj = rd("campaign_jitter_mongodb_FINAL_n30.csv"); pj = rd("campaign_pxc_jitter_n30.csv")
fig, ax = plt.subplots(1, 2, figsize=(8.5, 3))
for a, d, col, key, lab, ylab, col_c in [
        (ax[0], mj, "#1f6fb2", "election_triggered", "MongoDB", "Election triggered (%)", "#444"),
        (ax[1], pj, "#d62728", "excluded", "PXC (Galera)", "Node excluded (%)", "#444")]:
    g = d.groupby("delay_ms")[key].agg(["sum", "count"]).reset_index()
    x = g.delay_ms / 1000; y = 100 * g["sum"] / g["count"]
    ci = np.array([cp(int(k), int(n)) for k, n in zip(g["sum"], g["count"])])
    a.errorbar(x, y, yerr=[y - ci[:, 0], ci[:, 1] - y], fmt="o-", color=col, capsize=3, lw=1.3)
    a.set(title=lab, xlabel="Injected delay (s)", ylabel=ylab, ylim=(-5, 105))
ax[0].axvline(10, color="gray", ls=":", lw=1); ax[0].text(10.3, 45, "electionTimeoutMillis\n= 10 s", fontsize=7, color="gray")
ax[1].axvline(3, color="gray", ls=":", lw=1); ax[1].text(3.3, 45, "gmcast.peer_timeout\n= 3 s", fontsize=7, color="gray")
fig.tight_layout(); fig.savefig(os.path.join(A.out, "fig_scenario3.pdf")); plt.close(fig)
print("figures written to", A.out)
