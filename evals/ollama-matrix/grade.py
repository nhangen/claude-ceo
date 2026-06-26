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
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEYS = json.loads(Path(os.environ.get("CEO_EVAL_KEYS", HERE / "keys.json")).read_text())["tasks"]
OUT = Path(os.environ.get("CEO_EVAL_OUT", HERE / "out"))
VERBOSE = "--verbose" in sys.argv


class EvalInfraError(Exception):
    """A grading failure caused by infrastructure, not model quality (interpreter
    won't launch, etc.). Routed to ERR + excluded from the summary, never a 0."""


def _resolve_python():
    py = os.environ.get("CEO_EVAL_PYTHON", sys.executable)
    if not py:
        sys.exit("CEO_EVAL_PYTHON is set but empty — unset it or point it at a python3 binary")
    if py != sys.executable and not (shutil.which(py) or os.path.exists(py)):
        sys.exit(f"CEO_EVAL_PYTHON={py!r} is not an executable; grading would crash mid-matrix")
    return py


def _run_script(script, timeout):
    """Execute a model script in an isolated interpreter. Raise EvalInfraError if
    the interpreter itself can't be launched (config error → ERR, not a model 0).
    Return (returncode, stdout, last_stderr); returncode is None on timeout."""
    try:
        p = subprocess.run([PYTHON, "-I", "-"], input=script,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", f"timeout>{timeout}s"
    except OSError as e:
        raise EvalInfraError(f"cannot launch {PYTHON!r}: {e}") from e
    return p.returncode, p.stdout, (p.stderr.strip().splitlines() or ["(no stderr)"])[-1]


PYTHON = _resolve_python()


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


def _extract_code(text):
    # Take the last fenced ```python/``` block (models explain, then give the
    # final function). Fall back to the whole body if there are no fences.
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", text, re.DOTALL | re.IGNORECASE)
    return blocks[-1] if blocks else text


def grade_code(text, key):
    # Run the model's function against a hidden battery of assert tests in an
    # isolated subprocess (per-test, for partial credit). A test passes iff the
    # script exits 0; a crash, wrong answer, or timeout fails that test only.
    code = _extract_code(text)
    tests = key["tests"]
    timeout = key.get("timeout", 10)
    passed, wrong = 0, []
    for i, t in enumerate(tests, 1):
        rc, _out, err = _run_script(f"{code}\n\n{t}\n", timeout)
        if rc == 0:
            passed += 1
        else:
            wrong.append((f"test{i}", "pass", err[:90]))
    return passed, len(tests), wrong


def grade_script(text, key):
    # Run the model's full script standalone, capture stdout, parse named numeric
    # values out of it, and score each boolean check (built from those values).
    # For stochastic/applied tasks where the contract is the program's OUTPUT, not
    # a fixed function signature.
    #
    # SAFETY: the eval() below executes ONLY the check expressions authored in
    # keys.json (trusted, version-controlled) — never model output. Model output
    # reaches eval solely as pre-parsed float values bound in `vals`; builtins are
    # disabled ({"__builtins__": {}}) so a check can't call anything. The model's
    # own code is run as a separate sandboxed subprocess (-I), not via this eval.
    code = _extract_code(text)
    timeout = key.get("timeout", 60)
    rc, out, _err = _run_script(f"{code}\n", timeout)
    vals = {}
    for name, pat in key["parse"].items():
        m = re.search(pat, out, re.IGNORECASE)
        try:
            vals[name] = float(m.group(1)) if m else None
        except (TypeError, ValueError):
            vals[name] = None
    checks = key["checks"]
    passed, wrong = 0, []
    for i, expr in enumerate(checks, 1):
        if None in vals.values():
            # A value the model never printed (crashed/timed-out/wrong output) is a
            # model failure, not a check to evaluate. rc surfaces why in the note.
            ok = False
        else:
            try:
                ok = bool(eval(expr, {"__builtins__": {}}, vals))
            except (NameError, SyntaxError) as e:
                # A typo'd/malformed check expression is a keys.json authoring bug,
                # not a model failure — fail loud rather than scoring it 0.
                sys.exit(f"KEY ERROR: check {expr!r} in keys.json is malformed: {e}")
            except Exception:
                ok = False
        if ok:
            passed += 1
        else:
            wrong.append((f"check{i}", expr, f"rc={rc} {str(vals)[:72]}"))
    return passed, len(checks), wrong


GRADERS = {
    "reconcile": grade_reconcile, "order": grade_order, "pair": grade_pair,
    "kv": grade_kv, "abstain": grade_abstain, "yesno": grade_yesno,
    "code": grade_code, "script": grade_script,
}


def write_scores_tsv(scores, models, out_dir, generated_at, task_order=None):
    """Persist per-(task, model) correctness as a stable, machine-readable
    contract for downstream consumers (the CEO min_score delegation gate),
    rather than forcing them to parse this script's printed table.

    `scores` is {model: {task: (correct, total) | None}}. A None entry (absent
    output or an ERR/infra failure) is omitted — the gate treats a missing
    score as "refuse", so it must not appear as a row. A total of 0 yields a
    blank ratio (never a div-by-zero). The write is atomic (temp + rename) so a
    reader mid-grade never observes a partial file. Models are written in the
    filename/dot form they already carry (e.g. `gpt-oss.20b`); the gate maps a
    registry model id to this form by replacing `:` with `.`."""
    out_dir = Path(out_dir)
    tasks = task_order if task_order is not None else sorted({t for m in scores for t in scores[m]})
    tmp = out_dir / "scores.tsv.tmp"
    final = out_dir / "scores.tsv"
    with tmp.open("w") as fh:
        fh.write(f"# generated_at={generated_at}\n")
        fh.write("task\tmodel\tcorrect\ttotal\tratio\n")
        for task in tasks:
            for m in models:
                s = scores.get(m, {}).get(task)
                if s is None:
                    continue
                got, tot = s
                ratio = f"{got / tot:.4f}" if tot else ""
                fh.write(f"{task}\t{m}\t{got}\t{tot}\t{ratio}\n")
    os.replace(tmp, final)
    return final


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
        # KEEP and CLOSE in the same verdict field must fail (exercises `and not CLOSE`).
        (grade_reconcile, {"items": {"T8": "KEEP"}}, "T8 | KEEP CLOSE #169 | hedging", 0),
        (grade_order, {"expect": "B,A,C"}, "ORDER: B, A, C", 1),
        (grade_order, {"expect": "B,A,C"}, "ORDER: A, B, C", 0),
        (grade_pair, {"expect": "S3,S4"}, "PAIR: S3 and S4", 1),
        (grade_pair, {"expect": "S3,S4"}, "PAIR: S1,S2", 0),
        (grade_kv, {"expect": {"NEXT": "2026-06-09 09:00"}}, "NEXT: 2026-06-09 at 9:00", 1),
        (grade_abstain, {"items": {"Q1": "INSUFFICIENT"}}, "Q1: INSUFFICIENT — not enough data", 1),
        (grade_abstain, {"items": {"Q1": "INSUFFICIENT"}}, "Q1: The answer is 42", 0),
        (grade_abstain, {"items": {"Q2": "ANSWER"}, "answerable_contains": {"Q2": "42"}},
         "Q2: The answer is 42", 1),
        (grade_abstain, {"items": {"Q2": "ANSWER"}, "answerable_contains": {"Q2": "42"}},
         "Q2: INSUFFICIENT", 0),
        (grade_yesno, {"expect": "YES"}, "ANSWER: NO", 0),
        (grade_code, {"tests": ["assert f(2) == 4"]}, "```python\ndef f(x): return x*2\n```", 1),
        (grade_code, {"tests": ["assert f(2) == 5"]}, "```python\ndef f(x): return x*2\n```", 0),
        (grade_code, {"tests": ["assert f(2) == 4"]}, "prose then\n```\ndef f(x): return x*2\n```\n", 1),
        # First block wrong, last block correct: exercises "take the LAST fenced block".
        (grade_code, {"tests": ["assert f(2) == 4"]},
         "```python\ndef f(x): return x*99\n```\nfixed:\n```python\ndef f(x): return x*2\n```", 1),
        (grade_script, {"parse": {"x": r"X:\s*([0-9.]+)", "y": r"Y:\s*([0-9.]+)"},
                        "checks": ["x < y", "y > 2*x"]},
         "```python\nprint('X: 6.3'); print('Y: 65.0')\n```", 2),
        (grade_script, {"parse": {"x": r"X:\s*([0-9.]+)"}, "checks": ["x < 5"]},
         "```python\nprint('X: 9.9')\n```", 0),
        # y never printed → None-guard fails the check that references only x.
        (grade_script, {"parse": {"x": r"X:\s*([0-9.]+)", "y": r"Y:\s*([0-9.]+)"},
                        "checks": ["x < 5"]},
         "```python\nprint('X: 1.0')\n```", 0),
    ]
    fails = 0
    for fn, key, text, want in cases:
        got = fn(text, key)[0]
        if got != want:
            fails += 1
            print(f"SELFTEST FAIL: {fn.__name__}({text!r}) -> {got}, want {want}")

    # write_scores_tsv: stable shape, total=0 handling, None/ERR omission, atomicity.
    import tempfile
    with tempfile.TemporaryDirectory() as _td:
        _sample = {
            "m1": {"think-01": (3, 4), "think-02": (0, 0), "think-03": None},
            "m2": {"think-01": (4, 4)},
        }
        _p = write_scores_tsv(_sample, ["m1", "m2"], _td, "2026-01-01T00:00:00Z",
                              task_order=["think-01", "think-02", "think-03"])
        _lines = Path(_p).read_text().splitlines()
        _checks = [
            (_lines[0] == "# generated_at=2026-01-01T00:00:00Z", "generated_at header"),
            (_lines[1] == "task\tmodel\tcorrect\ttotal\tratio", "column header"),
            ("think-01\tm1\t3\t4\t0.7500" in _lines, "ratio computed"),
            ("think-02\tm1\t0\t0\t" in _lines, "total=0 -> blank ratio, no div-by-zero"),
            (not any("think-03" in _l for _l in _lines), "None/ERR row omitted"),
            ("think-01\tm2\t4\t4\t1.0000" in _lines, "second model row"),
            (not (Path(_td) / "scores.tsv.tmp").exists(), "tmp removed after atomic rename"),
        ]
        for _ok, _desc in _checks:
            if not _ok:
                fails += 1
                print(f"SELFTEST FAIL: write_scores_tsv — {_desc}")

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
        try:
            got, total, wrong = grader(raw, key)
        except EvalInfraError as e:
            row += f"{'ERR':<22} "
            scores[m][task] = None
            print(f"    [{m}] {task}: INFRA {e}", file=sys.stderr)
            continue
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

generated_at = os.environ.get("CEO_SCORES_GENERATED_AT") \
    or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
scores_path = write_scores_tsv(scores, models, OUT, generated_at, task_order=list(KEYS))
print(f"\nwrote {scores_path}")
