"""Who actually served a run (#667).

The ledger recorded the string the wrapper SENT. Against a router that resolves
one name to many backends, that is not an answer to "what wrote this code": on
2026-09-08 the alias `local-coder` resolved to a 14.8b model while every doc and
every verbal claim in three sessions said 27b. Thirteen runs' worth of outcome
data was attributed to a model that never ran.

olla returns the resolution on every response -- the concrete model in the body,
the endpoint and proxy version in headers -- so nothing here needs an extra
request. These arms pin that it is captured, that it survives a run whose turns
land on DIFFERENT backends, and that a plain ollama daemon with no proxy headers
still writes a clean row.
"""
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ollama_agent.ledger import append_run  # noqa: E402
from ollama_agent.transport import ollama_transport, parse_chat_response  # noqa: E402


def _body(model="qwen3.8:27b", content="ok"):
    return json.dumps({
        "model": model,
        "message": {"role": "assistant", "content": content},
        "prompt_eval_count": 11,
        "eval_count": 7,
    })


class _Resp(io.BytesIO):
    """Minimal stand-in for the urlopen context manager, carrying headers."""

    def __init__(self, body, headers=None, status=200):
        super().__init__(body.encode())
        self.status = status
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def _patch_urlopen(monkeypatch, responses):
    """Serve `responses` in order, so a multi-turn run can change backend."""
    queue = list(responses)

    def fake_urlopen(req, timeout=None):
        return queue.pop(0)

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)


# --- the body's resolved model -------------------------------------------------

def test_parse_records_the_served_model_not_the_requested_one():
    prov = {}
    msg, usage = parse_chat_response(200, _body(model="hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"),
                                     provenance=prov)
    assert msg["content"] == "ok"
    assert usage == {"input": 11, "output": 7}
    assert prov["model_served"] == ["hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"]


def test_parse_without_a_provenance_dict_is_unchanged():
    """The parameter is optional: every existing caller passes two args."""
    msg, usage = parse_chat_response(200, _body())
    assert msg["content"] == "ok"
    assert usage == {"input": 11, "output": 7}


# --- headers ------------------------------------------------------------------

def test_transport_records_endpoint_and_proxy_from_headers(monkeypatch):
    prov = {}
    _patch_urlopen(monkeypatch, [_Resp(_body(), {
        "X-Olla-Endpoint": "ml1-5080",
        "X-Olla-Request-Id": "gentle-galloping-9a2d",
        "Via": "1.1 olla/v0.0.29",
    })])
    t = ollama_transport("local-coder", host="h:1", provenance=prov)
    t([{"role": "user", "content": "hi"}], [])
    assert prov["endpoint"] == ["ml1-5080"]
    assert prov["proxy"] == ["1.1 olla/v0.0.29"]
    assert prov["request_ids"] == ["gentle-galloping-9a2d"]


def test_a_plain_ollama_daemon_records_no_proxy_fields(monkeypatch):
    """No olla in front: the body still names the model, and the proxy-only keys
    stay absent rather than landing as empty strings that look like a backend."""
    prov = {}
    _patch_urlopen(monkeypatch, [_Resp(_body())])
    t = ollama_transport("qwen3.8:27b", host="h:1", provenance=prov)
    t([{"role": "user", "content": "hi"}], [])
    assert prov["model_served"] == ["qwen3.8:27b"]
    assert "endpoint" not in prov
    assert "proxy" not in prov


# --- the arm that matters: a run can change backend mid-flight ----------------

def test_two_turns_on_different_backends_record_both(monkeypatch):
    """A priority balancer re-decides per request, so a 20-turn run is not one
    experiment. Recording only the last (or only the first) turn's backend would
    name one model for a run that two models wrote."""
    prov = {}
    _patch_urlopen(monkeypatch, [
        _Resp(_body(model="qwen3.8:27b"), {"X-Olla-Endpoint": "ml1-5080"}),
        _Resp(_body(model="hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"),
              {"X-Olla-Endpoint": "ml2-5070"}),
    ])
    t = ollama_transport("local-coder", host="h:1", provenance=prov)
    t([{"role": "user", "content": "one"}], [])
    t([{"role": "user", "content": "two"}], [])
    assert prov["model_served"] == ["qwen3.8:27b", "hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"]
    assert prov["endpoint"] == ["ml1-5080", "ml2-5070"]


def test_repeated_identical_turns_are_recorded_once(monkeypatch):
    """Distinct values, not one entry per turn: a 20-turn run on one backend
    must not write a 20-element list nobody can read."""
    prov = {}
    _patch_urlopen(monkeypatch, [
        _Resp(_body(), {"X-Olla-Endpoint": "ml1-5080"}),
        _Resp(_body(), {"X-Olla-Endpoint": "ml1-5080"}),
        _Resp(_body(), {"X-Olla-Endpoint": "ml1-5080"}),
    ])
    t = ollama_transport("local-coder", host="h:1", provenance=prov)
    for _ in range(3):
        t([{"role": "user", "content": "x"}], [])
    assert prov["model_served"] == ["qwen3.8:27b"]
    assert prov["endpoint"] == ["ml1-5080"]


# --- the ledger row -----------------------------------------------------------

def _row(path):
    return json.loads(Path(path).read_text().strip().splitlines()[-1])


