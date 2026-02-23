"""Tests for CLI/package entrypoints."""

from __future__ import annotations

import argparse
import runpy
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from photosorter import main as main_mod


def test_main_function_parses_and_runs_pipeline(tmp_path, monkeypatch):
    parsed_args = argparse.Namespace(
        input_dir=Path(tmp_path),
        device="cpu",
        batch_size=2,
        pooling="cls",
        distance_threshold=0.2,
        temporal_weight=0.0,
        linkage="complete",
    )

    class _FakeParser:
        def parse_args(self):
            return parsed_args

    called = {}
    monkeypatch.setattr(main_mod, "build_parser", lambda: _FakeParser())
    monkeypatch.setattr(main_mod, "run_pipeline", lambda args: called.setdefault("args", args))

    main_mod.main()
    assert called["args"] is parsed_args


def test_package_main_module_invokes_main(monkeypatch):
    called = {"count": 0}
    monkeypatch.setattr(main_mod, "main", lambda: called.__setitem__("count", called["count"] + 1))

    runpy.run_module("photosorter.__main__", run_name="__main__")
    assert called["count"] == 1
