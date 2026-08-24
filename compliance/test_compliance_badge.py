#!/usr/bin/env python3
"""Regression checks for the generated compliance badge."""

import json
import unittest

from run_compliance import (
    EXPECTED_NET_CHECKS,
    compliance_badge_json,
    compliance_badge_payload,
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
            "message": "11/11",
            "color": "brightgreen",
        })
        self.assertEqual(json.loads(compliance_badge_json(results)), payload)

    def test_failed_check_cannot_produce_a_green_badge(self):
        results = complete_results()
        name, _, _ = results["net"][0]
        results["net"][0] = (name, False, "reference mismatch")

        payload = compliance_badge_payload(results)

        self.assertEqual(payload["message"], "10/11")
        self.assertEqual(payload["color"], "red")

    def test_missing_check_cannot_produce_a_green_badge(self):
        results = complete_results()
        results["net"].pop()

        payload = compliance_badge_payload(results)

        self.assertEqual(payload["message"], "10/11")
        self.assertEqual(payload["color"], "red")

    def test_duplicate_or_unexpected_check_is_red(self):
        results = complete_results()
        results["net"].append(results["net"][0])
        self.assertEqual(compliance_badge_payload(results)["color"], "red")

        results = complete_results()
        results["net"].append(("unregistered check", True, ""))
        self.assertEqual(compliance_badge_payload(results)["color"], "red")


if __name__ == "__main__":
    unittest.main()
