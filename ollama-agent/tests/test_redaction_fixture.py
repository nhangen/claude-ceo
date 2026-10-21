"""Walks the shared redaction corpus through ``redact_secrets`` (#566).

``scripts/redaction-cases.jsonl`` is the one (input, must-not-contain,
must-contain) corpus both redactors satisfy; ``scripts/ceo-cron-redaction.test.sh``
walks it through the sed side. A credential shape is added once, to the fixture
and to both implementations.
"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_credentials import fake_hex32, fake_secret  # noqa: E402
from ollama_agent.transport import redact_secrets  # noqa: E402

_CASES = Path(__file__).resolve().parents[2] / "scripts" / "redaction-cases.jsonl"


def _rows():
    return [json.loads(line) for line in _CASES.read_text().splitlines() if line.strip()]


def _expand(text: str) -> str:
    return text.replace("{{BODY}}", fake_secret("")).replace("{{HEX32}}", fake_hex32())


def test_fixture_rows_assert_something():
    rows = _rows()
    assert rows
    for row in rows:
        assert row.get("must_not_contain") or row.get("must_contain"), row["id"]


@pytest.mark.parametrize("row", _rows(), ids=lambda r: r["id"])
def test_redact_secrets_satisfies_shared_fixture(row):
    out = redact_secrets(_expand(row["input"]))
    for bad in row.get("must_not_contain", []):
        assert _expand(bad) not in out, f"{row['id']}: {bad!r} survived: {out!r}"
    for keep in row.get("must_contain", []):
        assert _expand(keep) in out, f"{row['id']}: {keep!r} missing: {out!r}"
