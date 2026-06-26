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


def run_agent(task, system, transport, toolbox, tools, turn_cap=8):
    """Run one task to completion (a turn with no tool calls) or the turn cap.

    Returns a record: completed, turns, the full transcript, and the toolbox's
    call log + unknown-tool list so a hallucinated tool reads as a hallucination,
    not a silent capability loss.
    """
    messages = [{"role": "system", "content": system},
                {"role": "user", "content": task}]
    transcript = list(messages)
    completed = False
    turns = 0
    while turns < turn_cap:
        turns += 1
        msg = transport(messages, tools)
        transcript.append(msg)
        messages.append(msg)
        calls = msg.get("tool_calls") or []
        if not calls:
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
        "turns": turns,
        "transcript": transcript,
        "calls": toolbox.calls,
        "unknown_calls": toolbox.unknown_calls,
    }
