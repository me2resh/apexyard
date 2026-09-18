#!/usr/bin/env python3
"""Structured Jev routing benchmark for issue #1341.

Unlike the first smoke test, each case supplies hook/event and change-risk
metadata, and each routing dimension is queried independently. This remains a
shadow benchmark; it does not alter framework hooks.
"""
from __future__ import annotations
import json, os, re, subprocess, sys, time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SECRET_FILE = Path.home() / ".config/codex/secrets/trading.env"
ENDPOINT = "https://api.typesafe.ai/v1/systemone"

CASES = [
 {"id":"bug_paraphrase","state":{"prompt":"Customers receive a reproducible 500 after yesterday's deployment.","event":"UserPromptSubmit","changed_paths":["src/api/orders.ts"],"ticket_type":"Bug","diff_files":1,"diff_lines":18,"reversible":True,"risk_flags":[]},"expected":{"skill":"bug","role":"none","ceremony":"standard"}},
 {"id":"spec_paraphrase","state":{"prompt":"Capture requirements and acceptance criteria for a CSV export flow.","event":"UserPromptSubmit","changed_paths":["docs/product/export.md"],"ticket_type":"Feature","diff_files":3,"diff_lines":90,"reversible":True,"risk_flags":[]},"expected":{"skill":"write-spec","role":"product-manager","ceremony":"standard"}},
 {"id":"security_paraphrase","state":{"prompt":"Assess this login change against common web application security risks.","event":"UserPromptSubmit","changed_paths":["src/auth/login.ts"],"ticket_type":"Chore","diff_files":2,"diff_lines":60,"reversible":True,"risk_flags":["auth"]},"expected":{"skill":"security-review","role":"security-auditor","ceremony":"heavy"}},
 {"id":"launch_paraphrase","state":{"prompt":"Check whether the service is ready for its production release.","event":"UserPromptSubmit","changed_paths":["src/api/app.ts",".github/workflows/release.yml"],"ticket_type":"Chore","diff_files":8,"diff_lines":260,"reversible":False,"risk_flags":["release"]},"expected":{"skill":"launch-check","role":"platform-engineer","ceremony":"heavy"}},
 {"id":"decision_paraphrase","state":{"prompt":"Record the decision between a scheduled job and an event trigger.","event":"UserPromptSubmit","changed_paths":["docs/agdr/AgDR-0200-job.md"],"ticket_type":"Chore","diff_files":1,"diff_lines":40,"reversible":True,"risk_flags":[]},"expected":{"skill":"decide","role":"tech-lead","ceremony":"standard"}},
 {"id":"neutral_read","state":{"prompt":"Show the current branch and recent commit.","event":"UserPromptSubmit","changed_paths":[],"ticket_type":"","diff_files":0,"diff_lines":0,"reversible":True,"risk_flags":[]},"expected":{"skill":"none","role":"none","ceremony":"lean"}},
 {"id":"role_backend","state":{"prompt":"Act as the backend engineer and review this repository layer.","event":"UserPromptSubmit","changed_paths":["src/domain/order.ts"],"ticket_type":"Refactor","diff_files":4,"diff_lines":130,"reversible":True,"risk_flags":[]},"expected":{"skill":"none","role":"backend-engineer","ceremony":"standard"}},
 {"id":"role_frontend","state":{"prompt":"As the frontend engineer, inspect this page implementation.","event":"UserPromptSubmit","changed_paths":["src/components/Table.tsx"],"ticket_type":"Feature","diff_files":5,"diff_lines":180,"reversible":True,"risk_flags":[]},"expected":{"skill":"none","role":"frontend-engineer","ceremony":"standard"}},
 {"id":"role_qa","state":{"prompt":"Put on your QA engineer hat and verify the acceptance criteria.","event":"UserPromptSubmit","changed_paths":["tests/order.test.ts"],"ticket_type":"Testing","diff_files":3,"diff_lines":100,"reversible":True,"risk_flags":[]},"expected":{"skill":"none","role":"qa-engineer","ceremony":"standard"}},
 {"id":"path_security","state":{"prompt":"Update the token parser.","event":"PreToolUse","tool_name":"Write","changed_paths":["src/auth/token-parser.ts"],"ticket_type":"Fix","diff_files":1,"diff_lines":12,"reversible":True,"risk_flags":["auth"]},"expected":{"skill":"none","role":"security-auditor","ceremony":"heavy"}},
 {"id":"path_platform","state":{"prompt":"Update the deployment workflow.","event":"PreToolUse","tool_name":"Write","changed_paths":[".github/workflows/deploy.yml"],"ticket_type":"CI","diff_files":1,"diff_lines":20,"reversible":True,"risk_flags":["deployment"]},"expected":{"skill":"none","role":"platform-engineer","ceremony":"heavy"}},
 {"id":"path_architecture","state":{"prompt":"Record the architecture migration decision.","event":"PreToolUse","tool_name":"Write","changed_paths":["docs/agdr/AgDR-0201.md"],"ticket_type":"Chore","diff_files":1,"diff_lines":80,"reversible":True,"risk_flags":["architecture"]},"expected":{"skill":"none","role":"tech-lead","ceremony":"standard"}},
 {"id":"lean_docs","state":{"prompt":"Change one README sentence and fix its link.","event":"UserPromptSubmit","changed_paths":["README.md"],"ticket_type":"Docs","diff_files":1,"diff_lines":2,"reversible":True,"risk_flags":[]},"expected":{"skill":"none","role":"none","ceremony":"lean"}},
 {"id":"heavy_migration","state":{"prompt":"Migrate production authentication and rotate its credentials.","event":"UserPromptSubmit","changed_paths":["src/auth/login.ts","migrations/2026-09-auth.sql",".github/workflows/deploy.yml"],"ticket_type":"Migration","diff_files":12,"diff_lines":600,"reversible":False,"risk_flags":["auth","migration","secrets","deployment"]},"expected":{"skill":"none","role":"security-auditor","ceremony":"heavy"}},
 {"id":"standard_api","state":{"prompt":"Add a read-only endpoint for the project list.","event":"UserPromptSubmit","changed_paths":["src/api/projects.ts","tests/projects.test.ts"],"ticket_type":"Feature","diff_files":2,"diff_lines":80,"reversible":True,"risk_flags":[]},"expected":{"skill":"none","role":"backend-engineer","ceremony":"standard"}},
]

