"""HTTP transport to ollama's /api/chat tools endpoint.

The success check is explicit on both the urlopen and HTTPError paths: ollama
returns a 200 body carrying an "error" key for some failures, and a non-200 for
others. Treating "no exception" as success would record an HTTP error as a model
turn (non-throwing-client-success-check).
"""
import json
import sys
import time
import urllib.error
import urllib.request

DEFAULT_HOST = "127.0.0.1:11434"
RETRYABLE_HTTP_STATUSES = frozenset({502, 503, 504})
MAX_HTTP_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = 0.2

# Ollama's own wording when a prompt overruns num_ctx: it trims tokens from the
# front until the user turn is gone, then reports this. It is the daemon's
# message, not an API contract (observed on ollama through 2026-09), so a reword
# upstream silently reverts overflow to the generic raises below. The durable
# signal is prompt_eval_count against num_ctx, not this string.
CONTEXT_OVERFLOW_SENTINEL = "no user query found in messages"
CONTEXT_OVERFLOW_REMEDIATION = (
    "Increase --num-ctx (e.g. --num-ctx 65536) or reduce prompt size with "
    "--no-skills / --no-rules / --max-rules."
)


# Response headers a proxy adds to name the backend it chose. Absent behind a
# plain ollama daemon, which is why each is recorded only when present: an empty
# string in `endpoint` would read as a backend named "".
# Enough request ids to find the run in the proxy's own logs. Capped because an
# id is unique per request: see `_note`'s `limit`.
MAX_REQUEST_IDS = 5

_HEADER_FIELDS = (
    ("endpoint", "X-Olla-Endpoint"),
    ("proxy", "Via"),
    # The router stating that it resolved a name to something else. This is the
    # substitution signal that does NOT depend on the model string coming back
    # different: if the proxy ever echoes the alias instead of the concrete tag,
    # `model_served` looks like an exact match and only this field dissents.
    ("routing", "X-Olla-Routing-Strategy"),
    ("request_ids", "X-Olla-Request-Id"),
)

_FIELD_LIMITS = {"request_ids": MAX_REQUEST_IDS}


def _note_headers(provenance, headers):
    """Best-effort, and deliberately unable to fail the run.

    This mirrors `ledger.append_run`'s contract: provenance is telemetry, and a
    run that produced correct code must not be reported as failed because the
    bookkeeping about it went wrong. A response object without usable headers is
    the realistic case (a stub, a transport wrapper), and the cost of losing one
    row's attribution is a lot lower than the cost of losing the run.
    """
    if provenance is None or not headers:
        return
    try:
        for key, header in _HEADER_FIELDS:
            _note(provenance, key, headers.get(header), limit=_FIELD_LIMITS.get(key))
    except Exception:
        return


def _context_overflow_error(status, detail):
    return RuntimeError(
        f"ollama HTTP {status}: prompt exceeded context window "
        f"(ollama trimmed user message): {detail}. {CONTEXT_OVERFLOW_REMEDIATION}"
    )


def _note(provenance, key, value, limit=None):
    """Record a DISTINCT observed value under `key`, in first-seen order.

    A list, not a scalar, because a priority balancer re-decides per request --
    so a run is not guaranteed to be one experiment, and recording only the last
    turn would name one model for work two models did. Ordered rather than a set
    so the row stays JSON-serializable and the first backend is identifiable.

    Distinct keeps the model and endpoint fields short: a 20-turn run on one
    backend writes one entry, not twenty. **That argument does not hold for a
    value that is unique per request**, which is why `limit` exists -- an olla
    request id never repeats, so dedup never fires on it and the list grows with
    the turn count. `turns` already says how many requests there were, so a
    capped list is not a claim about their number.
    """
    if provenance is None or not value:
        return
    seen = provenance.setdefault(key, [])
    if value in seen:
        return
    if limit is not None and len(seen) >= limit:
        return
    seen.append(value)


