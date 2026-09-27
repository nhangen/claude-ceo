import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("ceo-profile-context.py")


class ProfileContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.vault = pathlib.Path(self.tmp.name)
        (self.vault / "Profile").mkdir()
        self.legacy = self.vault / "Profile.md"
        self.canonical = self.vault / "Profile/goals.md"
        self.legacy.write_text(self.profile("Legacy employer"))

    def profile(self, body, date="2026-09-26"):
        return f"---\nactive_domains_as_of: {date}\nlast_updated: 2026-09-26\n---\n## Active Domains (priority)\n{body}\n## Private\nSECRET\n"

    def run_reader(self):
        result = subprocess.run(["python3", str(SCRIPT), str(self.vault), "2026-09-26"], capture_output=True, text=True)
        return result.returncode, result.stdout

    def test_canonical_authority_and_section_boundary(self):
        self.canonical.write_text(self.profile("Current research"))
        (self.vault / "Profile/_inbox").mkdir()
        (self.vault / "Profile/_inbox/test.md").write_text("UNPROMOTED")
        rc, out = self.run_reader()
        self.assertEqual(rc, 0)
        self.assertIn("Source: Profile/goals.md", out)
        self.assertIn("Current research", out)
        for forbidden in ["Legacy employer", "SECRET", "UNPROMOTED"]:
            self.assertNotIn(forbidden, out)

    def test_only_absent_canonical_allows_fresh_legacy(self):
        self.assertIn("Legacy employer", self.run_reader()[1])
        for body in ["", "## Something else\n"]:
            self.canonical.write_text(body)
            self.assertNotIn("Legacy employer", self.run_reader()[1])
        self.canonical.unlink()
        self.canonical.mkdir()
        rc, out = self.run_reader()
        self.assertEqual(rc, 2)
        self.assertIn("unavailable", out)
        self.assertNotIn("Legacy employer", out)

    def test_dates_and_inclusive_thirty_day_boundary(self):
        for date in ["", "invalid", "2026-02-30", "2026-09-27", "2026-08-26"]:
            with self.subTest(date=date):
                self.canonical.write_text(self.profile("WITHHOLD", date))
                rc, out = self.run_reader()
                self.assertEqual(rc, 0)
                self.assertIn("need review", out)
                self.assertNotIn("WITHHOLD", out)
                self.assertNotIn("Legacy employer", out)
        self.canonical.write_text(self.profile("Current research", "2026-08-27"))
        self.assertIn("Current research", self.run_reader()[1])

    def test_unclosed_frontmatter_cannot_supply_freshness(self):
        self.canonical.write_text("---\nactive_domains_as_of: 2026-09-26\n## Active Domains\nWITHHOLD")
        out = self.run_reader()[1]
        self.assertIn("need review", out)
        self.assertNotIn("WITHHOLD", out)

    def test_empty_and_oversized_sections_are_not_partial_truth(self):
        self.canonical.write_text(self.profile(""))
        self.assertIn("missing or empty", self.run_reader()[1])
        self.canonical.write_text(self.profile("TOO LONG" * 2000))
        out = self.run_reader()[1]
        self.assertIn("exceeds 10000 bytes", out)
        self.assertNotIn("TOO LONG", out)
        self.assertLess(len(out.encode()), 1000)


if __name__ == "__main__":
    unittest.main()
