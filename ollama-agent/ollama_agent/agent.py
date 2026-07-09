"""The agent loop: drive a model through tool calls until it stops or hits the cap."""
import json


def _normalize_args(raw):
    """ollama builds return tool-call arguments as either a dict or a JSON string.
    Normalize to a dict; a non-JSON string becomes {} so a malformed call degrades
    to an unknown/empty call rather than crashing the loop."""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            v = json.loads(raw or "{}")
            return v if isinstance(v, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def _tool_calls_from_content(content):
    """Recover tool calls a model serialized into `content` instead of the native
    `tool_calls` field.

    Some ollama chat templates (e.g. qwen2.5-coder) emit a correct
    ``{"name": ..., "arguments": ...}`` object as assistant *text* while leaving
    ``message.tool_calls`` empty, so the native read at the drop site loses the
    call and the loop ends as if the model answered in prose. This parses that
    object (optionally inside a ``` fence) back into the native envelope shape so
    the dispatch loop handles it identically.

    Returns [] when content is prose or JSON that isn't a tool call, so a
    text-only model (e.g. glm, which narrates instead of calling) still completes
    as a normal no-call turn rather than crashing. Requires both a non-empty
    string ``name`` and an ``arguments`` key to avoid misreading an ordinary JSON
    answer that merely happens to carry a ``name`` field as a call."""
    if not isinstance(content, str):
        return []
    text = content.strip()
    if text.startswith("```"):
        # Drop the opening fence line (``` or ```json) and a trailing fence.
        text = text.split("\n", 1)[1] if "\n" in text else ""
        text = text.strip()
        if text.endswith("```"):
            text = text[:-3].strip()
    try:
        parsed = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return []
    items = parsed if isinstance(parsed, list) else [parsed]
    calls = []
    for it in items:
        if isinstance(it, dict) and isinstance(it.get("name"), str) and it["name"] and "arguments" in it:
            calls.append({"function": {"name": it["name"], "arguments": it["arguments"]}})
    return calls


def run_agent(task, system, transport, toolbox, tools, turn_cap=8, run_id=None,
              verify_cmd=None):
    """Run one task to completion (a turn with no tool calls) or the turn cap.

    Returns a record: completed, turns, the full transcript, and the toolbox's
    call log + unknown-tool list so a hallucinated tool reads as a hallucination,
    not a silent capability loss.

    `run_id` is an optional caller-minted identifier echoed back in the record so
    a downstream ingestion pass can dedup this run's findings (the bridge itself
    does not mint one — a standalone run leaves it None). Additive.

    `verify_cmd` is an optional shell command that gates completion: when the
    model stops (a turn with no tool calls), the command runs in the toolbox's
    cwd and the stop is accepted only if it exits 0. A non-zero exit feeds the
    failure back and the loop continues, so the run drives to a green gate rather
    than to the model's own say-so. `verified` is None when no gate is configured,
    else the last check's pass/fail; the turn cap still bounds the loop.
    """
    messages = [{"role": "system", "content": system},
                {"role": "user", "content": task}]
    transcript = list(messages)
    completed = False
    verified = None
    turns = 0
    ollama_input_tokens = 0
    ollama_output_tokens = 0
    while turns < turn_cap:
        turns += 1
        msg, usage = transport(messages, tools)
        ollama_input_tokens += usage.get("input", 0)
        ollama_output_tokens += usage.get("output", 0)
        transcript.append(msg)
        messages.append(msg)
        calls = msg.get("tool_calls") or []
        if not calls:
            # Fallback: some templates serialize the call into content with an
            # empty native tool_calls field — recover it before concluding the
            # model answered in prose.
            calls = _tool_calls_from_content(msg.get("content"))
        if not calls:
            if verify_cmd:
                res = json.loads(toolbox.run_shell(verify_cmd))
                if res.get("returncode") == 0:
                    verified = True
                    completed = True
                    break
                verified = False
                feedback = {"role": "user", "content": (
                    "Verification command `%s` is not passing yet (returncode=%s). "
                    "Fix the remaining failures and keep going — do not stop until "
                    "it exits 0.\nstdout:\n%s\nstderr:\n%s" % (
                        verify_cmd, res.get("returncode"),
                        res.get("stdout", ""), res.get("stderr", "")))}
                transcript.append(feedback)
                messages.append(feedback)
                continue
            completed = True
            break
        for c in calls:
            fn_obj = c.get("function") or {}
            fn = fn_obj.get("name")
            if not fn:
                # A malformed call envelope (no function/name) is a hallucination,
                # not a reason to crash the run — record it and feed an error back,
                # mirroring dispatch's unknown-tool path.
                toolbox.unknown_calls.append(fn)
                result = json.dumps({"error": "malformed tool_call: missing function name"})
            else:
                args = _normalize_args(fn_obj.get("arguments"))
                result = toolbox.dispatch(fn, args)
            tool_msg = {"role": "tool", "content": result}
            transcript.append(tool_msg)
            messages.append(tool_msg)
    return {
        "completed": completed,
        "verified": verified,
        "turns": turns,
        "run_id": run_id,
        "ollama_input_tokens": ollama_input_tokens,
        "ollama_output_tokens": ollama_output_tokens,
        "transcript": transcript,
        "calls": toolbox.calls,
        "unknown_calls": toolbox.unknown_calls,
        "tool_errors": toolbox.tool_errors,
    }
