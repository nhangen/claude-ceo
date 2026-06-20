---
date: 2026-06-20
status: approved-design
topic: ceo-morning-flow
tags: [ceo, morning-flow, orchestration, learning-loop, design]
---

# CEO Morning Flow — Design (v1)

## Problem

The CEO's "morning" is a set of disconnected cron playbooks, each a fully independent `claude -p` run with no shared state: `morning-scan` (3:10), `morning-brief` (3:20), `pending-drip` (3:30), `pr-triage` (3:50), `eod-summary` (4:00). Only `morning-brief` reaches Discord; the rest write to logs and a per-host inbox Nathan never reads. The briefing Nathan sees is one model working from pre-gathered scraps while the richer work scatters into invisible files — so the report reads as garbage.

Deeper: the CEO has **no model of how Nathan thinks**. It ranks priorities by PR/ticket *age* because it doesn't consume the real priority signal (current sprint) that's already available. Nathan's requirement: the CEO must **observe him like the vaultkeeper observes the vault** — watch real choices, take notes, build understanding — and earn autonomy as that understanding proves out. Trust is a function of demonstrated understanding, not hand-fed rules.

## Goal (v1)

Replace the disconnected morning playbooks with **one orchestrated morning flow** that:
1. produces **one coherent briefing** delivered to Discord,
2. prioritizes by **real per-domain signals** (not ticket age), and
3. starts a **learning loop** — a model-of-Nathan ledger it reads and updates.

This is the first of three planned subsystems. **(B) bidirectional Discord** (Nathan replies, CEO acts) and **(C) autonomous execution** are explicitly later specs. v1 is the foundation both stand on.

## Non-goals (v1)

- Bidirectional Discord / inbound replies.
- Autonomous execution of actions.
- The "Propose drafts" phase (deferred to v1.1 — see Phasing).
- Calendar, Asana, email, Slack integration (no data source today).
- The end-of-day (`eod`) flow (possible sibling action later).

## Architecture

**One cron entry `morning` → a shell-level orchestrator** (extends existing `ceo-cron.sh` patterns) that runs phases in sequence. Gather is shell (model-free); only synthesis is an LLM run. The orchestrator composes what are today separate playbooks into ordered phases that share state and produce one output.

### Phase 1 — Gather (shell, model-free)

Collect real priority signals + the model-of-Nathan ledger into shared state. **Ship two concrete domains in v1** (no pluggable resolver framework — that abstraction earns its keep at 4+ domains, not 2):

- **Awesome Motive** → **current Zenhub sprint** (via MCP `getSprint`/`getIssuesInPipeline`) + review-requested PRs (`gh`).
- **Personal** → daily-note Top 3 + tasks.

Plus existing pre-gathered inputs: `Pending.md`, approvals, firing alerts, prior report, PR counts. NRX / Academics / Career are **flat additions later** when their real signals are wired (not built speculatively).

### Phase 2 — Synthesis (one read-tier LLM run; sonnet, ollama-degradable)

Consume gathered state + ledger → produce the arrival briefing:

> overnight digest → **priorities (ranked by real signal)** → day plan → goals/todos surfaced

- **Acceptance criterion (defines "not garbage"):** for AM, **sprint membership is the primary priority key, beating ticket age.** A test asserts a sprint-member PR outranks an older non-sprint PR.
- Calendar section omitted explicitly (no source).
- **Fallback:** if synthesis fails, deliver the raw gathered digest — never deliver nothing.

### Phase 3 — Observe (the learning loop)

Append a dated entry to the **model-of-Nathan ledger**, reusing the append-only agent-memory ledger pattern (dated file, frontmatter, adjudication-on-review):

- Record what the CEO **predicted** as top priorities, and **what Nathan actually did** — read from observable positives only: PR merges, commits, closes (`gh`, `git log --since`).
- **Positives only (load-bearing constraint):** the ledger does **not** infer "Nathan deprioritized X" from absence of action. Absence conflates "chose not to" with "blocked / waiting / didn't get to," which generates confidently-wrong notes and *erodes* the trust the system exists to build. Skip-detection is a documented known-gap.
- Score a **prediction hit-rate**: of the top-N priorities the CEO surfaced, how many Nathan actually actioned that day. This number is the concrete signal that later justifies graduating an action-class from propose → auto (the bridge to specs B/C). "Earn autonomy over time" is thereby measurable, not aspirational.

### Output

**One briefing → Discord** (replaces the four fragments). `pending-drip`'s invisible per-host inbox write is folded in / retired.

## Model-of-Nathan ledger — location & confidentiality

- **Location:** synced CEO vault (so every CEO host reads/updates one model), e.g. `CEO/model/YYYY-MM.md` or `CEO/agents/ceo/YYYY-MM.md` (exact path in the plan).
- **Discretion-bound (hard):** because it syncs across machines + backups, it records **patterns**, never employer/Altamira-sensitive specifics — e.g. "prioritized client delivery over internal tooling," never the client name or contract detail. Obeys `Profile/discretion.md` exactly, same discipline as logs.

## Model portability

Each phase picks an appropriate model. Gather is shell (model-free). Synthesis runs sonnet by default, degrades to ollama with reduced scope; the raw-digest fallback covers total synthesis failure. The flow must produce *something* useful on haiku/ollama, not only opus.

## Error handling & cutover safety

- One synthesis run replacing four means one failure = zero briefing today (vs. degraded-partial today). The **raw-digest fallback** mitigates this.
- Per-phase runner/model selection validates inputs (`enum-config-typo-fallback`, `shell-required-env-vars` apply): reject unknown runner/model at parse, require `$CEO_VAULT`.
- **Cutover is an ML-1 action** (`ceo-scan-only-on-ml1`). Keep the four old playbooks **disabled, not deleted**, for one cycle; diff old-vs-new briefings before retiring.
- The morning flow writes to the synced vault → it is an **automated writer**; register it in `CEO/registry.json` with declared outputs (`ceo-automated-writers-are-playbooks`).

## Testing

- **Priority ranking:** sprint-member PR outranks older non-sprint PR (the anti-garbage assertion).
- **Synthesis fallback:** simulate synthesis failure → raw digest delivered, not empty.
- **Ledger positives-only:** an unmerged-but-not-touched PR produces NO "deprioritized" entry.
- **Hit-rate:** given predicted top-N and a known set of merged items, the computed hit-rate matches a hand-computed value (drive from the production entry point, not the same primitive — `test-expected-from-production-entry-point`).
- **Discretion:** a fixture with an employer-sensitive specific does not appear verbatim in the ledger entry.
- **Orchestrator:** stub the LLM runner with argv validation (`stub-cli-argv-validation`); a failing phase degrades rather than aborting the whole flow.

## Phasing

- **v1 (this spec):** gather (2 domains) → synthesis (one briefing, sprint-beats-age, raw-digest fallback) → observe (positives-only ledger + hit-rate). Fixes the garbage report and starts the learning loop.
- **v1.1:** Propose phase — queue draft proposals (suggested replies, todos, reprioritizations) into the existing approval queue.
- **Spec B:** bidirectional Discord (reply in-channel).
- **Spec C:** autonomous execution, gated by the ledger's demonstrated hit-rate.

## Open implementation details (for the plan, not blockers)

- Exact ledger path + frontmatter schema.
- Which existing playbook bodies become orchestrator phase prompts vs. are retired.
- Orchestrator: extend `ceo-cron.sh` vs. a new `ceo-morning.sh` it dispatches.
