import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent.registry import (  # noqa: E402
    DELEGABLE_TIERS, RegistryError, TaskSpec, filter_tools, gate, load_registry,
    load_scores, normalize_model, score_for,
)

# The committed canonical registry (ollama-agent/registry.json), resolved off the
# same parents[1] that sys.path is anchored to above.
COMMITTED_REGISTRY = Path(__file__).resolve().parents[1] / "registry.json"

SCORES_TSV = (
    "# generated_at=2026-06-26T00:00:00Z\n"
    "task\tmodel\tcorrect\ttotal\tratio\n"
    "think-02-prioritization\tgpt-oss.20b\t9\t10\t0.9000\n"
    "think-02-prioritization\tgemma4.12b-it-qat\t3\t10\t0.3000\n"
    "think-03-contradiction\tgpt-oss.20b\t2\t10\t0.2000\n"
    "think-04-temporal\tgpt-oss.20b\t0\t0\t\n"   # total=0 → omitted (blank ratio)
)


def _reg(**tasks):
    return {"tasks": tasks}


def _scored():
    return load_scores(SCORES_TSV)[0]


def test_load_valid_registry():
    specs = load_registry(_reg(
        triage={"runner": "ollama", "model": "gpt-oss:20b", "tier": "deterministic"}))
    s = specs["triage"]
    assert s.model == "gpt-oss:20b" and s.tier == "deterministic" and s.tools == "*"


def test_load_rejects_unknown_runner():
    # The enum-config-typo-fallback incident: `runner: scrpt` must fail loudly.
    with pytest.raises(RegistryError, match="unknown runner"):
        load_registry(_reg(x={"runner": "scrpt", "model": "m", "tier": "deterministic"}))


def test_load_rejects_unknown_tier():
    with pytest.raises(RegistryError, match="unknown tier"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "detrministic"}))


def test_load_rejects_missing_field():
    with pytest.raises(RegistryError, match="missing required field 'model'"):
        load_registry(_reg(x={"runner": "ollama", "tier": "deterministic"}))


def test_load_rejects_bad_tools_type():
    with pytest.raises(RegistryError, match="tools must be"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "deterministic", "tools": "run_shell"}))


def test_load_from_json_string():
    specs = load_registry('{"tasks": {"t": {"runner": "ollama", "model": "m", "tier": "deterministic"}}}')
    assert "t" in specs


def test_load_from_file(tmp_path):
    f = tmp_path / "reg.json"
    f.write_text('{"tasks": {"t": {"runner": "ollama", "model": "m", "tier": "low-stakes-write"}}}')
    assert load_registry(str(f))["t"].tier == "low-stakes-write"


def test_gate_allows_deterministic():
    ok, reason = gate(TaskSpec("t", "ollama", "m", "deterministic"))
    assert ok and reason == "ok"


def test_gate_allows_low_stakes_write():
    ok, _ = gate(TaskSpec("t", "ollama", "m", "low-stakes-write"))
    assert ok


def test_gate_rejects_high_stakes():
    ok, reason = gate(TaskSpec("t", "ollama", "m", "high-stakes"))
    assert not ok and "may not be delegated" in reason


def test_gate_rejects_unknown_runner_defense_in_depth():
    # gate re-checks even if a TaskSpec is hand-built bypassing load validation.
    ok, reason = gate(TaskSpec("t", "bogus", "m", "deterministic"))
    assert not ok and "unknown runner" in reason


def test_filter_tools_star_is_passthrough():
    tools = [{"function": {"name": "run_shell"}}, {"function": {"name": "git"}}]
    assert filter_tools(tools, "*") == tools


def test_filter_tools_restricts_to_allowlist():
    tools = [{"function": {"name": "run_shell"}}, {"function": {"name": "git"}},
             {"function": {"name": "write_file"}}]
    kept = {t["function"]["name"] for t in filter_tools(tools, ["git", "read_file"])}
    assert kept == {"git"}


def test_filter_tools_empty_allowlist_yields_nothing():
    tools = [{"function": {"name": "run_shell"}}]
    assert filter_tools(tools, []) == []


