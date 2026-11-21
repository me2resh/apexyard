"""Shared fixture and CLI helpers."""

import json
from pathlib import Path
import subprocess
import sys

LIB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LIB))
FIXTURES = LIB / 'tests' / 'fixtures'


def fixture(name='dfd'):
    return json.loads((FIXTURES / (name + '.diagram.json')).read_text())


def cli(*args, **kwargs):
    return subprocess.run([sys.executable, str(LIB / 'diagram.py')] + list(map(str, args)),
                          capture_output=True, **kwargs)
