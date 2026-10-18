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
        output = self.render("---\nactive_domains_as_of: 2026-09-20\n---\n## Active Domains (priority)\nCurrent Research\n## Private\nignore\n")
        self.assertTrue(output.startswith("Canonical active domains ("))
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

    # The 30-day window is inclusive: a section confirmed exactly 30 days ago
    # is still current.
    def test_exactly_thirty_day_old_domains_are_reported(self):
        output = self.render("---\nactive_domains_as_of: 2026-08-29\n---\n## Active Domains\nAt Age Limit\n")
        self.assertTrue(output.startswith("Canonical active domains ("))
        self.assertIn("At Age Limit", output)

    def test_same_day_domains_are_reported(self):
        output = self.render("---\nactive_domains_as_of: 2026-09-28\n---\n## Active Domains\nConfirmed Today\n")
        self.assertTrue(output.startswith("Canonical active domains ("))
        self.assertIn("Confirmed Today", output)

    def test_future_dated_domains_are_withheld(self):
        output = self.render("---\nactive_domains_as_of: 2026-09-29\n---\n## Active Domains\nFuture Dated\n")
        self.assertIn("stale", output)
        self.assertNotIn("Future Dated", output)

    # A read error (the canonical file is a directory) is withheld with the
    # unreadable reason, not a crash and not a partial render.
    def test_unreadable_goals_are_unavailable_not_crashed(self):
        (self.vault / "Profile/goals.md").mkdir()
        result = subprocess.run(["python3", str(SCRIPT), str(self.vault), "2026-09-28"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("missing or unreadable", result.stdout)
        self.assertNotIn("Canonical active domains (", result.stdout)

    def test_invalid_today_argument_is_unavailable_not_crashed(self):
        (self.vault / "Profile/goals.md").write_text("---\nactive_domains_as_of: 2026-09-20\n---\n## Active Domains\nX\n")
        result = subprocess.run(["python3", str(SCRIPT), str(self.vault), "notadate"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("Active domains unavailable:"), result.stdout)
        self.assertNotIn("Canonical active domains (", result.stdout)

    def test_non_utf8_goals_are_unavailable_not_crashed(self):
        (self.vault / "Profile/goals.md").write_bytes(b"\xff\xfe---\n")
        result = subprocess.run(["python3", str(SCRIPT), str(self.vault), "2026-09-28"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("Active domains unavailable:"), result.stdout)
        self.assertNotIn("Canonical active domains (", result.stdout)

    # main() has its own catch layer for an unresolvable vault path
    # (resolve(strict=True)), which render()'s catches never reach.
    def test_nonexistent_vault_is_unavailable_not_crashed(self):
        missing = self.vault / "no-such-vault"
        result = subprocess.run(["python3", str(SCRIPT), str(missing), "2026-09-28"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("Active domains unavailable:"), result.stdout)
        self.assertNotIn("Canonical active domains (", result.stdout)


if __name__ == "__main__":
    unittest.main()
