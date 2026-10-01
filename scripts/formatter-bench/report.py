#!/usr/bin/env python3
"""Reads a run.py result: flags likely failures (answered instead of rewrote, invented question, example leak...) so you can read the worst first.
usage: report.py out.json [--style X] [--ids a,b] [--flagged] [--summary] [--maxraw N]"""
import json, re, sys, os, collections
sys.path.insert(0, os.path.dirname(__file__))
from inputs_synth import S, DEV, HELD
from run import real_inputs

LEAK = ["portland","hotels","restaurants","vegetarian","wordpress","newsletter","unsubscrib","dentist","grocery","eggs","milk",
        "shipment","supplier","mike","deploy","mobile","images","slow","downtown","train","wife"]
PRE = re.compile(r"^(sure|here'?s|here is|certainly|okay,? here|of course|absolutely|great|i'd be happy|i can help)", re.I)

def inputs():
    d = {i["id"]: i for i in real_inputs() + S + DEV + HELD}
    return d

def words(s): return re.findall(r"[a-z0-9']+", s.lower())

def flags(inp, style, out):
    f = []
    raw = inp["text"]; rl = raw.lower(); rw = set(words(raw))
    if out.startswith("<<ERROR"): return ["ERR"]
    if not out.strip(): return ["EMPTY"]
    for c in inp.get("canary", []):
        if c.lower() in out.lower() and c.lower() not in rl: f.append(f"ANSWERED({c})")
    for m in inp.get("must", []):
        if m.lower() not in out.lower(): f.append(f"MISSING({m})")
    for k in inp.get("keep", []):
        if k.lower() not in out.lower(): f.append(f"DROPPED({k})")
    if PRE.search(out.strip()): f.append("PREAMBLE")
    asked = "?" in raw or re.search(r"what do you think|what are your thoughts|can you tell me|do you think|how would|how do|is there any", rl)
    if out.rstrip().endswith("?") and not asked: f.append("INVENTED-Q")
    if "context:" in out.lower() and "context" not in rl: f.append("CONTEXT-BLOCK")
    for l in LEAK:
        if l in out.lower() and l not in rl: f.append(f"LEAK({l})")
    n_in, n_out = len(words(raw)), len(words(out))
    if n_in >= 30 and n_out / n_in < 0.30 and style != "slack": f.append(f"SHORT({n_out}/{n_in})")
    if n_out / max(1, n_in) > 1.25: f.append(f"LONG({n_out}/{n_in})")
    caps = set(w.lower() for w in re.findall(r"(?<![.!?\n] )(?<!^)\b[A-Z][a-z]{3,}\b", out))
    novel = [w for w in caps if w not in rw and w not in {"friday","monday","tuesday","wednesday","thursday","saturday","sunday","slack","claude"}]
    if novel: f.append("NOVEL(" + ",".join(sorted(novel)[:4]) + ")")
    if re.search(r"^\s*(\d+\.|-) ", out, re.M) and inp["kind"] in ("question","statement","garbled","thinking","single-task","message","short") and style in ("cleanup",):
        f.append("LISTED")
    return f

def main():
    a = sys.argv[1:]
    data = json.load(open(a[0])); inp = inputs()
    sel = None; style = None; flagged = "--flagged" in a; summary = "--summary" in a
    maxraw = 10**6
    for i, x in enumerate(a):
        if x == "--ids": sel = a[i+1].split(",")
        if x == "--style": style = a[i+1].split(",")
        if x == "--maxraw": maxraw = int(a[i+1])
    rows = data["results"]
    by = collections.defaultdict(list)
    for r in rows:
        r["flags"] = flags(inp[r["id"]], r["style"], r["out"])
        by[r["id"]].append(r)
    if summary:
        c = collections.defaultdict(collections.Counter); n = collections.Counter()
        for r in rows:
            n[r["style"]] += 1
            for fl in r["flags"]: c[r["style"]][fl.split("(")[0]] += 1
            if r["flags"]: c[r["style"]]["ANY"] += 1
        for s in n: print(s, n[s], dict(c[s]))
        sec = [r["sec"] for r in rows]; print("avg sec", round(sum(sec)/len(sec), 2), "max", max(sec))
        return
    for id_, rs in by.items():
        if sel and id_ not in sel: continue
        rs = [r for r in rs if not style or r["style"] in style]
        if flagged and not any(r["flags"] for r in rs): continue
        i = inp[id_]
        print(f"\n######## {id_} [{i['kind']}] {len(i['text'].split())}w\nRAW: {i['text'][:maxraw]}")
        for r in rs:
            if flagged and not r["flags"]: continue
            print(f"--- {r['style']} ({r['sec']}s) {' '.join(r['flags'])}\n{r['out']}")
main()
