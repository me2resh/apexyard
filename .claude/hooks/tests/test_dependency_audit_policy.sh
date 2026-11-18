#!/bin/bash
# Repository policy regression tests for GH-2084. No network required.
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import date

root = Path(sys.argv.pop())
script = root / '.github/scripts/dependency-audit-policy.py'
spec = importlib.util.spec_from_file_location('policy', script)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
ADVISORY = 'GHSA-fc5q-39xc-vjpf'


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.entry = {'id': ADVISORY, 'reason': 'Owner approved', 'expires': '2026-12-31'}
        self.finding = {'package': 'picomatch', 'advisory_id': ADVISORY,
                        'aliases': ['CVE-2026-12345'], 'severity': 'High'}
        self.report = {'findings': [self.finding], 'dependency_sets': [], 'unsupported_only': False}

    def evaluate(self, code=0, today=date(2026, 11, 18)):
        return policy.evaluate(self.report, [self.entry], code, today)

    def test_ignored_passes_before_and_on_expiry(self):
        self.assertEqual(self.evaluate()[0], 0)
        self.assertEqual(self.evaluate(today=date(2026, 12, 31))[0], 0)

    def test_other_high_and_critical_block(self):
        for severity in ('High', 'Critical'):
            with self.subTest(severity=severity):
                self.report['findings'] = [self.finding, dict(self.finding, advisory_id='GHSA-other', aliases=[], severity=severity)]
                status, messages = self.evaluate()
                self.assertEqual(status, 1)
                self.assertIn('GHSA-other', '\n'.join(messages))

    def test_invalid_entries_fail_and_are_named_even_without_findings(self):
        self.report['findings'] = []
        for expiry in ('2026-11-17', None, '2026-02-30', '20261231', ''):
            with self.subTest(expiry=expiry):
                self.entry.pop('expires', None)
                if expiry is not None:
                    self.entry['expires'] = expiry
                status, messages = self.evaluate()
                self.assertEqual(status, 1)
                self.assertIn(ADVISORY, '\n'.join(messages))

    def test_required_id_and_reason(self):
        for field in ('id', 'reason'):
            entry = dict(self.entry)
            del entry[field]
            self.assertEqual(policy.evaluate(self.report, [entry], 0, date(2026, 11, 18))[0], 1)

    def test_alias_matches_and_critical_helper_exit_is_recomputed(self):
        self.entry['id'] = 'CVE-2026-12345'
        self.finding['severity'] = 'Critical'
        self.assertEqual(self.evaluate(code=1)[0], 0)
        self.entry['id'] = ADVISORY
        self.finding['advisory_id'] = 'PYSEC-example'
        self.finding['aliases'] = [ADVISORY]
        self.assertEqual(self.evaluate(code=1)[0], 0)

    def test_audit_errors_and_unknown_remain_failures(self):
        for code in (2, 3, 4, 127):
            self.assertEqual(self.evaluate(code=code)[0], 1)
        self.report['dependency_sets'] = [{'coverage': 'incomplete', 'check_status': 'failed'}]
        self.assertEqual(self.evaluate(code=1)[0], 1)
        self.report['dependency_sets'] = []
        self.report['findings'].append(dict(self.finding, severity='Unknown'))
        self.assertEqual(self.evaluate(code=1)[0], 1)

    def test_cli_logs_and_appends_ignored_finding_to_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            report, ignores, summary = (directory / name for name in ('report.json', 'ignore.json', 'summary.md'))
            report.write_text(json.dumps(self.report))
            # Keep this CLI test independent of the actual execution date.
            self.entry['expires'] = '9999-12-31'
            ignores.write_text(json.dumps([self.entry]))
            summary.write_text('Existing summary\n')
            result = subprocess.run([sys.executable, str(script), str(report), str(ignores), '0'],
                                    env=dict(os.environ, GITHUB_STEP_SUMMARY=str(summary)),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for text in ('Ignored:', 'picomatch', ADVISORY, '9999-12-31'):
                self.assertIn(text, result.stdout)
                self.assertIn(text, summary.read_text())
            self.assertTrue(summary.read_text().startswith('Existing summary\n'))


unittest.main()
PY
