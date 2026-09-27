import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent
DISCOVER = ROOT / "ceo-context-discover.py"
CONTEXT = ROOT / "ceo-context.py"


class ContextDiscoverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name) / "vault"
        (self.vault / "CEO").mkdir(parents=True)
        (self.vault / "Profile/_inbox").mkdir(parents=True)
        (self.vault / "CEO/from-nathan.md").write_text("## For the CEO\n- My current focus changed.\n")
        self.fresh = Path(self.temp.name) / "fresh.sh"
        self.fresh.write_text("#!/bin/bash\nexit 0\n")
        self.fresh.chmod(0o755)

    def discover(self, fresh=None):
        env = dict(os.environ, CEO_VAULTKEEPER_STALENESS_CMD=str(fresh or self.fresh))
        result = subprocess.run(["python3", str(DISCOVER), "--vault", str(self.vault), "--context-script", str(CONTEXT)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def context(self, *args):
        return subprocess.run(["python3", str(CONTEXT), "--vault", str(self.vault), *args], capture_output=True, text=True)

    def test_new_source_is_private_idempotent_candidate(self):
        first = self.discover()
        second = self.discover()
        self.assertTrue(first["candidates"])
        self.assertFalse(second["candidates"])
        inventory = self.context("inventory")
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        item = json.loads(inventory.stdout)[0]
        self.assertEqual(item["state"], "candidate")
        self.assertEqual(item["visibility"], "private")
        self.assertNotIn("My current focus", (self.vault / "CEO/alerts/context-discover.md").read_text())

    def test_fresh_update_makes_new_candidate_and_never_auto_accepts(self):
        old = self.discover()["candidates"][0]
        (self.vault / "CEO/from-nathan.md").write_text("## For the CEO\n- A newer current focus changed.\n")
        current = self.discover()["candidates"][0]
        self.assertNotEqual(old, current)
        inventory = json.loads(self.context("inventory").stdout)
        self.assertTrue(all(item["state"] == "candidate" for item in inventory))

    def test_explicit_fact_record_and_authorization_can_promote_a_discovery(self):
        self.discover()
        source = self.vault / "CEO/from-nathan.md"
        source.write_text("## For the CEO\n- Current research focus is active.\n")
        self.discover()
        authorization = self.vault / "context-authorization.md"
        authorization.write_text("I authorize reporting the current research focus.\n")
        record = {
            "subject": "research",
            "key": "focus",
            "value": "Current research focus",
            "effective_from": "2026-09-26",
            "authority": "document",
            "visibility": "report",
            "source": "CEO/from-nathan.md",
            "quote": "Current research focus is active.",
        }
        record_file = Path(self.temp.name) / "report-record.json"
        record_file.write_text(json.dumps(record))
        ingested = self.context("ingest", "--record", str(record_file))
        self.assertEqual(ingested.returncode, 0, ingested.stderr)
        claim = json.loads(ingested.stdout)["id"]
        accepted = self.context("accept", claim, "--actor", "test", "--authorization-source", "context-authorization.md", "--authorization-quote", "I authorize reporting the current research focus.")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        rendered = self.context("render")
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("Current research focus", rendered.stdout)

    def test_stale_vaultkeeper_blocks_discovery_without_ledger_write(self):
        stale = Path(self.temp.name) / "stale.sh"
        stale.write_text("#!/bin/bash\necho stale\n")
        stale.chmod(0o755)
        result = self.discover(stale)
        self.assertEqual(result["skipped"], "vaultkeeper")
        self.assertFalse((self.vault / "CEO/log/context").exists())
        self.assertIn("status: unknown", (self.vault / "CEO/alerts/context-discover.md").read_text())

    def test_discretion_holds_source_without_copying_content(self):
        (self.vault / "Profile/discretion-denylist.txt").write_text("secret project\n")
        (self.vault / "CEO/from-nathan.md").write_text("## For the CEO\n- secret project changes.\n")
        result = self.discover()
        self.assertFalse(result["candidates"])
        self.assertTrue(result["held"])
        self.assertFalse((self.vault / "CEO/log/context").exists())
        self.assertNotIn("secret project", (self.vault / "CEO/alerts/context-discover.md").read_text())

    def test_environment_discretion_holds_source_without_copying_content(self):
        self.fresh.write_text("#!/bin/bash\nexit 0\n")
        env = dict(os.environ, CEO_VAULTKEEPER_STALENESS_CMD=str(self.fresh), CEO_DISCRETION_DENY="private initiative")
        (self.vault / "CEO/from-nathan.md").write_text("## For the CEO\n- private initiative changes.\n")
        result = subprocess.run(["python3", str(DISCOVER), "--vault", str(self.vault), "--context-script", str(CONTEXT)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["held"])
        self.assertFalse((self.vault / "CEO/log/context").exists())


if __name__ == "__main__":
    unittest.main()
