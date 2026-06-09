# ollama-matrix — local-model reasoning eval

A small, reusable library for comparing local ollama models on the kinds of
reasoning the CEO agent runs locally (`runner: ollama` / `runner: ollama-think`).
Every task is **self-contained** (no live vault/repo state) and **machine-graded
against a known answer key** — no subjective judge — so runs are reproducible and
comparable across models and over time.

## Why it exists

The first gemma4-vs-incumbent comparison was a single task (N=1), which can't
separate models. This library varies the task across six reasoning dimensions,
each with a deterministic correct answer, so a score difference means something.

## Layout

```
prompts/   one .txt per task, fully self-contained
keys.json  answer key + grading mode + rationale per task
run.sh     runs every prompt × each model via the ollama API (temperature 0)
grade.py   extracts each model's verdict and scores it against keys.json
out/       generated outputs + stats.tsv (gitignored)
```

## Tasks

| Task | Dimension | Output contract | Graded by |
|------|-----------|-----------------|-----------|
| think-01-reconcile-evidence | evidence-matching + abstention | `T<n> \| CLOSE #<pr> \| ...` / `T<n> \| KEEP \| ...` | per-item verdict + PR # |
| think-02-prioritization | multi-criteria ranking | `ORDER: a,b,c,...` | exact order |
| think-03-contradiction | consistency detection | `PAIR: S<n>,S<n>` | unordered pair |
| think-04-temporal-cadence | date/cron arithmetic | `MISSED: <n>` / `NEXT: <ts>` | exact values |
| think-05-abstention | calibration | `Q<n>: <answer\|INSUFFICIENT>` | answer vs abstain |
| think-06-multihop | chained inference | `ANSWER: YES\|NO` | boolean |

Each task includes at least one trap (e.g. reconcile T8 cites a PR that is only
*proposed*, not merged → correct answer is KEEP) so a model that pattern-matches
without reasoning loses points.

## Run

Requires a running ollama daemon, `jq`, `curl`, and `python3`.

```bash
# default models (think-tier candidates)
bash run.sh
# or pick the set explicitly
MODELS="gemma4:12b-it-qat gpt-oss:20b mistral-small3.2:24b" bash run.sh
python3 grade.py            # score table + summary
python3 grade.py --verbose  # also list every wrong item
python3 grade.py --selftest # verify the extractors against known adversarial cases
```

A call that fails (daemon down, model not pulled, HTTP/API error) is written as an
`__EVAL_ERROR__` sentinel and shown as `ERR` in the score table — excluded from the
summary so an infrastructure failure never reads as a model-quality loss.

On the CEO host this runs in WSL against the WSL ollama daemon (the one cron
uses), not the Windows ollama — they are separate model stores.

## Adding a task

1. Drop a self-contained prompt in `prompts/`. Make the output a single
   machine-parseable contract (one verdict per line).
2. Add a `keys.json` entry: pick a `mode` that an extractor in `grade.py`
   already supports (`reconcile`/`order`/`pair`/`kv`/`abstain`/`yesno`), or add a
   new extractor. Include the correct answer and a one-line rationale.
3. Prefer tasks with a verifiable ground truth and at least one trap. Avoid
   anything whose answer depends on world knowledge or the current date unless
   the date is stated in the prompt.

## Caveats

- Greedy decoding (temperature 0) makes runs deterministic but is one sample per
  model; it does not estimate variance. For a tighter comparison, raise N by
  adding paraphrased task variants rather than re-sampling the same prompt.
- A perfect tie means "both competent on these tasks," not "equivalent
  reasoners." Add harder multi-hop / arithmetic tasks to separate strong models.
