"""HTTP transport to ollama's /api/chat tools endpoint.

The success check is explicit on both the urlopen and HTTPError paths: ollama
returns a 200 body carrying an "error" key for some failures, and a non-200 for
others. Treating "no exception" as success would record an HTTP error as a model
turn (non-throwing-client-success-check).
"""
import json
import urllib.error
import urllib.request

DEFAULT_HOST = "127.0.0.1:11434"


def parse_chat_response(status, body):
    """Return (message, usage). `usage` carries ollama's own token counts —
    prompt_eval_count (input) and eval_count (output) — so a caller can attribute
    local-model spend. Both default to 0 when the daemon omits them (older builds
    or an interrupted stream), never None, so downstream sums stay numeric."""
    if status != 200:
        raise RuntimeError(f"ollama HTTP {status}: {body[:200]}")
    data = json.loads(body)
    if "error" in data:
        raise RuntimeError(f"ollama error: {data['error']}")
    if "message" not in data:
        raise RuntimeError(f"ollama 200 with no message: {body[:200]}")
    usage = {
        "input": int(data.get("prompt_eval_count") or 0),
        "output": int(data.get("eval_count") or 0),
    }
    return data["message"], usage


def ollama_transport(model, host=DEFAULT_HOST, temperature=0.7, num_ctx=16384, timeout=600,
                     think=None):
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
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return parse_chat_response(resp.status, resp.read().decode())
        except urllib.error.HTTPError as e:
            return parse_chat_response(e.code, e.read().decode())
        except urllib.error.URLError as e:
            raise RuntimeError(f"ollama unreachable at {url}: {e.reason}") from e

    return transport