def test_load_bad_json_raises_valueerror():
    with pytest.raises(ValueError):
        load_registry("{not valid json")


# --- Slice B: min_score delegation gate (#200) ---

def test_normalize_model_colon_and_slash():
    assert normalize_model("gpt-oss:20b") == "gpt-oss.20b"
    assert normalize_model("library/foo:1b") == "library-foo.1b"
    # a legitimate version dot must survive (only ':'/'/' are transformed)
    assert normalize_model("mistral-small3.2:24b") == "mistral-small3.2.24b"


def test_load_scores_parses_and_captures_generated_at():
    scores, gen = load_scores(SCORES_TSV)
    assert gen == "2026-06-26T00:00:00Z"
    assert scores[("think-02-prioritization", "gpt-oss.20b")] == 0.9
    assert scores[("think-03-contradiction", "gpt-oss.20b")] == 0.2


def test_load_scores_omits_total_zero_rows():
    scores, _ = load_scores(SCORES_TSV)
    assert ("think-04-temporal", "gpt-oss.20b") not in scores


def test_score_for_pinned_task():
    assert score_for(_scored(), "think-02-prioritization", "gpt-oss.20b") == 0.9
    assert score_for(_scored(), "think-02-prioritization", "gemma4.12b-it-qat") == 0.3


def test_score_for_missing_is_none():
    assert score_for(_scored(), "think-99-nonexistent", "gpt-oss.20b") is None


def test_score_for_aggregate_star_is_mean():
    # gpt-oss.20b has 0.9 and 0.2 (the total=0 row is omitted) → mean 0.55
    assert score_for(_scored(), "*", "gpt-oss.20b") == pytest.approx(0.55)


def test_min_score_without_eval_task_is_config_error():
    with pytest.raises(RegistryError, match="min_score requires eval_task"):
        load_registry(_reg(t={"runner": "ollama", "model": "m", "tier": "deterministic",
                              "min_score": 0.8}))


def test_min_score_non_number_is_config_error():
    with pytest.raises(RegistryError, match="min_score must be a number"):
        load_registry(_reg(t={"runner": "ollama", "model": "m", "tier": "deterministic",
                              "min_score": "high", "eval_task": "think-02-prioritization"}))


def test_gate_passes_when_score_meets_threshold():
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.8, eval_task="think-02-prioritization")
    ok, reason = gate(spec, _scored())
    assert ok and reason == "ok"


def test_gate_refuses_when_score_below_threshold():
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.8, eval_task="think-03-contradiction")  # 0.2 < 0.8
    ok, reason = gate(spec, _scored())
    assert not ok and "below min_score" in reason


def test_gate_refuses_when_score_missing():
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.5, eval_task="think-99-nonexistent")
    ok, reason = gate(spec, _scored())
    assert not ok and "cannot confirm competence" in reason


def test_gate_refuses_when_no_scores_supplied():
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.5, eval_task="think-02-prioritization")
    ok, reason = gate(spec, None)
    assert not ok and "no eval scores available" in reason


def test_gate_eval_model_override():
    # run model is gpt-oss:20b but competence is checked against gemma (0.3 < 0.8)
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.8, eval_task="think-02-prioritization",
                    eval_model="gemma4:12b-it-qat")
    ok, reason = gate(spec, _scored())
    assert not ok and "below min_score" in reason


def test_gate_no_min_score_ignores_scores():
    # absent min_score = no gate (explicit pass-through, not a 0-threshold)
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic")
    ok, _ = gate(spec, None)
    assert ok


def test_load_scores_omits_non_finite_ratio():
    # A corrupt nan/inf must not slip past the threshold (nan < x is False).
    tsv = ("# generated_at=2026-06-26T00:00:00Z\n"
           "task\tmodel\tcorrect\ttotal\tratio\n"
           "t\tm\t1\t1\tnan\n"
           "t2\tm\t1\t1\tinf\n")
    scores, _ = load_scores(tsv)
    assert scores == {}


