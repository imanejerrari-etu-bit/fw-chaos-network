# Independent recomputation of the Phase 1 outcomes, written separately from parse_trials.py
import json,glob,os,re,datetime,collections
import numpy as np, pandas as pd
from scipy import stats
from scipy.stats import beta
R='runs_v2_lite'
def cp(k,n):
    lo=0 if k==0 else beta.ppf(.025,k,n-k+1); hi=1 if k==n else beta.ppf(.975,k+1,n-k); return round(100*lo,1),round(100*hi,1)
def J(p): return json.load(open(p,encoding='utf-8-sig'))
def lines(p): return [l.rstrip('\n') for l in open(p,encoding='utf-8-sig',errors='replace')] if os.path.exists(p) else []
ISO=re.compile(r'(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?')
def tms(s):
    m=ISO.search(s)
    if not m: return None
    y,mo,d,h,mi,se,fr=m.groups()
    return int(datetime.datetime(int(y),int(mo),int(d),int(h),int(mi),int(se),tzinfo=datetime.timezone.utc).timestamp()*1000)+int((fr or '0')[:3].ljust(3,'0'))
# ------------------------------------------------ PXC
rows=[]
metas={}
for mp in sorted(glob.glob(f'{R}/pxc_*/t*/meta.json')):
    d=os.path.dirname(mp); m=J(mp); metas[m['trial']]=(d,m)
trials=sorted(metas)
pxcidx={t:i for i,t in enumerate(trials)}
def rc_pxc(m): return int(m['restarts_before'][m['isolated_pod']].split(',')[-1]), int(m['restarts_after'][m['isolated_pod']].split(',')[-1])
for t in trials:
    d,m=metas[t]; tp,ti,th0,th=m['t_partition_ms'],m['t_isolated_ms'],m['t_heal_start_ms'],m['t_heal_ms']
    w=[l.split(',',4) for l in lines(d+'/writer.log') if l.strip()]
    w=[(int(a[0]),int(a[1]),int(a[2]),int(a[3]),a[4] if len(a)>4 else '') for a in w]
    present={int(x) for x in lines(d+'/present.txt') if x.strip().isdigit()}
    acked={x[2] for x in w if x[3]==0}
    ack_iso=[x for x in w if x[3]==0 and ti<=x[0]<=th0]
    nonack=[x for x in w if x[0]>=ti and x[3]!=0]
    n1047=sum('1047' in x[4] for x in w if ti<=x[0]<=th0)
    # restart via counters, corrected for the lag: compare with next trial's 'before'
    b,a=rc_pxc(m)
    nxt=None
    if pxcidx[t]+1<len(trials): nxt=rc_pxc(metas[trials[pxcidx[t]+1]][1])[0]
    restart=int(a>b or (nxt is not None and nxt>b))
    log=lines(f"{d}/log_{m['isolated_pod']}.txt")
    nonprim=sh=None; synced=None
    for l in log:
        x=tms(l)
        if x is None: continue
        if ti<=x<th0 and nonprim is None and ('primary = no' in l or 'Received NON-PRIMARY' in l): nonprim=x
        if x>=tp and sh is None and 'Received SHUTDOWN' in l: sh=x
        if x>=th0 and synced is None and re.search(r'Shifting \S+ -> SYNCED',l): synced=x
    rows.append(dict(trial=t,hold=m['hold_s'],valid=int(t not in (1,2)),log_ok=int(len(log)>=100),
        acked_after_isolation=len(ack_iso),first_nonack_s=(min(x[0] for x in nonack)-ti)/1000 if nonack else np.nan,
        n1047=n1047,lost_acked=len(acked-present),timeouts_present=len({x[2] for x in w if x[3]==124}&present),
        restart_counter_corrected=restart,shutdown_in_log=int(sh is not None) if log else np.nan,
        nonprimary_from_iso_s=(nonprim-ti)/1000 if nonprim else np.nan,
        rejoin_from_heal_start_s=(synced-th0)/1000 if synced else np.nan,
        shutdown_s_from_partition=(sh-tp)/1000 if sh else np.nan))
P=pd.DataFrame(rows); P.to_csv('independent_pxc.csv',index=False)
# ------------------------------------------------ Mongo
mrows=[]
for mp in sorted(glob.glob(f'{R}/mongo_*/t*/meta.json')):
    d=os.path.dirname(mp); m=J(mp); tp,ti,th0=m['t_partition_ms'],m['t_isolated_ms'],m['t_heal_start_ms']
    w=[l.split(',',3) for l in lines(d+'/writer.log') if l.strip()]
    w=[(int(a[0]),int(a[1]),int(a[2]),a[3].strip()) for a in w if a[0].isdigit()]
    present={int(x) for x in lines(d+'/present.txt') if x.strip().isdigit()}
    ok=[x for x in w if x[3]=='OK']; acked={x[2] for x in ok}
    ack_iso=[x for x in ok if ti<=x[0]<=th0]
    kinds=collections.Counter(x[3].split(':')[1] if x[3]!='OK' and ':' in x[3] else x[3] for x in w if x[0]>=ti and x[3]!='OK')
    el=[]
    for pod in m['pods']:
        for l in lines(f'{d}/log_{pod}.txt'):
            if 'Election succeeded' in l:
                mm=re.search(r'"\$date":"([^"]+)"',l); x=tms(mm.group(1)) if mm else None
                if x and x>=tp: el.append(x)
    el.sort()
    mrows.append(dict(trial=m['trial'],wc=m['write_concern'],lost_acked=len(acked-present),acked_after_isolation=len(ack_iso),
        last_ack_from_partition_s=(max(x[1] for x in ok if x[0]<=th0)-tp)/1000 if ok else np.nan,
        wc_failed=kinds.get('WriteConcernFailed',0),not_writable=kinds.get('NotWritablePrimary',0),
        present_not_acked=len(present-acked),elections=len(el),rto_first_s=(el[0]-tp)/1000 if el else np.nan,
        rto_first_from_iso_s=(el[0]-ti)/1000 if el else np.nan))