def parse_chat_response(status, body, provenance=None):
    """Return (message, usage). `usage` carries ollama's own token counts —
    prompt_eval_count (input) and eval_count (output) — so a caller can attribute
    local-model spend. Both default to 0 when the daemon omits them (older builds
    or an interrupted stream), never None, so downstream sums stay numeric.

    A context overflow raises the diagnostic form of RuntimeError, on either the
    non-200 body or a 200 carrying an "error" key. The sentinel is only ever read
    from a body ollama itself reported as failed: a successful 200 whose assistant
    content merely quotes the phrase is a model turn, not an error."""
    if status != 200:
        if CONTEXT_OVERFLOW_SENTINEL in body:
            raise _context_overflow_error(status, body[:200])
        raise RuntimeError(f"ollama HTTP {status}: {body[:200]}")
    try:
        data = json.loads(body)
    except ValueError as e:
        raise RuntimeError(f"ollama {status}: unparseable body: {body[:200]}") from e
    # The model that ANSWERED, which against a router is not the one we asked
    # for. `local-coder` resolved to a 14.8b build while the docs said 27b
    # (#667), and this field was being parsed and discarded on every turn.
    _note(provenance, "model_served", data.get("model"))
    if "error" in data:
        err = data["error"]
        if isinstance(err, str) and CONTEXT_OVERFLOW_SENTINEL in err:
            raise _context_overflow_error(status, err)
        raise RuntimeError(f"ollama error: {err}")
    if "message" not in data:
        raise RuntimeError(f"ollama 200 with no message: {body[:200]}")
    usage = {
        "input": int(data.get("prompt_eval_count") or 0),
        "output": int(data.get("eval_count") or 0),
    }
    return data["message"], usage


def ollama_transport(model, host=DEFAULT_HOST, temperature=0.7, num_ctx=16384, timeout=600,
                     think=None, provenance=None):
    """Return a transport(messages, tools) -> (assistant message dict, usage dict).

    Raises RuntimeError on any non-success response and re-raises URLError
    (daemon down) so the caller sees a failure rather than a silent hang.

    `think` controls a thinking model's reasoning phase: None leaves it to the model
    (the historical behaviour), False suppresses it. It is a caller decision rather
    than a per-model default because the right answer depends on the shape of the
    turn, not on the weights. Measured on qwen3.8:27b, 2026-08-17: one long analytic
    turn over a 1,464-token diff spent its whole output budget thinking and never
    reached an answer inside 600s, while the same request with think=False finished
    in 62s; a task made of many short turns is unaffected either way.

    `provenance`, when given a dict, accumulates who actually served each turn:
    `model_served` from the response body, plus `endpoint`, `proxy` and
    `request_ids` from a proxy's response headers. The caller owns the dict and
    reads it after the run, so the transport's (message, usage) contract is
    unchanged and every existing stub keeps working.
    """
    url = f"http://{host}/api/chat"

    def transport(messages, tools):
        body = {
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": False,
            "options": {"temperature": temperature, "num_ctx": num_ctx},
        }
        # Omitted entirely when None. Sending "think": null asks older daemons to parse
        # a field they do not know, and the default has to stay byte-identical to what
        # shipped before this parameter existed.
        if think is not None:
            body["think"] = think
        payload = json.dumps(body).encode()
        req = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"})
        for attempt in range(1, MAX_HTTP_ATTEMPTS + 1):
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    _note_headers(provenance, getattr(resp, "headers", None))
                    return parse_chat_response(resp.status, resp.read().decode(errors="replace"),
                                               provenance=provenance)
            except urllib.error.HTTPError as e:
                try:
                    if e.code not in RETRYABLE_HTTP_STATUSES:
                        # Headers first: parse_chat_response raises on an error
                        # body, and a failed turn still needs to name its backend.
                        _note_headers(provenance, getattr(e, "headers", None))
                        return parse_chat_response(e.code, e.read().decode(errors="replace"),
                                                   provenance=provenance)
                    # The endpoint that just 503'd. Without this a flaky backend
                    # that fails twice before a healthy one answers is invisible,
                    # which is exactly the "which machine" question this records.
                    _note_headers(provenance, getattr(e, "headers", None))
                    if attempt == MAX_HTTP_ATTEMPTS:
                        raise RuntimeError(
                            f"ollama HTTP {e.code} after {attempt} attempts for model {model}"
                        ) from e
                finally:
                    e.close()
                print(
                    f"warning: ollama HTTP {e.code} on attempt {attempt}/{MAX_HTTP_ATTEMPTS}, retrying in {RETRY_BACKOFF_SECONDS * attempt:.1f}s",
                    file=sys.stderr,
                )
                time.sleep(RETRY_BACKOFF_SECONDS * attempt)
            except urllib.error.URLError as e:
                raise RuntimeError(f"ollama unreachable at {url}: {e.reason}") from e

    return transport