def test_gate_refuses_nan_score_fail_open_guard():
    tsv = ("task\tmodel\tcorrect\ttotal\tratio\n"
           "think-x\tm\t1\t1\tnan\n")
    scores, _ = load_scores(tsv)
    spec = TaskSpec("t", "ollama", "m", "deterministic", min_score=0.5, eval_task="think-x")
    ok, reason = gate(spec, scores)
    assert not ok and "cannot confirm competence" in reason


def test_gate_refuses_total_zero_row_via_behavior():
    # total=0 row (blank ratio) is omitted → gate refuses. Asserts the refusal
    # behavior, not mere dict absence, so it fails if a future change leaked a 0.0.
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.0, eval_task="think-04-temporal")
    ok, reason = gate(spec, _scored())
    assert not ok and "cannot confirm competence" in reason


def test_gate_score_exactly_at_threshold_passes():
    # boundary: score == min_score must pass (>=, not >)
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.9, eval_task="think-02-prioritization")  # exactly 0.9
    ok, _ = gate(spec, _scored())
    assert ok


def test_gate_aggregate_star_through_gate():
    # gpt-oss.20b mean = 0.55 → passes 0.5, refuses 0.6
    passes, _ = gate(TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                              min_score=0.5, eval_task="*"), _scored())
    refused, reason = gate(TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                                    min_score=0.6, eval_task="*"), _scored())
    assert passes and not refused and "below min_score" in reason


def test_gate_eval_model_override_passing_redirect():
    # run model (gemma, 0.3) would fail, but eval_model redirects to gpt-oss (0.9) → passes
    spec = TaskSpec("t", "ollama", "gemma4:12b-it-qat", "deterministic",
                    min_score=0.8, eval_task="think-02-prioritization",
                    eval_model="gpt-oss:20b")
    ok, _ = gate(spec, _scored())
    assert ok


def test_gate_min_score_zero_is_a_real_threshold():
    # min_score=0.0 still requires a present score (not no-gate); a 0.2 score passes
    spec = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.0, eval_task="think-03-contradiction")
    ok, _ = gate(spec, _scored())
    assert ok
    # but a missing score still refuses even at threshold 0.0
    miss = TaskSpec("t", "ollama", "gpt-oss:20b", "deterministic",
                    min_score=0.0, eval_task="think-99")
    ok2, _ = gate(miss, _scored())
    assert not ok2


def test_committed_registry_ships_empty():
    # The shipped canonical registry must load without error AND be empty: it is
    # governance scaffolding, not a place to register tasks. Asserting == {} (not
    # just "is a dict") also catches a stray high-stakes entry, which the
    # delegable-tier guard below would let slip. A malformed hand-edit fails here
    # (load_registry raises) rather than at first cron dispatch.
    specs = load_registry(str(COMMITTED_REGISTRY))
    assert specs == {}


def test_committed_registry_enables_no_delegable_tier():
    # Governance guard: the committed registry ships the *mechanism*, not the
    # bet. Enabling a task that pins a local model in a delegable tier is gated
    # behind the delegation spike (#255) + routing policy (#254) and belongs in
    # that work, not here. This fails the moment such an entry is added to
    # registry.json, forcing the decision back through the gated issue.
    specs = load_registry(str(COMMITTED_REGISTRY))
    delegable = {name: s.tier for name, s in specs.items() if s.tier in DELEGABLE_TIERS}
    assert not delegable, (
        f"committed registry enables delegable tier(s): {delegable} — "
        "delegable pins are gated behind #255/#254, add them there")


def test_load_registry_warns_when_write_file_without_edit_file(capsys):
    specs = load_registry(_reg(t={"runner": "ollama", "model": "m", "tier": "deterministic",
                                  "tools": ["read_file", "write_file"]}))
    assert "t" in specs
    assert "without 'edit_file'" in capsys.readouterr().err


def test_pairing_warning_names_the_registry_file(tmp_path, capsys):
    reg = tmp_path / "registry.json"
    reg.write_text(json.dumps(_reg(t={"runner": "ollama", "model": "m", "tier": "deterministic",
                                      "tools": ["write_file"]})))
    load_registry(str(reg))
    assert str(reg) in capsys.readouterr().err


