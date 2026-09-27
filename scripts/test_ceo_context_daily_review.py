import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent
DAILY_REVIEW = ROOT / "ceo-context-daily-review.py"
CONTEXT = ROOT / "ceo-context.py"


class DailyContextReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name) / "vault"
        (self.vault / "Daily").mkdir(parents=True)
        (self.vault / "Daily/2026-09-26.md").write_text("# 2026-09-26\n\n- Research direction changed.\n")
        (self.vault / "Daily/2026-09-10.md").write_text("# 2026-09-10\n\n- Too old for this review window.\n")

    def review(self):
        result = subprocess.run(["python3", str(DAILY_REVIEW), "--vault", str(self.vault), "--context-script", str(CONTEXT), "--today", "2026-09-27", "--lookback", "14"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_recent_daily_notes_are_idempotent_private_candidates(self):
        first = self.review()
        second = self.review()
        self.assertEqual(first["reviewed_sources"], 1)
        self.assertTrue(first["new_candidates"])
        self.assertFalse(second["new_candidates"])
        inventory = subprocess.run(["python3", str(CONTEXT), "--vault", str(self.vault), "inventory"], capture_output=True, text=True)
        item = json.loads(inventory.stdout)[0]
        self.assertEqual(item["state"], "candidate")
        self.assertEqual(item["visibility"], "private")
        queue = (self.vault / "CEO/reports/context/daily-review-queue.md").read_text()
        self.assertIn("Daily/2026-09-26.md", queue)
        self.assertNotIn("Daily/2026-09-10.md", queue)

    def test_discretion_note_is_queued_without_copying_its_content(self):
        (self.vault / "Profile").mkdir()
        (self.vault / "Profile/discretion-denylist.txt").write_text("private deal\n")
        (self.vault / "Daily/2026-09-26.md").write_text("# 2026-09-26\n\n- private deal changed.\n")
        result = self.review()
        self.assertFalse(result["new_candidates"])
        self.assertNotIn("private deal", (self.vault / "CEO/reports/context/daily-review-queue.md").read_text())


if __name__ == "__main__":
    unittest.main()
