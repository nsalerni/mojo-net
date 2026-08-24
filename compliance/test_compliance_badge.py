#!/usr/bin/env python3
"""Regression checks for the generated compliance badge."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_compliance

from run_compliance import (
    EXPECTED_NET_CHECKS,
    compliance_badge_json,
    compliance_badge_payload,
    write_html_report,
    write_report,
)


def complete_results() -> dict[str, list[tuple[str, bool, str]]]:
    return {
        "net": [(name, True, "") for name in EXPECTED_NET_CHECKS],
    }


class ComplianceBadgeTest(unittest.TestCase):
    def test_complete_run_reports_exact_score(self):
        results = complete_results()

        payload = compliance_badge_payload(results)

        self.assertEqual(payload, {
            "schemaVersion": 1,
            "label": "CPython socket checks",
            "message": "15/15",
            "color": "brightgreen",
        })
        self.assertEqual(json.loads(compliance_badge_json(results)), payload)

    def test_failed_check_cannot_produce_a_green_badge(self):
        results = complete_results()
        name, _, _ = results["net"][0]
        results["net"][0] = (name, False, "reference mismatch")

        payload = compliance_badge_payload(results)

        self.assertEqual(payload["message"], "14/15")
        self.assertEqual(payload["color"], "red")

    def test_missing_check_cannot_produce_a_green_badge(self):
        results = complete_results()
        results["net"].pop()

        payload = compliance_badge_payload(results)

        self.assertEqual(payload["message"], "14/15")
        self.assertEqual(payload["color"], "red")

    def test_missing_check_cannot_produce_a_green_report(self):
        results = complete_results()
        results["net"].pop()

        with tempfile.TemporaryDirectory(dir=run_compliance.ROOT) as directory:
            markdown = Path(directory) / "COMPLIANCE.md"
            html = Path(directory) / "COMPLIANCE.html"
            with (
                patch.object(run_compliance, "RESULTS", results),
                patch.object(run_compliance, "REPORT", markdown),
                patch.object(run_compliance, "HTML_REPORT", html),
                patch.object(run_compliance, "versions", return_value={}),
            ):
                self.assertFalse(write_report())
                self.assertFalse(write_html_report())

            self.assertIn(
                "14/15 registered checks passed; results incomplete",
                markdown.read_text(),
            )
            self.assertIn(
                "14/15</span><span>registered checks passed; results incomplete",
                html.read_text(),
            )

    def test_duplicate_or_unexpected_check_is_red(self):
        results = complete_results()
        results["net"].append(results["net"][0])
        self.assertEqual(compliance_badge_payload(results)["color"], "red")

        results = complete_results()
        results["net"].append(("unregistered check", True, ""))
        self.assertEqual(compliance_badge_payload(results)["color"], "red")


if __name__ == "__main__":
    unittest.main()