def test_pairing_warning_repeats_across_loads(capsys):
    # warnings.warn deduplicated per process, so a long-lived caller validating
    # several registries would hear about the first offender only.
    reg = _reg(t={"runner": "ollama", "model": "m", "tier": "deterministic",
                  "tools": ["write_file"]})
    load_registry(reg)
    load_registry(reg)
    assert capsys.readouterr().err.count("without 'edit_file'") == 2


@pytest.mark.parametrize("tools", ["*", [], ["edit_file"], ["read_file"],
                                   ["read_file", "write_file", "edit_file"]])
def test_load_registry_no_pairing_warning(tools, capsys):
    specs = load_registry(_reg(t={"runner": "ollama", "model": "m", "tier": "deterministic",
                                  "tools": tools}))
    assert "t" in specs
    assert "edit_file'" not in capsys.readouterr().err


def _registry_sources():
    """Every committed registry: the canonical one plus each playbook's inline
    `registry:` frontmatter. Vault-synced playbooks are out of a repo test's reach."""
    repo_root = Path(__file__).resolve().parents[2]
    sources = [(COMMITTED_REGISTRY.name, COMMITTED_REGISTRY.read_text())]
    playbook_files = sorted((repo_root / "docs" / "playbooks").glob("*.md"))
    assert playbook_files, "playbook files must exist under docs/playbooks/"
    for pb in playbook_files:
        in_frontmatter = False
        for i, line in enumerate(pb.read_text().splitlines()):
            if line.strip() == "---":
                if i == 0:
                    in_frontmatter = True
                    continue
                if in_frontmatter:
                    break
            if in_frontmatter and line.startswith("registry:"):
                raw = line.split(":", 1)[1].strip()
                # SCHEMA.md sanctions a path form too; json.loads would take it for
                # malformed JSON, so resolve it rather than failing on the wrong thing.
                if not raw.startswith("{"):
                    raw = str((repo_root / raw).resolve())
                sources.append((pb.name, raw))
    return sources


def test_committed_playbooks_pairing_invariant():
    sources = _registry_sources()
    # The guard against the sweep silently emptying — not a claim that any task
    # uses write_file today.
    assert len(sources) > 1, "no playbook declares an inline registry any more"
    for origin, source in sources:
        for name, spec in load_registry(source).items():
            if isinstance(spec.tools, list) and "write_file" in spec.tools:
                assert "edit_file" in spec.tools, (
                    f"{origin}: task {name!r} allows 'write_file' but omits 'edit_file'")


def test_load_mcp_field():
    specs = load_registry(_reg(
        mcp_task={"runner": "ollama", "model": "m", "tier": "deterministic", "mcp": "npx -y @mcp/server"}))
    assert specs["mcp_task"].mcp == "npx -y @mcp/server"


def test_load_rejects_bad_mcp_type():
    with pytest.raises(RegistryError, match="mcp must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "deterministic", "mcp": 123}))
    with pytest.raises(RegistryError, match="mcp must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "deterministic", "mcp": ["server"]}))


def test_load_rejects_empty_mcp_string():
    with pytest.raises(RegistryError, match="mcp must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "deterministic", "mcp": "   "}))


def test_load_verify_field():
    specs = load_registry(_reg(
        verify_task={"runner": "ollama", "model": "m", "tier": "low-stakes-write", "verify": "pytest -q"}))
    assert specs["verify_task"].verify == "pytest -q"


def test_load_verify_field_default_none():
    specs = load_registry(_reg(
        plain_task={"runner": "ollama", "model": "m", "tier": "low-stakes-write"}))
    assert specs["plain_task"].verify is None


def test_load_rejects_bad_verify_type():
    with pytest.raises(RegistryError, match="verify must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "low-stakes-write", "verify": 123}))
    with pytest.raises(RegistryError, match="verify must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "low-stakes-write", "verify": ["pytest"]}))


def test_load_rejects_empty_verify_string():
    with pytest.raises(RegistryError, match="verify must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "low-stakes-write", "verify": "   "}))
    with pytest.raises(RegistryError, match="verify must be a non-empty string"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "low-stakes-write", "verify": ""}))
