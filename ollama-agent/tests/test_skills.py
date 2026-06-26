import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent import ToolBox  # noqa: E402
from ollama_agent.skills import (  # noqa: E402
    _parse_skill_frontmatter, get_skill, load_skill_index, render_catalog,
)


def _skill(root, name, desc=None, body="procedure body"):
    d = root / name
    d.mkdir()
    nm = f"name: {name}\n" if desc is not None else ""
    ds = f"description: {desc}\n" if desc is not None else ""
    fm = f"---\n{nm}{ds}---\n\n" if (nm or ds) else ""
    (d / "SKILL.md").write_text(f"{fm}# {name}\n\n{body}\n")
    return d


@pytest.fixture
def skills_root(tmp_path):
    r = tmp_path / "skills"
    r.mkdir()
    _skill(r, "pr-review-panel", "Multi-agent PR review with specialists and an auditor")
    _skill(r, "obsidian-save", "Save the conversation to the Obsidian vault")
    return r


def test_parse_skill_frontmatter():
    name, desc = _parse_skill_frontmatter("---\nname: foo\ndescription: does a thing\n---\n\n# Foo\nbody")
    assert name == "foo" and desc == "does a thing"


def test_parse_skill_frontmatter_missing_is_empty():
    assert _parse_skill_frontmatter("no frontmatter\nbody") == ("", "")


def test_parse_skill_frontmatter_folded_scalar():
    text = "---\nname: foo\ndescription: >-\n  a long\n  wrapped description\n---\n\n# Foo\nbody"
    name, desc = _parse_skill_frontmatter(text)
    assert name == "foo" and desc == "a long wrapped description"


def test_parse_skill_frontmatter_no_closing_fence_is_empty():
    assert _parse_skill_frontmatter("---\nname: foo\ndescription: bar\n\n# no closing fence") == ("", "")


def test_load_skill_index(skills_root):
    idx = load_skill_index(skills_root)
    assert {s.name for s in idx} == {"pr-review-panel", "obsidian-save"}
    panel = get_skill(idx, "pr-review-panel")
    assert "auditor" in panel.description


def test_name_falls_back_to_dir_when_frontmatter_lacks_name(tmp_path):
    r = tmp_path / "skills"
    r.mkdir()
    _skill(r, "no-name-skill", desc=None)  # no frontmatter at all
    idx = load_skill_index(r)
    assert idx[0].name == "no-name-skill"


def test_load_missing_root_returns_empty(tmp_path):
    assert load_skill_index(tmp_path / "nope") == []


def test_first_root_wins_on_name_clash(tmp_path):
    r1, r2 = tmp_path / "a", tmp_path / "b"
    r1.mkdir(); r2.mkdir()
    _skill(r1, "dup", "from r1")
    _skill(r2, "dup", "from r2")
    idx = load_skill_index([r1, r2])
    assert len(idx) == 1 and get_skill(idx, "dup").description == "from r1"


def test_render_catalog(skills_root):
    cat = render_catalog(load_skill_index(skills_root))
    assert "use_skill" in cat
    assert "pr-review-panel: Multi-agent PR review" in cat


def test_render_catalog_empty():
    assert render_catalog([]) == ""


def test_render_catalog_no_description_placeholder(tmp_path):
    r = tmp_path / "skills"
    r.mkdir()
    _skill(r, "bare", desc=None)  # no frontmatter → empty description
    cat = render_catalog(load_skill_index(r))
    assert "bare: (no description)" in cat


def test_load_skill_index_folded_scalar_in_catalog(tmp_path):
    r = tmp_path / "skills"
    d = r / "auto-review"
    d.mkdir(parents=True)
    (d / "SKILL.md").write_text(
        "---\nname: auto-review\ndescription: >\n  reviews a PR\n  automatically\n---\n\n# auto-review\nbody")
    desc = load_skill_index(r)[0].description
    assert desc == "reviews a PR automatically"  # not a bare ">"


def test_use_skill_tool_returns_body(skills_root):
    tb = ToolBox(cwd=skills_root, skills=load_skill_index(skills_root))
    out = json.loads(tb.dispatch("use_skill", {"name": "obsidian-save"}))
    assert out["name"] == "obsidian-save" and "procedure body" in out["body"]


def test_use_skill_unknown_records_and_errors(skills_root):
    tb = ToolBox(cwd=skills_root, skills=load_skill_index(skills_root))
    out = json.loads(tb.dispatch("use_skill", {"name": "no-such-skill"}))
    assert "error" in out and "pr-review-panel" in out["available"]
    assert tb.unknown_calls == ["no-such-skill"]


def test_use_skill_with_no_skills_loaded_errors_cleanly(tmp_path):
    tb = ToolBox(cwd=tmp_path)  # no skills
    out = json.loads(tb.dispatch("use_skill", {"name": "anything"}))
    assert "error" in out and out["available"] == []
    assert tb.unknown_calls == ["anything"]


def test_load_skill_index_skips_unreadable_file(tmp_path, monkeypatch):
    r = tmp_path / "skills"
    r.mkdir()
    _skill(r, "good", "fine")
    _skill(r, "bad", "broken")
    real = Path.read_text

    def selective(self, *a, **k):
        if self.parent.name == "bad":
            raise PermissionError("nope")
        return real(self, *a, **k)
    monkeypatch.setattr(Path, "read_text", selective)
    idx = load_skill_index(r)  # must not raise; bad skill skipped
    assert {s.name for s in idx} == {"good"}


def test_use_skill_body_is_clipped(tmp_path):
    from ollama_agent.skills import MAX_SKILL_BODY
    r = tmp_path / "skills"
    r.mkdir()
    _skill(r, "huge", "big skill", body="x" * (MAX_SKILL_BODY + 5000))
    tb = ToolBox(cwd=r, skills=load_skill_index(r))
    out = json.loads(tb.dispatch("use_skill", {"name": "huge"}))
    assert "truncated" in out["body"] and len(out["body"]) < MAX_SKILL_BODY + 200
