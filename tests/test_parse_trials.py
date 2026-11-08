"""Synthetic fixtures: checks the parser on known values. Run: python3 tests/test_parse_trials.py"""
import json, os, sys, tempfile, importlib.util
from datetime import datetime, timezone
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import parse_trials as pt

def iso(ms, z=True):
    d = datetime.fromtimestamp(ms / 1000, tz=timezone.utc); s = d.strftime("%Y-%m-%dT%H:%M:%S") + f".{ms % 1000:03d}000"
    return s + ("Z" if z else "")

T0 = 1_785_000_000_000
tmp = tempfile.mkdtemp()

# ---------------- PXC fixture: partition at T0+10 s, heal at T0+35 s, writer 4/s
d = os.path.join(tmp, "pxc_partition_v2", "t001"); os.makedirs(d)
tp, th = T0 + 10_000, T0 + 35_000
json.dump(dict(system="pxc", campaign="pxc_partition_v2", trial=1, t_partition_ms=tp, t_heal_ms=th, hold_s=25,
               isolated_pod="pxc-0", pods=["pxc-0", "pxc-1", "pxc-2"]), open(os.path.join(d, "meta.json"), "w"))
w, present = [], []
for i in range(1, 160):
    s = T0 + i * 250; seq = 1_000_000 + i
    if s < tp + 3_000 or s > th + 2_000:                      # acknowledged before detection (3 s) and after heal
        w.append(f"{s},{s+20},{seq},0,"); present.append(seq) if i != 50 else None   # seq 1000050 acknowledged but lost
    else:
        w.append(f"{s},{s+30},{seq},1,ERROR 1047 (08S01) at line 1: WSREP has not yet prepared node")
open(os.path.join(d, "writer.log"), "w").write("\n".join(w) + "\n")
open(os.path.join(d, "present.txt"), "w").write("\n".join(map(str, present)) + "\n")
log = [f"{iso(tp+3100)} 0 [Note] [MY-000000] [WSREP] New COMPONENT: primary = no, bootstrap = no, my_idx = 0, memb_num = 1",
       f"{iso(th+2300)} 0 [Note] [MY-000000] [WSREP] Shifting OPEN -> PRIMARY (TO: 10)",
       f"{iso(th+2400)} 0 [Note] [MY-000000] [WSREP] Receiving IST: 12 writesets, seqnos 10-22",
       f"{iso(th+9400)} 0 [Note] [MY-000000] [WSREP] Shifting JOINED -> SYNCED (TO: 22)", "continuation line without timestamp"]
open(os.path.join(d, "log_pxc-0.txt"), "w").write("\n".join(log) + "\n")
open(os.path.join(d, "status_poll.csv"), "w").write(
    f"{th+1000},pxc-0,wsrep_cluster_size 1 wsrep_cluster_status non-Primary wsrep_local_state_comment Initialized wsrep_ready OFF\n"
    f"{th+9900},pxc-0,wsrep_cluster_size 3 wsrep_cluster_status Primary wsrep_local_state_comment Synced wsrep_ready ON\n")

# ---------------- Mongo fixture: w:1, isolated primary acknowledges 12 s, then NotWritablePrimary
d2 = os.path.join(tmp, "mongo_w1_v2", "t002"); os.makedirs(d2)
json.dump(dict(system="mongo", campaign="mongo_w1_v2", trial=2, write_concern="w1", t_partition_ms=tp, t_heal_ms=th, hold_s=25,
               isolated_pod="m-0", pods=["m-0", "m-1", "m-2"]), open(os.path.join(d2, "meta.json"), "w"))
w, present = [], []
for i in range(1, 200):
    s = T0 + i * 200; seq = 2_000_000 + i
    if s < tp + 12_000:
        w.append(f"{s},{s+5},{seq},OK")
        if not (tp <= s < tp + 12_000 and i % 2 == 0 and False): present.append(seq)
    else:
        w.append(f"{s},{s+5},{seq},ERR:NotWritablePrimary:10107")
# drop the writes acknowledged after t_partition+1 s from the final state (rolled back)
present = [x for x in present if not (tp + 1_000 <= T0 + (x - 2_000_000) * 200 < tp + 12_000)]
open(os.path.join(d2, "writer.log"), "w").write("\n".join(w) + "\n")
open(os.path.join(d2, "present.txt"), "w").write("\n".join(map(str, present)) + "\n")
el = json.dumps({"t": {"$date": iso(tp + 11_500, z=False).replace(".500000", ".500") + "+00:00"}, "msg": "Election succeeded, assuming primary role in term 2"})
el2 = json.dumps({"t": {"$date": iso(th + 3_000, z=False).replace(".000000", ".000") + "+00:00"}, "msg": "Election succeeded, assuming primary role in term 3"})
open(os.path.join(d2, "log_m-1.txt"), "w").write(el + "\n" + el2 + "\n")
open(os.path.join(d2, "log_m-0.txt"), "w").write(json.dumps({"t": {"$date": iso(tp + 10_300, z=False)[:-3] + "+00:00"}, "msg": "Stepping down from primary, because I cannot see a majority"}) + "\n")

rows = {r["campaign"]: r for r in pt.load(tmp)}
p, m = rows["pxc_partition_v2"], rows["mongo_w1_v2"]
def close(a, b, tol=0.05): return abs(a - b) <= tol
checks = [
    ("pxc lost_acked == 1", p["lost_acked"] == 1),
    ("pxc n_err1047 > 0", p["n_err1047"] > 0),
    ("pxc first non-ack ~3 s", close(p["first_nonack_after_partition_s"], 3.0, 0.3)),
    ("pxc last ack in partition ~3 s", close(p["last_ack_in_partition_s"], 3.0, 0.3)),
    ("pxc rejoin_log 9.4 s", close(p["rejoin_log_s"], 9.4)),
    ("pxc rejoin_poll 9.9 s", close(p["rejoin_poll_s"], 9.9)),
    ("pxc nonprimary_log 3.1 s", close(p["nonprimary_log_s"], 3.1)),
    ("pxc transfer ist", p["transfer_type"] == "ist"),
    ("mongo acked during partition > 0", m["n_acked_during_partition"] > 0),
    ("mongo lost_acked > 0", m["lost_acked"] > 0),
    ("mongo rto_first 11.5 s", close(m["rto_first_s"], 11.5)),
    ("mongo rto_last 28.0 s", close(m["rto_last_s"], 28.0)),
    ("mongo 2 elections", m["n_elections_after_partition"] == 2),
    ("mongo stepdown 10.3 s", close(m["stepdown_log_s"], 10.3)),
]
bad = [n for n, ok in checks if not ok]
for n, ok in checks: print(("PASS " if ok else "FAIL ") + n)
if bad: print("\nvalues:", {k: p[k] for k in ("lost_acked","first_nonack_after_partition_s","last_ack_in_partition_s","rejoin_log_s","rejoin_poll_s","nonprimary_log_s","transfer_type")},
              {k: m[k] for k in ("lost_acked","n_acked_during_partition","rto_first_s","rto_last_s","n_elections_after_partition","stepdown_log_s")}); sys.exit(1)
print("\nall checks passed")
