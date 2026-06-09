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
        # Allow an optional list marker (-, *, 1.) before the ticket id; models
        # add these even when told not to. Match on the VERDICT field (between
        # the first two pipes) only — never the free-text reason, which legitimately
        # contains the word "close" ("no merged PR closes it").
        m = re.search(rf"^\s*(?:[-*]\s*|\d+[.)]\s*)?{tid}\b(.*)$", text, re.MULTILINE | re.IGNORECASE)
        rest = m.group(1) if m else ""
        parts = rest.split("|")
        verdict = parts[1] if len(parts) >= 2 else rest
        if expect == "KEEP":
            ok = bool(re.search(r"\bKEEP\b", verdict, re.IGNORECASE)) and not re.search(r"\bCLOSE\b", verdict, re.IGNORECASE)
        else:
            pr = expect.split(":")[1]
            cm = re.search(r"\bCLOSE\b\s*#?(\d+)", verdict, re.IGNORECASE)
            ok = bool(cm) and cm.group(1) == pr
        if not ok:
            wrong.append((tid, expect, (m.group(0) if m else "").strip()))
    return len(items) - len(wrong), len(items), wrong


def grade_order(text, key):
    m = re.search(r"ORDER:\s*([A-Za-z0-9 ,]+)", text, re.IGNORECASE)
    got = re.sub(r"[^A-Za-z0-9]", "", m.group(1)).upper() if m else ""
    exp = re.sub(r"[^A-Za-z0-9]", "", key["expect"]).upper()
    ok = got == exp
    return int(ok), 1, [] if ok else [("ORDER", key["expect"], m.group(1).strip() if m else "(no ORDER line)")]


def grade_pair(text, key):
    # Capture the rest of the line (tolerates "S3 and S4", "S3, S4", etc.);
    # findall isolates the ids regardless of separator.
    m = re.search(r"PAIR:\s*(.+)", text, re.IGNORECASE)
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


def _selftest():
    """Lock the extractors against the failure modes a review panel found:
    KEEP whose reason prose says "close", list-prefixed lines, "S3 and S4"
    separators, timestamp-format variance, and wrong answers still failing."""
    cases = [
        (grade_reconcile, {"items": {"T8": "KEEP"}},
         "T8 | KEEP | PR #169 would close this but is only proposed", 1),
        (grade_reconcile, {"items": {"T1": "CLOSE:165"}}, "- T1 | CLOSE #165 | retry", 1),
        (grade_reconcile, {"items": {"T1": "CLOSE:165"}}, "1. T1 | CLOSE #165 | retry", 1),
        (grade_reconcile, {"items": {"T1": "CLOSE:165"}}, "T1 | CLOSE #999 | wrong pr", 0),
        (grade_reconcile, {"items": {"T8": "KEEP"}}, "T8 | CLOSE #169 | proposed", 0),
        (grade_pair, {"expect": "S3,S4"}, "PAIR: S3 and S4", 1),
        (grade_pair, {"expect": "S3,S4"}, "PAIR: S1,S2", 0),
        (grade_kv, {"expect": {"NEXT": "2026-06-09 09:00"}}, "NEXT: 2026-06-09 at 9:00", 1),
        (grade_yesno, {"expect": "YES"}, "ANSWER: NO", 0),
    ]
    fails = 0
    for fn, key, text, want in cases:
        got = fn(text, key)[0]
        if got != want:
            fails += 1
            print(f"SELFTEST FAIL: {fn.__name__}({text!r}) -> {got}, want {want}")
    print("selftest: OK" if not fails else f"selftest: {fails} FAILED")
    sys.exit(1 if fails else 0)


if "--selftest" in sys.argv:
    _selftest()

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
        raw = f.read_text()
        # An empty file or a run.sh error sentinel means the call never produced
        # an answer (daemon down, model not pulled, HTTP/parse error). Score it
        # ERR, distinct from a wrong answer, and exclude it from the summary —
        # an infra failure must not read as a model-quality loss.
        if not raw.strip() or raw.lstrip().startswith("__EVAL_ERROR__"):
            row += f"{'ERR':<22} "
            scores[m][task] = None
            continue
        got, total, wrong = grader(raw, key)
        scores[m][task] = (got, total)
        row += f"{f'{got}/{total}':<22} "
        if VERBOSE and wrong:
            for w in wrong:
                print(f"    [{m}] {task} {w[0]}: expected {w[1]!r}, got {w[2]!r}")
    print(row)

print("\n=== summary (items correct / total) ===")
for m in models:
    vals = [s for s in scores[m].values() if s is not None]
    got = sum(s[0] for s in vals)
    tot = sum(s[1] for s in vals)
    pct = 100 * got / tot if tot else 0
    errs = sum(1 for s in scores[m].values() if s is None)
    note = f"  [{errs} task(s) ERR, excluded]" if errs else ""
    print(f"  {m:<24} {got}/{tot}  ({pct:.0f}%){note}")
