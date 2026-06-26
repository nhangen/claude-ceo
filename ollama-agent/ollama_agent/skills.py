"""Discover Claude-style skills and expose them to the local agent.

A skill is a directory containing a `SKILL.md` with `name:`/`description:`
frontmatter and a markdown procedure body. The agent gets a *catalog* (name +
one-line description) in its system prompt and a `use_skill(name)` tool that
returns a skill's full body on demand — the model loads a procedure only when it
decides it needs one, rather than carrying every skill body in context.
"""
from pathlib import Path

DEFAULT_SKILL_ROOT = "~/.claude/skills"
MAX_SKILL_BODY = 24000   # chars of a skill body returned by use_skill


_BLOCK_SCALAR = {">", ">-", ">+", "|", "|-", "|+", ""}


def _parse_skill_frontmatter(text):
    """Return (name, description) from SKILL.md frontmatter. Either may be empty
    if absent; the caller falls back to the directory name. A YAML block scalar
    (`description: >-` + indented continuation) is folded into one line — several
    real SKILL.md files use that form, and reading only the inline value would
    capture a bare `>`."""
    name, desc = "", ""
    if not text.startswith("---"):
        return name, desc
    end = text.find("\n---", 3)
    if end == -1:
        return name, desc
    lines = text[3:end].splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("name:"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("description:"):
            val = line.split(":", 1)[1].strip()
            if val in _BLOCK_SCALAR:
                parts, j = [], i + 1
                while j < len(lines) and (lines[j][:1] in (" ", "\t") or not lines[j].strip()):
                    if lines[j].strip():
                        parts.append(lines[j].strip())
                    j += 1
                desc = " ".join(parts)
                i = j
                continue
            desc = val
        i += 1
    return name, desc


class Skill:
    def __init__(self, name, path, description):
        self.name = name
        self.path = path
        self.description = description

    def body(self):
        return Path(self.path).read_text(errors="replace")


def load_skill_index(roots=DEFAULT_SKILL_ROOT):
    """Scan each root for <root>/*/SKILL.md. `roots` is a path or list of paths.
    The skill name is its frontmatter `name:`, falling back to the directory name.
    Later roots do not override earlier ones on a name clash (first wins, logged
    by the caller if it cares)."""
    if isinstance(roots, (str, Path)):
        roots = [roots]
    index, seen = [], set()
    for root in roots:
        d = Path(root).expanduser()
        if not d.is_dir():
            continue
        for skill_md in sorted(d.glob("*/SKILL.md")):
            try:
                text = skill_md.read_text(errors="replace")
            except OSError:
                # A permission-denied / race-deleted SKILL.md must not abort
                # discovery of every other skill (safety-invariant-scope).
                continue
            name, desc = _parse_skill_frontmatter(text)
            name = name or skill_md.parent.name
            if name in seen:
                continue
            seen.add(name)
            index.append(Skill(name, str(skill_md), desc))
    return index


def render_catalog(index):
    """A compact name + description list for the system prompt."""
    if not index:
        return ""
    lines = ["# Available skills (call use_skill(name) to load one's full instructions)"]
    for s in index:
        desc = s.description or "(no description)"
        lines.append(f"- {s.name}: {desc}")
    return "\n".join(lines)


def get_skill(index, name):
    for s in index:
        if s.name == name:
            return s
    return None


USE_SKILL_TOOL = {
    "type": "function", "function": {"name": "use_skill",
        "description": "Load a skill's full instructions by name. Call this when a "
                       "listed skill matches the task, then follow the returned procedure.",
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string", "description": "The skill name from the catalog."}},
            "required": ["name"]}},
}
