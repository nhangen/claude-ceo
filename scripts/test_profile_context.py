import os
import pathlib
import subprocess
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).with_name("ceo-profile-context.py")

# Exit codes the gather keys CEO_PROFILE_CONTEXT_VERSION off: only FRESH exports it.
FRESH, WITHHELD, READ_ERROR = 0, 1, 2


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

    def run_reader(self, *extra):
        result = subprocess.run(["python3", str(SCRIPT), *extra, str(self.vault), "2026-09-26"], capture_output=True, text=True)
        return result.returncode, result.stdout

    def test_canonical_authority_and_section_boundary(self):
        self.canonical.write_text(self.profile("Current research"))
        (self.vault / "Profile/_inbox").mkdir()
        (self.vault / "Profile/_inbox/test.md").write_text("UNPROMOTED")
        rc, out = self.run_reader()
        self.assertEqual(rc, FRESH)
        self.assertIn("Source: Profile/goals.md", out)
        self.assertIn("Current research", out)
        for forbidden in ["Legacy employer", "SECRET", "UNPROMOTED"]:
            self.assertNotIn(forbidden, out)

    def test_only_absent_canonical_allows_fresh_legacy(self):
        rc, out = self.run_reader()
        self.assertEqual(rc, FRESH)
        self.assertIn("Legacy employer", out)
        for body in ["", "## Something else\n"]:
            self.canonical.write_text(body)
            rc, out = self.run_reader()
            self.assertEqual(rc, WITHHELD)
            self.assertNotIn("Legacy employer", out)
        self.canonical.unlink()
        self.canonical.mkdir()
        rc, out = self.run_reader()
        self.assertEqual(rc, READ_ERROR)
        self.assertIn("unavailable", out)
        self.assertNotIn("Legacy employer", out)

    def test_no_profile_at_all_is_withheld(self):
        self.legacy.unlink()
        rc, out = self.run_reader()
        self.assertEqual(rc, WITHHELD)
        self.assertIn("unavailable", out)

    def test_dates_and_inclusive_thirty_day_boundary(self):
        for date in ["", "invalid", "2026-02-30", "2026-09-27", "2026-08-26"]:
            with self.subTest(date=date):
                self.canonical.write_text(self.profile("WITHHOLD", date))
                rc, out = self.run_reader()
                self.assertEqual(rc, WITHHELD)
                self.assertIn("need review", out)
                self.assertNotIn("WITHHOLD", out)
                self.assertNotIn("Legacy employer", out)
        self.canonical.write_text(self.profile("Current research", "2026-08-27"))
        rc, out = self.run_reader()
        self.assertEqual(rc, FRESH)
        self.assertIn("Current research", out)

    def test_duplicate_date_is_withheld(self):
        self.canonical.write_text("---\nactive_domains_as_of: 2026-09-26\nactive_domains_as_of: 2026-09-25\n---\n## Active Domains\nWITHHOLD\n")
        rc, out = self.run_reader()
        self.assertEqual(rc, WITHHELD)
        self.assertNotIn("WITHHOLD", out)

    def test_unclosed_frontmatter_cannot_supply_freshness(self):
        self.canonical.write_text("---\nactive_domains_as_of: 2026-09-26\n## Active Domains\nWITHHOLD")
        rc, out = self.run_reader()
        self.assertEqual(rc, WITHHELD)
        self.assertIn("need review", out)
        self.assertNotIn("WITHHOLD", out)

    def test_empty_and_oversized_sections_are_not_partial_truth(self):
        self.canonical.write_text(self.profile(""))
        rc, out = self.run_reader()
        self.assertEqual(rc, WITHHELD)
        self.assertIn("missing or empty", out)
        self.canonical.write_text(self.profile("TOO LONG" * 2000))
        rc, out = self.run_reader()
        self.assertEqual(rc, WITHHELD)
        self.assertIn("exceeds 10000 bytes", out)
        self.assertNotIn("TOO LONG", out)
        self.assertLess(len(out.encode()), 1000)


class DoctorModeTests(unittest.TestCase):
    """--doctor surfaces staleness to `ceo doctor`; it never prints domain content."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.vault = pathlib.Path(self.tmp.name)
        self.path = self.vault / "Profile.md"

    def write(self, date, mtime_date=None):
        head = f"active_domains_as_of: {date}\n" if date is not None else ""
        self.path.write_text(f"---\n{head}---\n## Active Domains\nPRIVATE DOMAIN\n")
        stamp = time.mktime(time.strptime(mtime_date or "2026-09-20", "%Y-%m-%d")) + 12 * 3600
        os.utime(self.path, (stamp, stamp))

    def doctor(self):
        result = subprocess.run(["python3", str(SCRIPT), "--doctor", str(self.vault), "2026-09-26"], capture_output=True, text=True)
        self.assertNotIn("PRIVATE DOMAIN", result.stdout + result.stderr)
        return result.returncode, result.stdout

    def test_fresh_and_unedited_is_ok(self):
        self.write("2026-09-20", "2026-09-21")
        rc, out = self.doctor()
        self.assertEqual(rc, 0, out)
        self.assertIn("2026-09-20", out)

    def test_missing_date_warns(self):
        self.write(None)
        rc, out = self.doctor()
        self.assertEqual(rc, 1)
        self.assertIn("active_domains_as_of", out)

    def test_older_than_thirty_days_warns(self):
        self.write("2026-08-26", "2026-08-26")
        rc, out = self.doctor()
        self.assertEqual(rc, 1)
        self.assertIn("31 days", out)

    def test_edited_more_than_a_day_after_as_of_warns(self):
        self.write("2026-09-20", "2026-09-22")
        rc, out = self.doctor()
        self.assertEqual(rc, 1)
        self.assertIn("edited", out)

    def test_no_profile_warns(self):
        rc, out = self.doctor()
        self.assertEqual(rc, 1)
        self.assertIn("no Profile", out)


if __name__ == "__main__":
    unittest.main()
