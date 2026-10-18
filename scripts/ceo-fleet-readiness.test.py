import datetime
import importlib.util
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parent


class ReporterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.observation = self.root / "observation.json"
        self.checker = self.root / "checker.py"
        self.checker.write_text("import pathlib,sys\nprint(pathlib.Path(__file__).with_name('observation.json').read_text())\n")
        self.outcome = self.root / "outcome"
        self.registry = self.root / "registry.json"
        self.registry.write_text(json.dumps({"machines": [{"id": "mac"}], "local_ci": {"machine_id": "mac", "repos": ["llm-tools"]}}))
        self.latest = self.root / "CEO/reports/fleet-readiness-test.json"

    def tearDown(self):
        self.temporary.cleanup()

    def state(self):
        text = (self.root / "CEO/alerts/fleet-readiness-test.md").read_text()
        return json.loads(text.split("<!-- fleet-readiness-state -->\n```json\n")[1].split("\n```", 1)[0])

    def run_report(self, checks, stale=False, workflow_evidence=None, telemetry=None):
        failures = sorted("mac:" + k for k, v in checks.items() if v == "fail")
        unknown = sorted("mac:" + k for k, v in checks.items() if v == "unknown")
        status = "fail" if failures else "unknown" if unknown else "pass"
        stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1 if stale else 0)
        report = {"schema_version": 1, "read_only": True, "checked_at": stamp.isoformat(), "status": status, "failures": failures, "unknown": unknown, "machines": [{"id": "mac", "checks": checks}]}
        if workflow_evidence is not None:
            report["workflow_evidence"] = workflow_evidence
        if telemetry is not None:
            report["telemetry"] = telemetry
        self.observation.write_text(json.dumps(report))
        return subprocess.run(["python3", str(ROOT / "ceo-fleet-readiness-report.py"), "--vault", str(self.root), "--host", "test", "--checker", str(self.checker), "--registry", str(self.registry), "--outcome-file", str(self.outcome)], capture_output=True, text=True)

    def test_telemetry_is_sanitized_in_both_publications(self):
        telemetry = {
            "mac": {
                "disk_free_bytes": 1024,
                "ram_available_bytes": 2048,
                "memory_pressure_free_pct": 54,
                "gpu_temperatures_c": [45, 46.5],
                "gpu_power_limits_w": [250],
                "versions": {"git": "2.48.1", "python3": "3.14", "node": "secret-test-value", "token": "1.2.3"},
                "volumes_free_bytes": {"C:": 4096, "D:": -1, "secret-test-value": 8192},
                "token": "secret-test-value",
            },
            "invalid": {
                "disk_free_bytes": True,
                "ram_available_bytes": -1,
                "memory_pressure_free_pct": 2**64 + 1,
                "gpu_temperatures_c": [True],
                "gpu_power_limits_w": [1001],
                "versions": {"git": 123, "node": "1.2.3-secret-test-value"},
                "volumes_free_bytes": {"C:": True, "D:": 2**64 + 1},
            },
        }
        expected = {
            "mac": {
                "disk_free_bytes": 1024,
                "ram_available_bytes": 2048,
                "memory_pressure_free_pct": 54,
                "gpu_temperatures_c": [45, 46.5],
                "gpu_power_limits_w": [250],
                "versions": {"git": "2.48.1", "python3": "3.14"},
                "volumes_free_bytes": {"C:": 4096},
            },
            "invalid": {"versions": {}, "volumes_free_bytes": {}},
        }
        self.assertEqual(self.run_report({"api": "pass"}, telemetry=telemetry).returncode, 0)
        self.assertEqual(self.state()["telemetry"], expected)
        self.assertEqual(json.loads(self.latest.read_text())["telemetry"], expected)

    def test_workflow_evidence_survives_state_and_latest_publication(self):
        completed = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)
        evidence = {"llm-tools": {"completed_at": completed.isoformat(), "age_seconds": 7 * 86400}}
        self.assertEqual(self.run_report({"local-ci:workflow:llm-tools": "pass"}, workflow_evidence=evidence).returncode, 0)
        self.assertEqual(self.state()["workflow_evidence"], evidence)
        latest = json.loads(self.latest.read_text())
        self.assertEqual(latest["workflow_evidence"], evidence)
        self.assertEqual(latest["publication_id"], self.state()["publication_id"])

    def test_workflow_evidence_must_match_roster_and_check(self):
        completed = datetime.datetime.now(datetime.timezone.utc)
        evidence = {"other": {"completed_at": completed.isoformat(), "age_seconds": 0}}
        self.assertEqual(self.run_report({"local-ci:workflow:other": "pass"}, workflow_evidence=evidence).returncode, 1)
        self.assertFalse(self.latest.exists())
        evidence = {"llm-tools": {"completed_at": completed.isoformat(), "age_seconds": 0}}
        self.assertEqual(self.run_report({"workflow": "pass"}, workflow_evidence=evidence).returncode, 1)
        self.assertFalse(self.latest.exists())

    def test_invalid_workflow_evidence_cannot_publish(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        cases = (
            [],
            {"../repo": {"completed_at": now.isoformat(), "age_seconds": 0}},
            {"llm-tools": {"completed_at": "not-a-time", "age_seconds": 0}},
            {"llm-tools": {"completed_at": (now + datetime.timedelta(minutes=1)).isoformat(), "age_seconds": 0}},
            {"llm-tools": {"completed_at": (now - datetime.timedelta(days=7)).isoformat(), "age_seconds": 0}},
        )
        for evidence in cases:
            with self.subTest(evidence=evidence):
                self.assertEqual(self.run_report({"local-ci:workflow:llm-tools": "pass"}, workflow_evidence=evidence).returncode, 1)
                self.assertFalse(self.latest.exists())

    def test_baseline_and_unchanged_failures_are_quiet_new_failure_fires(self):
        self.assertEqual(self.run_report({"api": "fail"}).returncode, 0)
        self.assertEqual(self.outcome.read_text(), "noop")
        self.assertEqual(self.run_report({"api": "fail"}).returncode, 0)
        self.assertEqual(self.outcome.read_text(), "noop")
        self.assertEqual(self.run_report({"api": "fail", "github": "fail"}).returncode, 0)
        self.assertEqual(self.outcome.read_text(), "fired")

    def test_unknown_preserves_failure_and_positive_recovery_fires(self):
        self.run_report({"api": "fail", "trust": "unknown"})
        self.assertEqual(self.run_report({"api": "unknown", "trust": "unknown"}).returncode, 0)
        self.assertEqual(self.state()["active_failures"], ["mac:api"])
        self.assertEqual(self.run_report({"api": "pass", "trust": "unknown"}).returncode, 0)
        self.assertEqual(self.state()["active_failures"], [])
        self.assertEqual(self.outcome.read_text(), "fired")

    def test_missing_evidence_cannot_clear_prior_failure(self):
        self.run_report({"api": "fail"})
        self.run_report({"trust": "unknown"})
        self.assertEqual(self.state()["active_failures"], ["mac:api"])

    def test_stale_report_cannot_modify_prior_state(self):
        self.run_report({"api": "fail"})
        before = self.latest.read_text()
        alert = self.root / "CEO/alerts/fleet-readiness-test.md"
        before_alert = alert.read_text()
        before_publication_id = self.state()["publication_id"]
        result = self.run_report({"api": "pass"}, stale=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.latest.read_text(), before)
        self.assertEqual(alert.read_text(), before_alert)
        self.assertEqual(self.state()["publication_id"], before_publication_id)

    def test_uppercase_harness_identity_is_valid(self):
        result = self.run_report({"file:.codex/AGENTS.md": "fail"})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.state()["active_failures"], ["mac:file:.codex/AGENTS.md"])

    def test_history_failure_cannot_publish_recovery(self):
        self.run_report({"api": "fail"})
        alert = self.root / "CEO/alerts/fleet-readiness-test.md"
        before = (self.latest.read_text(), alert.read_text())
        log = self.root / "CEO/log/fleet-readiness" / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m") + ".md")
        log.unlink()
        log.mkdir()
        self.assertEqual(self.run_report({"api": "pass"}).returncode, 1)
        self.assertEqual((self.latest.read_text(), alert.read_text()), before)

    def test_persistent_failure_cannot_commit_recovery(self):
        spec = importlib.util.spec_from_file_location("reporter", ROOT / "ceo-fleet-readiness-report.py")
        reporter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reporter)
        for failing_write in (1, 2, 3):
            with self.subTest(failing_write=failing_write):
                self.run_report({"api": "fail"})
                alert = self.root / "CEO/alerts/fleet-readiness-test.md"
                before = alert.read_text()
                before_state = self.state()
                stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
                report = {"schema_version": 1, "read_only": True, "checked_at": stamp, "status": "pass", "failures": [], "unknown": [], "machines": [{"id": "mac", "checks": {"api": "pass"}}]}
                real_write = reporter.atomic_write
                count = 0

                def fail_persistently_before_write(path, body):
                    nonlocal count
                    count += 1
                    if count >= failing_write:
                        raise OSError("injected persistence failure")
                    real_write(path, body)

                with patch.object(reporter, "atomic_write", side_effect=fail_persistently_before_write):
                    with self.assertRaises(OSError):
                        reporter.publish(report, json.loads(self.registry.read_text()), self.root, "test", self.outcome)
                self.assertEqual(alert.read_text(), before)
                self.assertEqual(self.state()["active_failures"], ["mac:api"])
                latest = json.loads(self.latest.read_text())
                self.assertEqual(self.state()["publication_id"], before_state["publication_id"])
                self.assertFalse(latest["status"] == "pass" and latest["publication_id"] == self.state()["publication_id"])


if __name__ == "__main__":
    unittest.main()
