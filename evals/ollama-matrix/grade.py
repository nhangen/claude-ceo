#!/usr/bin/env python3
"""Grade ollama-matrix model outputs against keys.json.

Reads out/<task>--<model>.txt produced by run.sh, extracts each model's
per-item verdict by regex (per the task's mode), scores against the key, and
prints a per-task / per-model score table plus a summary matrix. No subjective
judging — every task has a deterministic correct answer.

    python3 grade.py            # grade everything in out/
    python3 grade.py --verbose  # also print each wrong item
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEYS = json.loads((HERE / "keys.json").read_text())["tasks"]
OUT = HERE / "out"
VERBOSE = "--verbose" in sys.argv


def norm(s):
    return re.sub(r"\s+", " ", s.strip()).lower()


def grade_reconcile(text, key):
    items = key["items"]
    wrong = []
    for tid, expect in items.items():
        m = re.search(rf"^\s*{tid}\b.*$", text, re.MULTILINE | re.IGNORECASE)
        line = m.group(0) if m else ""
        if expect == "KEEP":
            ok = bool(re.search(r"\bKEEP\b", line, re.IGNORECASE)) and not re.search(r"\bCLOSE\b", line, re.IGNORECASE)
        else:
            pr = expect.split(":")[1]
            cm = re.search(r"\bCLOSE\b\s*#?(\d+)", line, re.IGNORECASE)
            ok = bool(cm) and cm.group(1) == pr
        if not ok:
            wrong.append((tid, expect, line.strip()))
    return len(items) - len(wrong), len(items), wrong


def grade_order(text, key):
    m = re.search(r"ORDER:\s*([A-Za-z0-9 ,]+)", text, re.IGNORECASE)
    got = re.sub(r"[^A-Za-z0-9]", "", m.group(1)).upper() if m else ""
    exp = re.sub(r"[^A-Za-z0-9]", "", key["expect"]).upper()
    ok = got == exp
    return int(ok), 1, [] if ok else [("ORDER", key["expect"], m.group(1).strip() if m else "(no ORDER line)")]


def grade_pair(text, key):
    m = re.search(r"PAIR:\s*([Ss0-9 ,]+)", text, re.IGNORECASE)
    got = set(re.findall(r"[Ss]\s*(\d+)", m.group(1))) if m else set()
    exp = set(re.findall(r"[Ss]\s*(\d+)", key["expect"]))
    ok = got == exp
    return int(ok), 1, [] if ok else [("PAIR", key["expect"], m.group(1).strip() if m else "(no PAIR line)")]


def _kv_match(expect, got):
    dt = re.search(r"(\d{4}-\d{2}-\d{2})\D+(\d{1,2}:\d{2})", expect)
    if dt:
        g = re.search(r"(\d{4}-\d{2}-\d{2})\D+(\d{1,2}:\d{2})", got)
        return bool(g) and g.group(1) == dt.group(1) and g.group(2).zfill(5) == dt.group(2).zfill(5)
    if re.fullmatch(r"\d+", expect.strip()):
        g = re.search(r"-?\d+", got)
        return bool(g) and g.group(0) == expect.strip()
    return norm(expect) in norm(got)


def grade_kv(text, key):
    exp = key["expect"]
    wrong = []
    for k, v in exp.items():
        m = re.search(rf"{k}:\s*(.+)", text, re.IGNORECASE)
        got = m.group(1).strip() if m else ""
        if not _kv_match(v, got):
            wrong.append((k, v, got or "(missing)"))
    return len(exp) - len(wrong), len(exp), wrong


def grade_abstain(text, key):
    items = key["items"]
    contains = key.get("answerable_contains", {})
    wrong = []
    for qid, kind in items.items():
        m = re.search(rf"^\s*{qid}:\s*(.+)$", text, re.MULTILINE | re.IGNORECASE)
        got = m.group(1).strip() if m else ""
        is_insuff = bool(re.search(r"\bINSUFFICIENT\b", got, re.IGNORECASE))
        if kind == "INSUFFICIENT":
            ok = is_insuff
        else:
            if qid in contains:
                ok = (not is_insuff) and bool(re.search(rf"\b{re.escape(contains[qid])}\b", got, re.IGNORECASE))
            else:
                ok = (not is_insuff) and bool(got)
        if not ok:
            wrong.append((qid, kind, got or "(missing)"))
    return len(items) - len(wrong), len(items), wrong


def grade_yesno(text, key):
    m = re.search(r"ANSWER:\s*(YES|NO)", text, re.IGNORECASE)
    got = m.group(1).upper() if m else ""
    ok = got == key["expect"].upper()
    return int(ok), 1, [] if ok else [("ANSWER", key["expect"], got or "(no ANSWER line)")]


GRADERS = {
    "reconcile": grade_reconcile, "order": grade_order, "pair": grade_pair,
    "kv": grade_kv, "abstain": grade_abstain, "yesno": grade_yesno,
}

models = sorted({p.name.split("--", 1)[1].rsplit(".txt", 1)[0]
                 for p in OUT.glob("*--*.txt")})
if not models:
    print(f"No outputs in {OUT}. Run run.sh first.", file=sys.stderr)
    sys.exit(1)

scores = {m: {} for m in models}
print(f"{'task':<28} {'dim':<26} " + " ".join(f"{m:<22}" for m in models))
for task, key in KEYS.items():
    grader = GRADERS[key["mode"]]
    row = f"{task:<28} {key['dimension']:<26} "
    for m in models:
        f = OUT / f"{task}--{m}.txt"
        if not f.exists():
            row += f"{'--':<22} "
            continue
        got, total, wrong = grader(f.read_text(), key)
        scores[m][task] = (got, total)
        row += f"{f'{got}/{total}':<22} "
        if VERBOSE and wrong:
            for w in wrong:
                print(f"    [{m}] {task} {w[0]}: expected {w[1]!r}, got {w[2]!r}")
    print(row)

print("\n=== summary (items correct / total) ===")
for m in models:
    got = sum(s[0] for s in scores[m].values())
    tot = sum(s[1] for s in scores[m].values())
    pct = 100 * got / tot if tot else 0
    print(f"  {m:<24} {got}/{tot}  ({pct:.0f}%)")
