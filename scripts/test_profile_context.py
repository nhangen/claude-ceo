from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("ceo-profile-context.py")


class ProfileContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name)
        (self.vault / "Profile").mkdir()

    def render(self, content):
        (self.vault / "Profile/goals.md").write_text(content)
        result = subprocess.run(["python3", str(SCRIPT), str(self.vault), "2026-09-28"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_current_dated_domains_are_reported(self):
        output = self.render("---\nactive_domains_as_of: 2026-09-20\n---\n## Active Domains\nCurrent Research\n## Private\nignore\n")
        self.assertIn("Current Research", output)
        self.assertNotIn("ignore", output)

    def test_stale_domains_are_withheld_without_history_fallback(self):
        output = self.render("---\nactive_domains_as_of: 2026-08-01\n---\n## Active Domains\nOld Employer\n")
        self.assertIn("stale", output)
        self.assertNotIn("Old Employer", output)

    def test_missing_date_is_unavailable(self):
        output = self.render("## Active Domains\nOld Employer\n")
        self.assertIn("unavailable", output)
        self.assertNotIn("Old Employer", output)


if __name__ == "__main__":
    unittest.main()
