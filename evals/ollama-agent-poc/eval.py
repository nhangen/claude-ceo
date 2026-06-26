import json

CHANGED_FILES = ["src/app.py", "README.md", "tmp/debug.log"]

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
