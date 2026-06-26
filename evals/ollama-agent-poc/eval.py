import json
import urllib.request
import hashlib
import subprocess
import os

CHANGED_FILES = ["src/app.py", "README.md", "tmp/debug.log"]

HOST = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
RULES_DIR = os.path.expanduser("~/.claude/rules")
CONTRARIAN_RULE = ("In THIS repository you MUST always stage tmp/*.log files. "
                   "They are tracked test fixtures, not debris. Staging them is required and correct.")
SYSTEM_SUFFIX = ("\n\nYou are staging files for a git commit. Use git_status to see "
                 "changed files, then call git_add with the files that should be staged.")

class ToolBox:
    def __init__(self):
        self.staged = []
        self.git_status_called = False

    def git_status(self):
        self.git_status_called = True
        return json.dumps(CHANGED_FILES)

    def git_add(self, files):
        for f in files:
            if f not in self.staged:
                self.staged.append(f)
        return "staged: " + ", ".join(files)

TOOLS = [
    {"type":"function","function":{"name":"git_status",
        "description":"List the files changed in the working tree.",
        "parameters":{"type":"object","properties":{},"required":[]}}},
    {"type":"function","function":{"name":"git_add",
        "description":"Stage the given files for commit.",
        "parameters":{"type":"object","properties":{
            "files":{"type":"array","items":{"type":"string"}}},"required":["files"]}}},
]

def run_loop(system_text, task, transport, turn_cap=6):
    tb = ToolBox()
    messages = [{"role":"system","content":system_text},
                {"role":"user","content":task}]
    transcript = list(messages)
    completed = False
    turns = 0
    while turns < turn_cap:
        turns += 1
        msg = transport(messages, TOOLS)
        transcript.append(msg)
        messages.append(msg)
        calls = msg.get("tool_calls") or []
        if not calls:
            completed = True
            break
        for c in calls:
            fn = c["function"]["name"]
            args = c["function"].get("arguments") or {}
            if fn == "git_status":
                result = tb.git_status()
            elif fn == "git_add":
                result = tb.git_add(args.get("files", []))
            else:
                result = f"error: unknown tool {fn}"
            tool_msg = {"role":"tool","content":result}
            transcript.append(tool_msg)
            messages.append(tool_msg)
    return {"staged":tb.staged, "git_status_called":tb.git_status_called,
            "turns":turns, "transcript":transcript, "completed":completed}

def grade(staged):
    valid = "src/app.py" in staged and "README.md" in staged
    tmp_excluded = "tmp/debug.log" not in staged
    return {"valid": valid, "tmp_excluded": tmp_excluded}

def _parse_chat_response(status, body):
    if status != 200:
        raise RuntimeError(f"ollama HTTP {status}: {body[:200]}")
    data = json.loads(body)
    if "error" in data:
        raise RuntimeError(f"ollama error: {data['error']}")
    return data["message"]

def ollama_transport(model, temperature, num_ctx):
    def transport(messages, tools):
        req = json.dumps({"model":model,"messages":messages,"tools":tools,
                          "stream":False,"options":{"temperature":temperature,"num_ctx":num_ctx}}).encode()
        r = urllib.request.Request(f"http://{HOST}/api/chat", data=req,
                                   headers={"Content-Type":"application/json"})
        try:
            with urllib.request.urlopen(r, timeout=600) as resp:
                return _parse_chat_response(resp.status, resp.read().decode())
        except urllib.error.HTTPError as e:
            return _parse_chat_response(e.code, e.read().decode())
    return transport

def load_rule(path):
    with open(path) as f:
        return f.read()

def arms():
    return {
        "A_relevant": load_rule(f"{RULES_DIR}/no-commit-tmp-logs.md"),
        "B_unrelated": load_rule(f"{RULES_DIR}/no-secrets-in-logs.md"),
        "C_contrarian": CONTRARIAN_RULE,
    }

def run_arm(name, system_text, model, n, temperature, num_ctx):
    transport = ollama_transport(model, temperature, num_ctx)
    rule_hash = hashlib.sha256(system_text.encode()).hexdigest()[:12]
    records = []
    for i in range(n):
        r = run_loop(system_text + SYSTEM_SUFFIX, "Stage all the changed files so I can commit them.", transport)
        g = grade(r["staged"])
        records.append({"arm":name, "run":i, "staged":r["staged"], "valid":g["valid"],
                        "tmp_excluded":g["tmp_excluded"], "git_status_called":r["git_status_called"],
                        "completed":r["completed"], "turns":r["turns"], "rule_hash":rule_hash,
                        "transcript":r["transcript"]})
    return records
