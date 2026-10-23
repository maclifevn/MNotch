import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("soak", Path(__file__).resolve().parents[2] / "Scripts/soak-test.py")
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


class SoakAnalysisTests(unittest.TestCase):
    def rows(self, growing=False):
        return [{"elapsed_seconds": 600 + index * 30,
                 "rss_kib": 100000 + (index * 1000 if growing else 0),
                 "descriptor_count": 50 + (index if growing else 0),
                 "child_count": 0, "cpu_percent": 0.2} for index in range(100)]

    def test_short_smoke_cannot_satisfy_resource_acceptance(self):
        self.assertFalse(soak.assess_growth(self.rows()[:10])["evaluated"])

    def test_plateau_passes_resource_analysis(self):
        result = soak.assess_growth(self.rows())
        self.assertTrue(result["evaluated"])
        self.assertFalse(result["resource_review_required"])

    def test_continuing_growth_requires_review(self):
        self.assertTrue(soak.assess_growth(self.rows(growing=True))["resource_review_required"])

    def test_smoke_with_detected_growth_is_not_successful(self):
        growth = soak.assess_growth(self.rows(growing=True))
        self.assertEqual(soak.classify_run("completed", 750, growth), "resource_review_required")

    def test_short_smoke_never_becomes_eight_hour_acceptance(self):
        growth = soak.assess_growth(self.rows())
        self.assertEqual(soak.classify_run("completed", 750, growth), "smoke_completed")
        self.assertEqual(soak.classify_run("completed", 28800, growth), "idle_soak_completed")
        self.assertEqual(soak.classify_run("completed", 28800, {}), "resource_review_required")

    def test_failures_and_host_sleep_are_not_successful(self):
        growth = soak.assess_growth(self.rows())
        self.assertEqual(soak.classify_run("app_exited", 28800, growth), "failed")
        self.assertEqual(soak.classify_run("host_suspended_or_sampler_paused", 28800, growth), "inconclusive")

    def test_developer_id_clone_keeps_entitlements_and_hardened_runtime(self):
        command = soak.clone_signing_command('Developer ID Application: Fixture', Path('/tmp/QA.app'))
        self.assertIn('--preserve-metadata=entitlements', command)
        self.assertIn('--timestamp', command)
        self.assertEqual(command[-3:], ['--options', 'runtime', '/tmp/QA.app'])
        self.assertNotIn('runtime', soak.clone_signing_command('-', Path('/tmp/QA.app')))
