"""Test package for whoop_private."""

from __future__ import annotations

import unittest
from pathlib import Path


def run_unit_checks() -> None:
    """Run unit tests without hitting the live WHOOP API."""
    start = str(Path(__file__).resolve().parent)
    suite = unittest.defaultTestLoader.discover(start, pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if not result.wasSuccessful():
        raise SystemExit("whoop_private unit checks failed")
