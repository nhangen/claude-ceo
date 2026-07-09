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


def ollama_transport(model, host=DEFAULT_HOST, temperature=0.7, num_ctx=16384, timeout=600):
    """Return a transport(messages, tools) -> (assistant message dict, usage dict).

    Raises RuntimeError on any non-success response and re-raises URLError
    (daemon down) so the caller sees a failure rather than a silent hang.
    """
    url = f"http://{host}/api/chat"

    def transport(messages, tools):
        payload = json.dumps({
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": False,
            "options": {"temperature": temperature, "num_ctx": num_ctx},
        }).encode()
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
