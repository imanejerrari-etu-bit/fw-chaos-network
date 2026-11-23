#!/usr/bin/env python3
"""Figures of the Phase 1 manuscript. Usage: python3 make_figures_v2.py --runs runs_v2 --out figures"""
import argparse, glob, json, os, re, datetime
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
P = argparse.ArgumentParser(); P.add_argument("--runs", default="runs_v2"); P.add_argument("--out", default="figures"); P.add_argument("--exclude", default="1,2")
A = P.parse_args(); os.makedirs(A.out, exist_ok=True); EXC = {int(x) for x in A.exclude.split(",") if x}
plt.rcParams.update({"font.size": 8.5, "axes.spines.top": False, "axes.spines.right": False})
J = lambda p: json.load(open(p, encoding="utf-8-sig"))
L = lambda p: [l.rstrip("\n") for l in open(p, encoding="utf-8-sig", errors="replace") if l.strip()] if os.path.exists(p) else []
ISO = re.compile(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?")
def tms(s):
    m = ISO.search(s)
    if not m: return None
    y, mo, d, h, mi, se, fr = m.groups()
    return int(datetime.datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), tzinfo=datetime.timezone.utc).timestamp() * 1000) + int((fr or "0")[:3].ljust(3, "0"))

# ---------------- Figure 1: MongoDB
rows = []
for mp in glob.glob(f"{A.runs}/mongo_*/t*/meta.json"):
    d = os.path.dirname(mp); m = J(mp); tp, th0 = m["t_partition_ms"], m["t_heal_start_ms"]
    w = [l.split(",", 3) for l in L(d + "/writer.log")]; w = [(int(a[0]), int(a[1]), a[3].strip()) for a in w if a[0].isdigit()]
    ok = [x for x in w if x[2] == "OK" and x[0] <= th0]
    el = []
    for pod in m["pods"]:
        for l in L(f"{d}/log_{pod}.txt"):
            if "Election succeeded" in l:
                mm = re.search(r'"\$date":"([^"]+)"', l); x = tms(mm.group(1)) if mm else None
                if x and x >= tp: el.append(x)
    rows.append(dict(wc=m["write_concern"], last_ack=(max(x[1] for x in ok) - tp) / 1000, election=(min(el) - tp) / 1000 if el else np.nan))
M = pd.DataFrame(rows)
fig, ax = plt.subplots(figsize=(5.6, 3.0))
rng = np.random.default_rng(1)
pos = {("w1", "last_ack"): 0, ("w1", "election"): 1, ("wmajority", "last_ack"): 2.4, ("wmajority", "election"): 3.4}
cols = {"last_ack": "#d95f02", "election": "#1b9e77"}
for (wc, k), x0 in pos.items():
    v = M[M.wc == wc][k].dropna().values
    ax.scatter(x0 + rng.uniform(-0.17, 0.17, len(v)), v, s=11, color=cols[k], alpha=0.8, linewidths=0)
    ax.hlines(np.median(v), x0 - 0.3, x0 + 0.3, color="k", lw=1.2)
ax.axhline(10, color="gray", ls=":", lw=0.9); ax.text(1.7, 11.6, "10 s election timeout", fontsize=7, color="gray", ha="center")
ax.set_xticks(list(pos.values())); ax.set_xticklabels(["last acked\nwrite", "first\nelection", "last acked\nwrite", "first\nelection"])
ax.text(0.5, -0.27, "w:1 (n=15)", ha="center", fontsize=8.5, transform=ax.get_xaxis_transform()); ax.text(2.9, -0.27, "w:majority (n=30)", ha="center", fontsize=8.5, transform=ax.get_xaxis_transform())
ax.set_ylabel("Seconds after partition start"); ax.set_ylim(-0.5, 13)
fig.tight_layout(); fig.subplots_adjust(bottom=0.27); fig.savefig(f"{A.out}/fig_mongo.pdf"); plt.close(fig)

# ---------------- Figure 2: PXC write raster
trials = []
for mp in glob.glob(f"{A.runs}/pxc_*/t*/meta.json"):
    d = os.path.dirname(mp); m = J(mp)
    if m["trial"] in EXC: continue
    trials.append((m["hold_s"], m["trial"], d, m))
trials.sort(key=lambda x: (x[0], x[1]))
fig, ax = plt.subplots(figsize=(6.6, 4.2))
style = {"ok": ("#2ca02c", "acknowledged"), "block": ("#ff7f0e", "no reply (client timeout)"), "rej": ("#d62728", "rejected (error 1047)"),
         "other": ("#9467bd", "other error"), "down": ("black", "server down")}
seen = set(); y = 0; ticks = []; sepy = None; prev = None
for hold, t, d, m in trials:
    if prev is not None and hold != prev: sepy = y - 0.5
    prev = hold
    ti, th0 = m["t_isolated_ms"], m["t_heal_start_ms"]
    xs = {k: [] for k in style}
    for l in L(d + "/writer.log"):
        p = l.split(",", 4)
        if len(p) < 4: continue
        s = (int(p[0]) - ti) / 1000; rc = int(p[3]); msg = p[4] if len(p) > 4 else ""
        k = "ok" if rc == 0 else "block" if rc == 124 else "rej" if "1047" in msg else "down" if any(c in msg for c in ("2002", "2013", "2003")) else "other"
        xs[k].append(s)
    for k, v in xs.items():
        if v: ax.scatter(v, [y] * len(v), s=3.5, marker="s", color=style[k][0], linewidths=0, label=style[k][1] if k not in seen else None); seen.add(k)
    ax.plot([(th0 - ti) / 1000] * 2, [y - 0.45, y + 0.45], color="k", lw=1.0)
    y += 1
ax.axvline(0, color="gray", lw=0.8, ls="--")
if sepy is not None: ax.axhline(sepy, color="gray", lw=0.6)
n20 = sum(1 for t in trials if t[0] == 20); n30 = len(trials) - n20
ax.text(1.01, 1 - (n20 / 2) / len(trials), f"hold 20 s\n(n={n20})", ha="left", va="center", fontsize=8, transform=ax.transAxes); ax.text(1.01, (n30 / 2) / len(trials), f"hold 30 s\n(n={n30})", ha="left", va="center", fontsize=8, transform=ax.transAxes)
ax.set_xlim(-10, 45); ax.set_ylim(-0.7, len(trials) - 0.3); ax.invert_yaxis(); ax.set_yticks([])
ax.set_xlabel("Seconds after the isolation of the PXC node (black tick: start of heal)")
ax.set_ylabel("Trials")
ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=5, fontsize=7, frameon=False, handletextpad=0.2, columnspacing=1.0, markerscale=2.2)
fig.tight_layout(); fig.savefig(f"{A.out}/fig_pxc.pdf", bbox_inches="tight"); plt.close(fig)
print("figures written:", len(trials), "PXC trials,", len(M), "MongoDB trials")
