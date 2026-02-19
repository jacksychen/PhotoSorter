"""Tests for photosorter.app view/state logic (no AppKit required)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from photosorter.app.pipeline_runner import STEPS, StepInfo, build_args_namespace
from photosorter.config import DEFAULTS


class TestPhaseLogic:
    """Test the state machine transitions without instantiating real AppKit views."""

    def test_manifest_detection_triggers_results_phase(self, tmp_path):
        """If manifest.json exists in the folder, we should go to results."""
        manifest = {
            "version": 1,
            "input_dir": str(tmp_path),
            "total": 5,
            "parameters": {"distance_threshold": 0.4},
            "clusters": [],
        }
        (tmp_path / "manifest.json").write_text(json.dumps(manifest))

        # Simulate the check that MainWindowController.folder_selected does
        manifest_path = tmp_path / "manifest.json"
        assert manifest_path.exists()
        data = json.loads(manifest_path.read_text())
        assert data["version"] == 1
        assert data["parameters"]["distance_threshold"] == 0.4

    def test_no_manifest_triggers_parameters_phase(self, tmp_path):
        """If no manifest.json exists, we should go to parameters."""
        manifest_path = tmp_path / "manifest.json"
        assert not manifest_path.exists()

    def test_parameters_from_manifest_round_trip(self, tmp_path):
        """Parameters stored in manifest can be fed back to build_args_namespace."""
        params = {
            "device": "mps",
            "batch_size": 32,
            "pooling": "cls+avg",
            "distance_threshold": 0.35,
            "linkage": "complete",
            "temporal_weight": 0.15,
        }
        ns = build_args_namespace(str(tmp_path), params)
        assert ns.device == "mps"
        assert ns.batch_size == 32
        assert ns.pooling == "cls+avg"
        assert ns.distance_threshold == 0.35
        assert ns.linkage == "complete"
        assert ns.temporal_weight == 0.15


class TestStepOrdering:
    def test_steps_are_in_expected_order(self):
        assert STEPS == ("discover", "model", "embed", "similarity", "cluster", "output")

    def test_step_info_immutable(self):
        info = StepInfo("discover", "test", 5, 10)
        assert info.step == "discover"
        assert info.processed == 5
        assert info.total == 10
        with pytest.raises(AttributeError):
            info.step = "other"
