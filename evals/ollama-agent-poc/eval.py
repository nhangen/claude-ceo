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
