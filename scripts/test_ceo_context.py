import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).with_name("ceo")


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.vault = Path(self.tmp.name) / "vault"
        self.vault.mkdir()
        (self.vault / "evidence.md").write_text("Current fact. Historical fact. Explicit authorization to accept these facts.")
        self.env = dict(os.environ, CEO_VAULT=str(self.vault))

    def cli(self, *args, ok=True):
        result = subprocess.run(["bash", str(CLI), "context", *args], env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def ingest(self, value="Current", **extra):
        record = dict(subject="employment.example", key="status", value=value,
                      effective_from="2026-08-11", authority="document", visibility="report",
                      source="evidence.md", quote="Current fact.")
        record.update(extra)
        p = Path(self.tmp.name) / "record.json"
        p.write_text(json.dumps(record))
        return json.loads(self.cli("ingest", "--record", str(p)).stdout)["id"]

    def decide(self, action, claim):
        return self.cli(action, claim, "--actor", "test-agent", "--authorization-source", "evidence.md",
                        "--authorization-quote", "Explicit authorization to accept these facts.")

    def view(self, day="2026-09-26"):
        return json.loads(self.cli("list", "--as-of", day).stdout)

    def test_candidate_idempotence_and_acceptance(self):
        claim = self.ingest()
        self.assertEqual(self.ingest(), claim)
        self.assertEqual(self.view()["facts"], [])
        self.decide("accept", claim)
        self.assertEqual([f["value"] for f in self.view()["facts"]], ["Current"])
        self.assertIn(claim, self.cli("render").stdout)

    def test_effective_supersession_never_resurrects(self):
        old = self.ingest("Former active", effective_from="2026-01-01")
        self.decide("accept", old)
        successor = self.ingest("Inactive", supersedes=[old], visibility="private")
        self.decide("accept", successor)
        self.assertEqual(self.view()["facts"], [])
        self.decide("withdraw", successor)
        self.assertEqual(self.view()["facts"], [])
        self.assertNotIn("Former active", self.cli("render").stdout)

    def test_future_replacement_and_old_reingestion(self):
        old = self.ingest("Old", effective_from="2026-01-01")
        self.decide("accept", old)
        new = self.ingest("New", effective_from="2026-10-01", supersedes=[old])
        self.decide("accept", new)
        self.assertEqual(self.view()["facts"][0]["value"], "Old")
        self.assertEqual(self.view("2026-10-02")["facts"][0]["value"], "New")
        self.assertEqual(self.ingest("Old", effective_from="2026-01-01"), old)
        self.assertEqual(self.view("2026-10-02")["facts"][0]["value"], "New")

    def test_conflicting_claims_excluded_and_private_content_stays_private(self):
        first = self.ingest("Public")
        self.decide("accept", first)
        private = self.ingest("SECRET VALUE", visibility="private")
        self.decide("accept", private)
        result = self.view()
        self.assertEqual(result["facts"], [])
        self.assertTrue(result["diagnostics"])
        self.assertNotIn("SECRET VALUE", self.cli("render").stdout)

    def test_source_drift_keeps_snapshot_but_reports_degradation(self):
        claim = self.ingest()
        self.decide("accept", claim)
        (self.vault / "evidence.md").write_text("Unrelated appended activity")
        result = self.view()
        self.assertEqual(result["facts"][0]["value"], "Current")
        self.assertTrue(result["diagnostics"])

    def test_expired_replacement_does_not_revive_predecessor(self):
        old = self.ingest("Old", effective_from="2026-01-01")
        self.decide("accept", old)
        new = self.ingest("New", supersedes=[old], review_after="2026-08-12")
        self.decide("accept", new)
        self.assertEqual(self.view()["facts"], [])
        self.assertTrue(self.view()["diagnostics"])

    def test_inference_cannot_be_accepted(self):
        claim = self.ingest(authority="inferred")
        r = self.cli("accept", claim, "--actor", "test", "--authorization-source", "evidence.md",
                     "--authorization-quote", "Explicit authorization to accept these facts.", ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.view()["facts"], [])

    def test_generated_sources_and_path_escape_rejected(self):
        for source in ["../outside", "/tmp/outside", "CEO/reports/current.md"]:
            with self.subTest(source=source):
                p = Path(self.tmp.name) / "record.json"
                p.write_text(json.dumps(dict(subject="s", key="k", value="v", source=source, quote="x", effective_from="2026-01-01")))
                self.assertNotEqual(self.cli("ingest", "--record", str(p), ok=False).returncode, 0)

    def test_inventory_exposes_candidates_without_private_values(self):
        claim = self.ingest("PRIVATE VALUE", visibility="private")
        result = self.cli("inventory").stdout
        self.assertIn(claim, result)
        self.assertIn("candidate", result)
        self.assertNotIn("PRIVATE VALUE", result)

    def test_nonoverlapping_effective_intervals(self):
        old = self.ingest("Old", effective_from="2026-01-01", effective_until="2026-05-31")
        self.decide("accept", old)
        new = self.ingest("New", effective_from="2026-06-01")
        self.decide("accept", new)
        self.assertEqual(self.view("2026-05-31")["facts"][0]["value"], "Old")
        self.assertEqual(self.view("2026-06-01")["facts"][0]["value"], "New")

    def test_schema_invalid_but_checksum_valid_ledger_is_rejected(self):
        claim = self.ingest()
        self.decide("accept", claim)
        path = next((self.vault / "CEO/log/context").glob("*.md"))
        lines = path.read_text().splitlines()
        event = json.loads(lines[-1][2:])
        event["payload"]["action"] = "approve"
        payload = json.dumps(event["payload"], sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        event["id"] = hashlib.sha256(payload.encode()).hexdigest()
        path.write_text("\n".join(lines[:-1] + ["- " + json.dumps(event)]) + "\n")
        self.assertNotEqual(self.cli("render", ok=False).returncode, 0)

    def test_conflicting_decisions_and_sync_conflict_stop_promotion(self):
        claim = self.ingest()
        self.decide("accept", claim)
        self.decide("reject", claim)
        self.assertEqual(self.view()["facts"], [])
        self.assertTrue(self.view()["diagnostics"])
        (self.vault / "CEO/log/context/2026-09.sync-conflict.md").touch()
        self.assertNotEqual(self.cli("render", ok=False).returncode, 0)

    def test_withdrawal_resolves_dispute_without_reviving_predecessor(self):
        old = self.ingest("Old", effective_from="2026-01-01")
        self.decide("accept", old)
        disputed = self.ingest("Disputed", supersedes=[old])
        self.decide("accept", disputed)
        self.decide("reject", disputed)
        self.decide("withdraw", disputed)
        self.assertEqual(self.view()["facts"], [])
        current = self.ingest("New", effective_from="2026-09-01")
        self.decide("accept", current)
        self.assertEqual(self.view()["facts"][0]["value"], "New")

    def test_symlink_source_escape_rejected(self):
        outside = Path(self.tmp.name) / "outside.md"
        outside.write_text("Current fact.")
        (self.vault / "link.md").symlink_to(outside)
        record = Path(self.tmp.name) / "record.json"
        record.write_text(json.dumps(dict(subject="s", key="k", value="v", source="link.md", quote="Current fact.", effective_from="2026-01-01")))
        self.assertNotEqual(self.cli("ingest", "--record", str(record), ok=False).returncode, 0)

    def test_atomic_build_and_corruption_have_no_profile_fallback(self):
        claim = self.ingest()
        self.decide("accept", claim)
        self.cli("build")
        p = self.vault / "CEO/reports/context/current.json"
        before = p.stat().st_mtime_ns
        self.cli("build")
        self.assertEqual(p.stat().st_mtime_ns, before)
        ledger = next((self.vault / "CEO/log/context").glob("*.md"))
        with ledger.open("a") as f:f.write("partial record")
        r = self.cli("render", ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("Current", r.stdout)


if __name__ == "__main__":
    unittest.main()
