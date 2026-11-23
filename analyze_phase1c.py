# analyze_phase1c.py - analyse de la Phase 1c (T_serv = délai heal -> première écriture de sonde acquittée)
import json,glob,os,re,sys
import numpy as np, pandas as pd
from scipy import stats
from scipy.stats import beta
R=sys.argv[1] if len(sys.argv)>1 else 'runs_v2'
def cp(k,n):
    lo=0 if k==0 else beta.ppf(.025,k,n-k+1); hi=1 if k==n else beta.ppf(.975,k+1,n-k); return float(round(100*lo,1)),float(round(100*hi,1))
def rc(m): return int(m['restarts_before'][m['isolated_pod']].split(',')[-1]), int(m['restarts_after'][m['isolated_pod']].split(',')[-1])
metas={}
for mp in glob.glob(f'{R}/pxc1c_ft*_hold*_*/t*/meta.json'):
    d=os.path.dirname(mp); m=json.load(open(mp,encoding='utf-8-sig')); metas[m['trial']]=(d,m,d.split('/')[-2].split('_')[-1])
ts=sorted(metas); rows=[]
for i,t in enumerate(ts):
    d,m,blk=metas[t]; tp,th0=m['t_partition_ms'],m['t_heal_start_ms']
    hp=[l.split(',',4) for l in open(d+'/hostprobe.log',encoding='utf-8-sig',errors='replace').read().splitlines() if l.count(',')>=3] if os.path.exists(d+'/hostprobe.log') else []
    hp=[(int(a[0]),int(a[1]),int(a[2]),int(a[3]),a[4] if len(a)>4 else '') for a in hp if a[0].isdigit()]
    ok=lambda x: x[3]==0 and 'ERROR' not in x[4]
    base=[x for x in hp if tp-10000<=x[0]<tp and ok(x)]
    after=[x for x in hp if x[0]>=th0]
    first=[x for x in after if ok(x)]
    fails=[x for x in after if not ok(x)]
    # restauration stable : début de la dernière série d'écritures acquittées qui court jusqu'à la fin du journal (>= 20 écritures)
    run=[]
    for x in reversed(hp):
        if ok(x): run.append(x)
        else: break
    stable=(run[-1][0]-th0)/1000 if len(run)>=20 and run[-1][0]>=th0 else np.nan
    b,a=rc(m); nb=None
    if i+1<len(ts) and metas[ts[i+1]][2]==blk:
        nb=rc(metas[ts[i+1]][1])[0]
        if nb<b: nb=None
    rows.append(dict(trial=t,block=blk,ft=int(re.search(r'_ft(\d)',d).group(1)),base_acks=len(base),
        restart=int(a>b or (nb is not None and nb>b)),
        t_first_ack_s=(first[0][0]-th0)/1000 if first else np.nan,
        t_serv_s=stable,
        last_fail_after_heal_s=(max(x[1] for x in fails)-th0)/1000 if fails else 0.0,
        n_fail_after_heal=len(fails),clock_ms=m.get('clock_offset_ms')))
P=pd.DataFrame(rows); P.to_csv('phase1c_trials.csv',index=False)
V=P[(P.base_acks>0)&P.t_serv_s.notna()]
print(f'trials {len(P)}, valid {len(V)} (baseline ack >=1 and a stable restoration observed)')
for blk,g in V.groupby('block'):
    k=int(g.restart.sum()); n=len(g)
    print(f'{blk}: ft={g.ft.iloc[0]} n={n} restarts {k}/{n} CI {cp(k,n)}  T_serv median {g.t_serv_s.median():.1f} (min {g.t_serv_s.min():.1f}, max {g.t_serv_s.max():.1f})')
A=V[V.ft==3].t_serv_s.values; B=V[V.ft==6].t_serv_s.values
if len(A) and len(B):
    d=np.median(A)-np.median(B); rng=np.random.default_rng(2026)
    bs=[np.median(rng.choice(A,len(A)))-np.median(rng.choice(B,len(B))) for _ in range(10000)]
    print(f'H9: median(A)-median(B) = {d:.1f} s, bootstrap 95% CI {np.percentile(bs,[2.5,97.5]).round(1)}, Mann-Whitney p = {stats.mannwhitneyu(A,B).pvalue:.2g}; threshold 5 s -> {"supported" if d>5 else "NOT supported"}')
    a1=V[V.block=='A1'].t_serv_s; a2=V[V.block=='A2'].t_serv_s
    if len(a1) and len(a2): print(f'H11 drift: |median(A1)-median(A2)| = {abs(a1.median()-a2.median()):.1f} s (limit 5 s)')
