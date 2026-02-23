"""Tests for photosorter_bridge view/state logic (no AppKit required).

These tests verify the bridge-layer logic that translates between
the Swift GUI parameters and the Python pipeline core.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from photosorter.cache_paths import manifest_path_for_input
from photosorter_bridge.pipeline_runner import (
    STEPS,
    StepInfo,
    build_pipeline_params,
)
from photosorter.config import DEFAULTS
from photosorter.pipeline import PipelineArgumentError, PipelineParams


class TestBuildPipelineParamsFromGUI:
    """Test the GUI parameter dict → PipelineParams conversion.

    This is the primary bridge logic that FolderSelectView and
    ParameterView rely on when launching the pipeline subprocess.
    """

    def test_empty_parameters_use_defaults(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {})
        assert params.device == "auto"
        assert params.batch_size == DEFAULTS.batch_size
        assert params.pooling == DEFAULTS.pooling
        assert params.preprocess == DEFAULTS.preprocess
        assert params.distance_threshold == DEFAULTS.distance_threshold
        assert params.linkage == DEFAULTS.linkage
        assert params.temporal_weight == DEFAULTS.temporal_weight

    def test_gui_display_labels_map_to_python_values(self, tmp_path):
        """Swift sends display labels like 'Apple GPU'; bridge must map them."""
        gui_params = {
            "device": "Apple GPU",
            "pooling": "CLS+AVG",
            "preprocess": "TIMM",
            "linkage": "Complete",
            "batch_size": 16,
            "distance_threshold": 0.35,
            "temporal_weight": 0.1,
        }
        params = build_pipeline_params(str(tmp_path), gui_params)
        assert params.device == "mps"
        assert params.pooling == "cls+avg"
        assert params.preprocess == "timm"
        assert params.linkage == "complete"
        assert params.batch_size == 16
        assert params.distance_threshold == 0.35
        assert params.temporal_weight == 0.1

    def test_raw_python_values_pass_through(self, tmp_path):
        """Values already in Python format should be accepted unchanged."""
        params = build_pipeline_params(str(tmp_path), {
            "device": "cpu",
            "pooling": "avg",
            "preprocess": "letterbox",
            "linkage": "single",
        })
        assert params.device == "cpu"
        assert params.pooling == "avg"
        assert params.preprocess == "letterbox"
        assert params.linkage == "single"

    def test_auto_device_label_maps_to_auto(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"device": "Auto"})
        assert params.device == "auto"

    def test_cpu_display_label_maps_to_cpu(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"device": "CPU"})
        assert params.device == "cpu"

    def test_cls_display_label_maps_to_cls(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"pooling": "CLS"})
        assert params.pooling == "cls"

    def test_avg_display_label_maps_to_avg(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"pooling": "AVG"})
        assert params.pooling == "avg"

    def test_timm_preprocess_display_label_maps_to_timm(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"preprocess": "TIMM (strict)"})
        assert params.preprocess == "timm"

    def test_average_display_label_maps_to_average(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"linkage": "Average"})
        assert params.linkage == "average"

    def test_single_display_label_maps_to_single(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {"linkage": "Single"})
        assert params.linkage == "single"

    def test_parameters_from_manifest_round_trip(self, tmp_path):
        """Parameters stored in manifest can be fed back to build_pipeline_params."""
        params = {
            "device": "mps",
            "batch_size": 32,
            "pooling": "cls+avg",
            "preprocess": "timm",
            "distance_threshold": 0.35,
            "linkage": "complete",
            "temporal_weight": 0.15,
        }
        result = build_pipeline_params(str(tmp_path), params)
        assert result.device == "mps"
        assert result.batch_size == 32
        assert result.pooling == "cls+avg"
        assert result.preprocess == "timm"
        assert result.distance_threshold == 0.35
        assert result.linkage == "complete"
        assert result.temporal_weight == 0.15


class TestGUIParameterValidation:
    """Test that invalid GUI parameters are caught before pipeline runs."""

    def test_invalid_threshold_zero(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be > 0"):
            build_pipeline_params(str(tmp_path), {"distance_threshold": 0.0})

    def test_invalid_threshold_negative(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be > 0"):
            build_pipeline_params(str(tmp_path), {"distance_threshold": -0.5})

    def test_invalid_threshold_too_large(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be <= 2.0"):
            build_pipeline_params(str(tmp_path), {"distance_threshold": 2.5})

    def test_invalid_temporal_weight_negative(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--temporal-weight must be >= 0"):
            build_pipeline_params(str(tmp_path), {"temporal_weight": -0.1})

    def test_invalid_batch_size_zero(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--batch-size must be >= 1"):
            build_pipeline_params(str(tmp_path), {"batch_size": 0})

    def test_invalid_preprocess(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--preprocess must be one of"):
            build_pipeline_params(str(tmp_path), {"preprocess": "crop"})


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


class TestManifestDetection:
    """Test manifest detection logic used by FolderSelectView."""

    def test_manifest_exists_is_detectable(self, tmp_path):
        manifest = {
            "version": 1,
            "input_dir": str(tmp_path),
            "total": 5,
            "parameters": {"distance_threshold": 0.4},
            "clusters": [],
        }
        manifest_path = manifest_path_for_input(tmp_path)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest))
        assert manifest_path.exists()
        data = json.loads(manifest_path.read_text())
        assert data["version"] == 1
        assert data["parameters"]["distance_threshold"] == 0.4

    def test_no_manifest_is_detectable(self, tmp_path):
        manifest_path = manifest_path_for_input(tmp_path)
        assert not manifest_path.exists()

    def test_corrupt_manifest_raises_json_error(self, tmp_path):
        manifest_path = manifest_path_for_input(tmp_path)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text("{bad json")
        with pytest.raises(json.JSONDecodeError):
            json.loads(manifest_path.read_text())

    def test_manifest_missing_required_keys(self, tmp_path):
        """Manifest with missing keys should be handled gracefully."""
        manifest_path = manifest_path_for_input(tmp_path)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps({"version": 1}))
        data = json.loads(manifest_path.read_text())
        assert "clusters" not in data
        assert data.get("clusters") is None
