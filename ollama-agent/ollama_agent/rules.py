"""Load Claude-style rule files and select the ones relevant to a task.

Rules live as markdown with YAML-ish frontmatter (`description:`, `globs:`) and a
`# Title`; the rule name is the filename stem. There are ~64 of them — injecting
all of them every call is a context dump, not the always-check-rules discipline.
This module loads the index cheaply (frontmatter only) and selects the few whose
description/name actually overlap the task, under a character budget, logging
every rule it drops (no silent truncation — enum-config-typo-fallback).
"""
import re
from pathlib import Path

_TOKEN = re.compile(r"[a-z0-9]+")
_STOP = {
    "the", "a", "an", "and", "or", "but", "for", "to", "of", "in", "on", "at",
    "is", "are", "be", "do", "does", "did", "you", "your", "it", "its", "this",
    "that", "with", "as", "by", "if", "not", "no", "any", "all", "can", "will",
    "should", "must", "when", "before", "after", "every", "use", "using", "from",
}


def _tokens(text):
    return {t for t in _TOKEN.findall((text or "").lower()) if t not in _STOP and len(t) >= 3}


def _parse_frontmatter(text):
    """Return (description, globs, title) from a rule file's head. Missing fields
    come back as empty strings rather than raising — a rule without frontmatter is
    still usable, just less selectable."""
    desc, globs, title = "", "", ""
    body_start = 0
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            body_start = end + 4
            for line in text[3:end].splitlines():
                if line.startswith("description:"):
                    desc = line.split(":", 1)[1].strip()
                elif line.startswith("globs:"):
                    globs = line.split(":", 1)[1].strip()
    # Match the first heading after the frontmatter only — a `#` line inside the
    # body (e.g. a shell comment in a code block) is not the rule's title.
    m = re.search(r"^#\s+(.+)$", text[body_start:], re.MULTILINE)
    if m:
        title = m.group(1).strip()
    return desc, globs, title


class Rule:
    def __init__(self, name, path, description, title, size):
        self.name = name
        self.path = path
        self.description = description
        self.title = title
        self.size = size            # full-file char count (what the budget accounts against)
        self.cached_body = None     # set when the rule is selected (read once, errors-tolerant)
        self._tokens = _tokens(f"{name.replace('-', ' ')} {title} {description}")

    def score(self, task_tokens):
        return len(self._tokens & task_tokens)

    def read_body(self):
        # errors="replace" mirrors load_rule_index: a non-UTF-8 byte must not crash
        # injection on a file the index already admitted. OSError (file deleted/
        # unreadable after indexing) is left to the caller to route to `dropped`.
        return Path(self.path).read_text(errors="replace")


class Selection:
    def __init__(self, selected, dropped, considered=0, matched=0):
        self.selected = selected            # [Rule], in score order, bodies cached
        self.dropped = dropped              # [(Rule, reason)] matched-but-excluded
        self.considered = considered        # rules in the index
        self.matched = matched              # rules with score > 0

    def render(self):
        if not self.selected:
            return ""
        parts = ["# Applicable rules (follow these — they override default behavior)\n"]
        for r in self.selected:
            body = r.cached_body if r.cached_body is not None else r.read_body()
            parts.append(f"## Rule: {r.name}\n{body.strip()}\n")
        return "\n".join(parts)


def load_rule_index(rules_dir):
    """Read frontmatter (not bodies) for every *.md in rules_dir. Returns [Rule]."""
    d = Path(rules_dir).expanduser()
    rules = []
    if not d.is_dir():
        return rules
    for f in sorted(d.glob("*.md")):
        try:
            text = f.read_text(errors="replace")
        except OSError:
            # One unreadable rule file must not abort loading the rest.
            continue
        desc, _globs, title = _parse_frontmatter(text)
        rules.append(Rule(f.stem, str(f), desc, title, len(text)))
    return rules


def compose_system(base_system, task, rules_dir, max_rules=6, budget_chars=24000):
    """Return (system_text, selection): base prompt with the task-relevant rules
    prepended. Selection is returned so the caller can log what was injected and
    what was dropped."""
    sel = select_rules(task, load_rule_index(rules_dir), max_rules, budget_chars)
    block = sel.render()
    system = f"{block}\n\n{base_system}" if block else base_system
    return system, sel


def select_rules(task, index, max_rules=6, budget_chars=24000):
    """Pick the rules whose name/title/description overlap the task, highest score
    first, until max_rules or budget_chars is hit. A rule that scored > 0 but
    didn't fit is returned in `dropped` with a reason — never silently discarded.
    """
    task_tokens = _tokens(task)
    scored = [(r.score(task_tokens), r) for r in index]
    candidates = sorted((sr for sr in scored if sr[0] > 0),
                        key=lambda sr: (-sr[0], sr[1].name))
    selected, dropped, used = [], [], 0
    for sc, r in candidates:
        if len(selected) >= max_rules:
            dropped.append((r, f"max_rules={max_rules} reached"))
            continue
        if used + r.size > budget_chars:
            dropped.append((r, f"budget {budget_chars} exhausted (used {used}, +{r.size})"))
            continue
        try:
            r.cached_body = r.read_body()
        except OSError as e:
            dropped.append((r, f"unreadable: {type(e).__name__}"))
            continue
        selected.append(r)
        used += r.size
    return Selection(selected, dropped, considered=len(index), matched=len(candidates))