def read_key():
    for raw in SECRET_FILE.read_text().splitlines():
        m=re.match(r"^\s*(?:export\s+)?JEV_API_KEY\s*=\s*(.*?)\s*$",raw)
        if m and m.group(1).strip().strip("'\""): return m.group(1).strip().strip("'\"")
    raise RuntimeError("JEV_API_KEY is missing from the local secret file")

def hook_baseline(state, hook):
    if state["event"] == "UserPromptSubmit": payload={"hook_event_name":"UserPromptSubmit","prompt":state["prompt"]}
    else: payload={"hook_event_name":"PreToolUse","tool_name":state.get("tool_name","Write"),"tool_input":{"file_path":state["changed_paths"][0]}}
    env=os.environ.copy(); env["CLAUDE_CODE_SESSION_ID"]=f"jev-corrected-{os.getpid()}"
    r=subprocess.run([str(ROOT/".claude/hooks"/hook)],input=json.dumps(payload),text=True,capture_output=True,cwd=ROOT,env=env,check=False)
    if hook == "detect-skill-intent.sh": return re.findall(r"matches the /([^\s]+) skill",r.stderr)
    display=re.findall(r"ROLE TRIGGER: ([^—]+?)(?: owns this kind of work| —)",r.stderr)
    names={"Security Auditor":"security-auditor","Platform Engineer":"platform-engineer","Tech Lead":"tech-lead","Backend Engineer":"backend-engineer","Frontend Engineer":"frontend-engineer","Qa Engineer":"qa-engineer"}
    return [names.get(n.strip(),n.strip().lower().replace(" ","-")) for n in display]

def local_ceremony(s):
    if s["risk_flags"] or not s["reversible"] or s["diff_files"]>=8 or s["diff_lines"]>=400: return "heavy"
    if s["diff_files"]<=1 and s["diff_lines"]<=10 and not s["risk_flags"]: return "lean"
    return "standard"

def ask(key,state,dimension,choices,instructions):
    q={"type":"choice","criteria":{c:f"The {c} label is correct" for c in choices},"instructions":instructions}
    body=json.dumps({"model":"jev-latest","state":state,"questions":{dimension:q}}).encode()
    req=Request(ENDPOINT,data=body,headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    start=time.perf_counter()
    try:
        with urlopen(req,timeout=30) as response: result=json.loads(response.read())
    except HTTPError as e: raise RuntimeError(f"Jev HTTP {e.code}") from None
    except URLError as e: raise RuntimeError(f"Jev network error: {e.reason}") from None
    return result.get("answers",{}).get(dimension,{}),(time.perf_counter()-start)*1000

def main():
    key=read_key()
    dimensions={"skill":(["bug","write-spec","security-review","decide","launch-check","none"],"Choose the single shipped skill whose workflow should be surfaced for this request. Use none when no skill is requested."),"role":(["backend-engineer","frontend-engineer","security-auditor","platform-engineer","tech-lead","qa-engineer","product-manager","none"],"Choose the single role that owns this work, using the event and changed paths. Use none when no role trigger applies."),"ceremony":(["lean","standard","heavy"],"Choose the smallest appropriate process ceremony from the supplied scope, reversibility, ticket, and risk metadata.")}
    rows=[]
    for case in CASES:
        state={**case["state"],"decision_source":"framework-routing-evaluation"}
        row={"id":case["id"],"expected":case["expected"],"baseline":{"skill":hook_baseline(state,"detect-skill-intent.sh"),"role":hook_baseline(state,"detect-role-trigger.sh"),"ceremony":local_ceremony(state)},"jev":{},"latency_ms":{}}
        for d,(choices,instructions) in dimensions.items():
            ans,latency=ask(key,state,d,choices,instructions); row["jev"][d]=ans.get("choice",""); row["jev"][f"{d}_confidence"]=ans.get("confidence"); row["latency_ms"][d]=round(latency,1)
        rows.append(row)
    summary={"generated_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"corpus_size":len(rows),"requests":len(rows)*len(dimensions),"rows":rows}
    for d in dimensions: summary[f"{d}_accuracy"]=round(sum(r["jev"][d]==r["expected"][d] for r in rows)/len(rows),3)
    summary["mean_latency_ms"]=round(sum(v for r in rows for v in r["latency_ms"].values())/summary["requests"],1)
    Path("/tmp/jev-routing-corrected.json").write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps({k:v for k,v in summary.items() if k!="rows"},indent=2))

if __name__ == "__main__": main()