M=pd.DataFrame(mrows).sort_values('trial'); M.to_csv('independent_mongo.csv',index=False)
# ------------------------------------------------ report
out=[]
def o(*a): print(*a); out.append(' '.join(map(str,a)))
o('# Independent recomputation of the Phase 1 outcomes\n')
o('## MongoDB (hold 25 s)')
for wc,g in M.groupby('wc'):
    k=int((g.lost_acked>0).sum()); n=len(g)
    o(f'- {wc}: n={n}; trials with >=1 acknowledged-then-lost write: {k}/{n} (exact 95% CI {cp(k,n)}%); lost writes per trial mean {g.lost_acked.mean():.2f}, median {g.lost_acked.median():.0f}, min {g.lost_acked.min()}, max {g.lost_acked.max()}')
    k2=int((g.acked_after_isolation>0).sum())
    o(f'  - trials with >=1 acknowledged write after isolation: {k2}/{n}; mean acknowledged after isolation {g.acked_after_isolation.mean():.2f}')
    o(f'  - last acknowledged write, s after partition start: mean {g.last_ack_from_partition_s.mean():.2f}, min {g.last_ack_from_partition_s.min():.2f}, max {g.last_ack_from_partition_s.max():.2f}')
    r=g.rto_first_s.dropna(); o(f'  - first election, s after partition start: n={len(r)}, mean {r.mean():.2f}, median {r.median():.2f}, min {r.min():.2f}, max {r.max():.2f}; trials with 0 elections found: {int((g.elections==0).sum())}; with >1: {int((g.elections>1).sum())}')
    o(f'  - WriteConcernFailed per trial (after isolation): mean {g.wc_failed.mean():.2f}; writes present but not acknowledged: {int(g.present_not_acked.sum())}')
a=M[M.wc=='w1']; b=M[M.wc=='wmajority']
tab=[[int((a.lost_acked>0).sum()),int((a.lost_acked==0).sum())],[int((b.lost_acked>0).sum()),int((b.lost_acked==0).sum())]]
o(f'- Fisher exact (loss in w1 vs wmajority): {tab}, two-sided p = {stats.fisher_exact(tab)[1]:.3g}')
u=stats.mannwhitneyu(a.rto_first_s.dropna(),b.rto_first_s.dropna(),alternative='two-sided'); o(f'- first election, w1 vs wmajority: Mann-Whitney p = {u.pvalue:.3f}; w1 mean {a.rto_first_s.mean():.2f}, wmajority mean {b.rto_first_s.mean():.2f}')
o('\n## PXC')
V=P[P.valid==1]
o(f'- trials run: {len(P)} (hold 20: {int((P.hold==20).sum())}, hold 30: {int((P.hold==30).sum())}); valid after excluding trials 1 and 2 (rules aimed at a stale pod IP): {len(V)} (hold 20: {int((V.hold==20).sum())}, hold 30: {int((V.hold==30).sum())})')
for h,g in V.groupby('hold'):
    n=len(g); k=int((g.acked_after_isolation>0).sum()); l=int((g.lost_acked>0).sum()); rs=int(g.restart_counter_corrected.sum()); sh=g.shutdown_in_log.dropna()
    o(f'### hold {h} s (n={n})')
    o(f'- trials with an acknowledged write after isolation: {k}/{n} (exact CI {cp(k,n)}%); with an acknowledged-then-lost write: {l}/{n} (exact CI {cp(l,n)}%); writes that timed out on the client and were committed: {int(g.timeouts_present.sum())}')
    o(f'- first non-acknowledged write, s after isolation: median {g.first_nonack_s.median():.2f}, min {g.first_nonack_s.min():.2f}, max {g.first_nonack_s.max():.2f}')
    npm=g.nonprimary_from_iso_s.dropna(); o(f'- non-primary state seen in the log, s after isolation: n={len(npm)}, median {npm.median():.2f}, min {npm.min():.2f}, max {npm.max():.2f}')
    o(f'- error 1047 per trial: median {g.n1047.median():.0f}')
    o(f'- container restart (counter, lag-corrected): {rs}/{n} (exact CI {cp(rs,n)}%); mysqld shutdown signal in the log: {int(sh.sum())}/{len(sh)} trials with a usable log')
    rj=g.rejoin_from_heal_start_s.dropna(); o(f'- Synced from heal start, s: n={len(rj)}, median {rj.median():.2f}, min {rj.min():.2f}, max {rj.max():.2f}')
    ss=g.shutdown_s_from_partition.dropna()
    if len(ss): o(f'- shutdown signal, s after partition start: median {ss.median():.1f}, min {ss.min():.1f}, max {ss.max():.1f}')
a=V[V.hold==20]; b=V[V.hold==30]
tab=[[int(a.restart_counter_corrected.sum()),len(a)-int(a.restart_counter_corrected.sum())],[int(b.restart_counter_corrected.sum()),len(b)-int(b.restart_counter_corrected.sum())]]
o(f'- restart, hold 20 vs hold 30: {tab}; Fisher exact two-sided p = {stats.fisher_exact(tab)[1]:.3g}')
open('independent_results.md','w').write('\n'.join(out)+'\n')
