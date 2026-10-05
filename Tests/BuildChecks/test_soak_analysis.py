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
