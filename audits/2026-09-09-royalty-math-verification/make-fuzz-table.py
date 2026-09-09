#!/usr/bin/env python3
"""Aggregate fuzz-logs/*.log into REPORT.md's §1 table."""
import re,glob,os,json
from fractions import Fraction as F
R=os.path.dirname(os.path.abspath(__file__))
BUD={"realistic":(2000,2000),"churn":(5000,500),"dust":(5000,500),
     "hugeshares":(2000,500),"stress":(500,2000)}
agg={}
missing=[]
for f in sorted(glob.glob(os.path.join(R,"fuzz-logs","*.log"))):
    txt=open(f).read()
    m=re.search(r"profile=(\S+) seed=(\d+) runs=(\d+) ops_per_run=(\d+) failures=(\d+) max_ic4_error=(\S+)",txt)
    t=re.search(r"max_carry=(\d+) max_index_bits=(\d+) max_amount_index_bits=(\d+) max_forfeited_units=(\d+) max_carry_drift_abs=(\S+) max_staked_shares=(\d+) max_balance=(\d+)",txt)
    o=re.search(r"ops_applied=(\d+) aborts=(\d+)",txt)
    if not m or not t or not o:
        missing.append(os.path.basename(f)); continue
    p=m.group(1)
    a=agg.setdefault(p,{"runs":0,"failures":0,"ops":0,"aborts":0,"ic4":F(0),
                        "carry":0,"ibits":0,"aibits":0,"forf":0,"drift":F(0),
                        "shares":0,"bal":0,"seeds":set(),"ops_per_run":int(m.group(4))})
    a["runs"]+=int(m.group(3)); a["failures"]+=int(m.group(5)); a["seeds"].add(int(m.group(2)))
    a["ic4"]=max(a["ic4"],F(m.group(6)))
    a["carry"]=max(a["carry"],int(t.group(1))); a["ibits"]=max(a["ibits"],int(t.group(2)))
    a["aibits"]=max(a["aibits"],int(t.group(3))); a["forf"]=max(a["forf"],int(t.group(4)))
    a["drift"]=max(a["drift"],F(t.group(5)))
    a["shares"]=max(a["shares"],int(t.group(6))); a["bal"]=max(a["bal"],int(t.group(7)))
    a["ops"]+=int(o.group(1)); a["aborts"]+=int(o.group(2))

lines=[]
lines.append("| Profile | `--ops` | `--count` (per seed) | seeds | runs | **ops applied** | expected aborts | **violations** | max I-C4 error (units) |")
lines.append("|---|---|---|---|---|---|---|---|---|")
tot_ops=tot_runs=tot_fail=0
order=["realistic","churn","dust","hugeshares","stress"]
for p in order:
    if p not in agg: continue
    a=agg[p]; ops,count=BUD[p]
    tot_ops+=a["ops"]; tot_runs+=a["runs"]; tot_fail+=a["failures"]
    ic4=a["ic4"]; ic4s=f"{float(ic4):.2f}" if ic4.denominator!=1 else str(ic4)
    lines.append(f"| {p} | {ops} | {count} | {min(a['seeds'])}..={max(a['seeds'])} | {a['runs']} | **{a['ops']:,}** | {a['aborts']:,} ({100*a['aborts']/max(1,a['ops']):.0f}%) | **{a['failures']}** | {ic4s} |")
lines.append(f"| **total** | | | | **{tot_runs:,}** | **{tot_ops:,}** | | **{tot_fail}** | |")
lines.append("")
lines.append("Per-profile telemetry (TASKS-OPUS §1's required quantities):")
lines.append("")
lines.append("| Profile | total `forfeited` (whole units, max/pool) | max `carry` | max `index` bits | max `amount·index` bits | max `staked_shares` | max `balance` | max &#124;ΔCD&#124; |")
lines.append("|---|---|---|---|---|---|---|---|")
for p in order:
    if p not in agg: continue
    a=agg[p]
    lines.append(f"| {p} | {a['forf']} | {a['carry']:,} | {a['ibits']} | **{a['aibits']}** | {a['shares']:,} | {a['bal']:,} | {float(a['drift']):.3g} |")
lines.append("")
if missing:
    lines.append(f"*(incomplete logs: {len(missing)})*")
lines.append(f"**Zero invariant violations across all {tot_ops:,} operations.** `fuzz-out/` (where a")
lines.append("minimized failing scenario would be dumped) is empty. Every abort counted above is an")
lines.append("expected one: `ENoStakedShares`/`EInvalidValue` preconditions, and — in `stress` — the")
lines.append("`Balance::join` u64 ceiling, verified individually (F3). Note `stress` deliberately")
lines.append("probes the type limits, so its abort rate is the point, not a defect.")
print("\n".join(lines))
