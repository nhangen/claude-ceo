import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent.rules import (  # noqa: E402
    compose_system, load_rule_index, select_rules, _parse_frontmatter, _tokens,
)


def _rule(d, name, desc, title, body=""):
    (d / f"{name}.md").write_text(
        f"---\ndescription: {desc}\nglobs:\n---\n\n# {title}\n\n{body or 'body of ' + name}\n")


@pytest.fixture
def rules_dir(tmp_path):
    d = tmp_path / "rules"
    d.mkdir()
    _rule(d, "no-commit-tmp-logs", "Never commit tmp test log files", "No Committing tmp Logs")
    _rule(d, "billing-write-verification", "Verify Stripe and EDD billing writes succeed", "Billing Write Verification")
    _rule(d, "css-class-drift", "CSS classes in JSX must have matching stylesheet rules", "CSS Class Drift",
          body="x" * 30000)  # oversized, to exercise the budget path
    return d


def test_parse_frontmatter():
    desc, globs, title = _parse_frontmatter("---\ndescription: hello: world\nglobs: a,b\n---\n\n# Title Here\n\nbody")
    assert desc == "hello: world" and globs == "a,b" and title == "Title Here"


def test_parse_frontmatter_missing_is_empty_not_crash():
    desc, globs, title = _parse_frontmatter("no frontmatter at all\njust text")
    assert desc == "" and globs == "" and title == ""


def test_tokens_drops_stopwords_and_short():
    assert _tokens("the Stripe billing must be verified") == {"stripe", "billing", "verified"}


def test_load_rule_index(rules_dir):
    idx = load_rule_index(rules_dir)
    names = {r.name for r in idx}
    assert names == {"no-commit-tmp-logs", "billing-write-verification", "css-class-drift"}
    billing = next(r for r in idx if r.name == "billing-write-verification")
    assert "Stripe" in billing.description and billing.size > 0


def test_load_missing_dir_returns_empty(tmp_path):
    assert load_rule_index(tmp_path / "nope") == []


def test_select_picks_relevant_rule(rules_dir):
    sel = select_rules("I need to commit but there are tmp log files staged", load_rule_index(rules_dir))
    assert sel.selected[0].name == "no-commit-tmp-logs"
    assert "billing-write-verification" not in {r.name for r in sel.selected}


def test_select_irrelevant_task_selects_nothing(rules_dir):
    sel = select_rules("paint the fence a nice shade of blue", load_rule_index(rules_dir))
    assert sel.selected == []


def test_select_max_rules_cap_logs_dropped(rules_dir):
    # task matches multiple rules; cap at 1 → the rest are recorded as dropped.
    task = "commit the stripe billing css changes and the tmp logs"
    sel = select_rules(task, load_rule_index(rules_dir), max_rules=1, budget_chars=10**9)
    assert len(sel.selected) == 1
    assert len(sel.dropped) == 2  # exactly the other two matched rules, not a partial drop
    assert all("max_rules" in reason for _, reason in sel.dropped)


def test_selection_reports_considered_and_matched(rules_dir):
    sel = select_rules("commit tmp logs", load_rule_index(rules_dir))
    assert sel.considered == 3       # all rules in the index
    assert sel.matched == 1          # only no-commit-tmp-logs scored > 0
    assert len(sel.selected) == 1


def test_non_utf8_rule_body_does_not_crash_render(tmp_path):
    d = tmp_path / "rules"
    d.mkdir()
    (d / "weird.md").write_bytes(
        b"---\ndescription: handle the weird commit case\n---\n\n# Weird\n\n\xff\xfe bad bytes\n")
    sel = select_rules("weird commit case", load_rule_index(d))
    assert sel.selected[0].name == "weird"
    block = sel.render()  # must not raise UnicodeDecodeError
    assert "## Rule: weird" in block


def test_unreadable_selected_rule_is_dropped_not_crash(tmp_path, monkeypatch):
    d = tmp_path / "rules"
    d.mkdir()
    _rule(d, "no-commit-tmp-logs", "Never commit tmp log files", "tmp")
    idx = load_rule_index(d)
    monkeypatch.setattr(type(idx[0]), "read_body",
                        lambda self: (_ for _ in ()).throw(OSError("gone")))
    sel = select_rules("commit tmp logs", idx)
    assert sel.selected == []
    assert sel.dropped and "unreadable" in sel.dropped[0][1]


def test_title_taken_after_frontmatter_not_body_hash(tmp_path):
    d = tmp_path / "rules"
    d.mkdir()
    (d / "r.md").write_text(
        "---\ndescription: a rule\n---\n\n# Real Title\n\n```\n# fake heading in code\n```\n")
    title = load_rule_index(d)[0].title
    assert title == "Real Title"


def test_select_budget_drop_is_logged_not_silent(rules_dir):
    # css-class-drift body is 30k chars; a 1k budget must drop it with a reason.
    sel = select_rules("fix the css class drift in jsx", load_rule_index(rules_dir),
                        max_rules=6, budget_chars=1000)
    assert all(r.name != "css-class-drift" for r in sel.selected)
    assert any(r.name == "css-class-drift" and "budget" in reason for r, reason in sel.dropped)


def test_render_includes_selected_body(rules_dir):
    sel = select_rules("commit tmp logs", load_rule_index(rules_dir))
    block = sel.render()
    assert "## Rule: no-commit-tmp-logs" in block and "body of no-commit-tmp-logs" in block


def test_render_empty_when_nothing_selected(rules_dir):
    assert select_rules("xyzzy", load_rule_index(rules_dir)).render() == ""


def test_compose_system_prepends_rules(rules_dir):
    system, sel = compose_system("BASE PROMPT", "commit tmp logs", rules_dir)
    assert "BASE PROMPT" in system
    assert system.index("no-commit-tmp-logs") < system.index("BASE PROMPT")


def test_compose_system_no_match_is_base_only(rules_dir):
    system, sel = compose_system("BASE PROMPT", "xyzzy", rules_dir)
    assert system == "BASE PROMPT" and sel.selected == []
