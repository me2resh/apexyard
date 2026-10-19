import json,glob,os,re,statistics as st,sys
sys.path.insert(0,'bin')
import importlib.util
spec=importlib.util.spec_from_file_location('tc','bin/token-cost.py');tc=importlib.util.module_from_spec(spec);spec.loader.exec_module(tc)
rows=[]
for meta in glob.glob(os.path.expanduser('~/.claude/projects/-Users-ahmed-Projects-Apex-apexyard/*/subagents/*.meta.json')):
    m=json.load(open(meta))
    if m.get('agentType')!='code-reviewer': continue
    f=meta.replace('.meta.json','.jsonl')
    reqs={};first=None
    for line in open(f):
        try:r=json.loads(line)
        except:continue
        if first is None and r.get('type')=='user':
            c=r['message']['content'];first=c if isinstance(c,str) else json.dumps(c)
        if r.get('type')=='assistant':
            mid=r['message'].get('id');u=r['message'].get('usage')
            if mid and u: reqs[mid]=tc.usage_numbers(u)
    if not reqs: continue
    inp=sum(v[0] for v in reqs.values());cc=sum(v[1] for v in reqs.values());cr=sum(v[2] for v in reqs.values());out=sum(v[3] for v in reqs.values())
    d=bool(re.search(r'delta|re-review|since (the )?(last|prior|previous)|previously approved|prior approval|incremental',first or '',re.I))
    appr=bool(re.search(r'prior (rex )?approv|previously approved|already approved|rex-approved',first or '',re.I))
    rows.append((d,appr,inp+cc+out,out,cr,len(reqs),inp,cc))
for lab,sel in (('all',lambda r:True),('delta-ish',lambda r:r[0]),('delta+prior-approval',lambda r:r[0] and r[1])):
    s=[r for r in rows if sel(r)]
    if not s: print(lab,0);continue
    tot=sum(r[2] for r in s);out=sum(r[3] for r in s)
    w=lambda r:5*r[3]+r[6]+2*r[7]+0.1*r[4]
    print(lab,'cost_weighted_out_share %.1f%%'%(100*sum(5*r[3] for r in s)/sum(w(r) for r in s)),'mean_turns',round(sum(r[5] for r in s)/len(s),1));print(lab,len(s),'mean_uncached',round(tot/len(s)),'mean_out',round(out/len(s)),'out_share_uncached %.1f%%'%(100*out/tot),'mean_cacheread',round(sum(r[4] for r in s)/len(s)))