def test_ledger_records_served_alongside_the_requested_model(tmp_path):
    p = tmp_path / "runs.jsonl"
    rec = {"run_id": "r1", "turns": 2, "completed": True}
    append_run(rec, "local-coder", "t", "/w", path=p,
               provenance={"model_served": ["hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"],
                           "endpoint": ["ml1-5080"],
                           "proxy": ["1.1 olla/v0.0.29"],
                           "request_ids": ["gentle-galloping-9a2d"]})
    row = _row(p)
    # `model` keeps its historical meaning -- the string we asked for. Months of
    # rows mean that, and #648/#653's evidence is among them.
    assert row["model"] == "local-coder"
    assert row["model_served"] == ["hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"]
    assert row["endpoint"] == ["ml1-5080"]
    assert row["proxy"] == ["1.1 olla/v0.0.29"]
    assert row["request_ids"] == ["gentle-galloping-9a2d"]


def test_ledger_without_provenance_writes_nulls_not_a_missing_key(tmp_path):
    """A reader must be able to tell "nothing was captured" from "not captured
    yet": an absent key reads as an old row, an explicit null as a new one."""
    p = tmp_path / "runs.jsonl"
    append_run({"run_id": "r1"}, "qwen3.8:27b", "t", "/w", path=p)
    row = _row(p)
    assert row["model_served"] is None
    assert row["endpoint"] is None


# --- arms the first cut was missing (found by audit on PR #391) --------------

def test_request_ids_are_capped_because_dedup_can_never_fire_on_them():
    """`_note`'s distinct-value argument does not apply to a value that is unique
    per request. An olla request id never repeats, so without a cap the list grows
    one entry per turn -- and the "recorded once" arm above misses it, because its
    fixture omits the header. `turns` already reports the request count."""
    from ollama_agent.transport import MAX_REQUEST_IDS, _note_headers
    prov = {}
    for i in range(MAX_REQUEST_IDS + 4):
        _note_headers(prov, {"X-Olla-Endpoint": "ml1-5080",
                             "X-Olla-Request-Id": f"unique-{i}"})
    assert len(prov["request_ids"]) == MAX_REQUEST_IDS
    assert prov["request_ids"][0] == "unique-0", "the cap must keep the FIRST ids"
    # The fields that do dedup are unaffected by the cap.
    assert prov["endpoint"] == ["ml1-5080"]


def test_an_empty_header_value_is_not_recorded_as_a_backend():
    """The guard under test is `_note`'s `not value`, which the plain-daemon arm
    reaches only via `_note_headers`'s `not headers` early return. A present
    header with an empty value must not land as an endpoint named ""."""
    from ollama_agent.transport import _note_headers
    prov = {}
    _note_headers(prov, {"X-Olla-Endpoint": "", "Via": "", "X-Olla-Request-Id": "r1"})
    assert "endpoint" not in prov
    assert "proxy" not in prov
    assert prov["request_ids"] == ["r1"], "a real value alongside empty ones still records"


def test_a_failed_turn_still_names_its_backend(monkeypatch):
    """Headers are read before the body is parsed precisely so an error response
    is attributable. Deleting that call left the suite green in the first cut."""
    import urllib.error
    prov = {}

    def fake_urlopen(req, timeout=None):
        raise urllib.error.HTTPError(
            "http://h/api/chat", 400, "Bad Request",
            {"X-Olla-Endpoint": "ml2-5070", "X-Olla-Request-Id": "doomed-1"},
            io.BytesIO(json.dumps({"error": "model requires more system memory"}).encode()))

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    t = ollama_transport("local-coder", host="h:1", provenance=prov)
    try:
        t([{"role": "user", "content": "hi"}], [])
    except RuntimeError:
        pass
    else:
        raise AssertionError("a 400 with an error body must raise")
    assert prov["endpoint"] == ["ml2-5070"]
    assert prov["request_ids"] == ["doomed-1"]


def test_a_retried_endpoint_is_recorded_not_lost(monkeypatch):
    """A 503 is retried. If the failing endpoint is not recorded, a flaky backend
    that fails before a healthy one answers is invisible -- which is the "which
    machine" half of what this exists to answer."""
    import urllib.error
    prov = {}
    calls = {"n": 0}

    def fake_urlopen(req, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            raise urllib.error.HTTPError(
                "http://h/api/chat", 503, "unavailable",
                {"X-Olla-Endpoint": "ml2-5070"}, io.BytesIO(b"unavailable"))
        return _Resp(_body(), {"X-Olla-Endpoint": "ml1-5080"})

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    monkeypatch.setattr("time.sleep", lambda *a: None)
    t = ollama_transport("local-coder", host="h:1", provenance=prov)
    t([{"role": "user", "content": "hi"}], [])
    assert prov["endpoint"] == ["ml2-5070", "ml1-5080"], \
        "the endpoint that 503'd was dropped, so a flaky backend leaves no trace"


def test_routing_strategy_is_captured():
    """The router stating it resolved an alias. Independent of the model string,
    so it still reports a substitution if the proxy echoes the alias back."""
    from ollama_agent.transport import _note_headers
    prov = {}
    _note_headers(prov, {"X-Olla-Routing-Strategy": "alias"})
    assert prov["routing"] == ["alias"]
