"""Tests for photosorter.pipeline — PipelineParams validation and shared orchestration."""

from __future__ import annotations

from pathlib import Path

import pytest

from photosorter.pipeline import (
    VALID_DEVICE_OPTIONS,
    VALID_LINKAGE_OPTIONS,
    VALID_POOLING_OPTIONS,
    VALID_PREPROCESS_OPTIONS,
    PipelineArgumentError,
    PipelineOutcome,
    PipelineParams,
    validate_pipeline_parameters,
)
from photosorter.config import DEFAULTS


class TestPipelineParams:
    """Test the frozen dataclass that replaced argparse.Namespace."""

    def test_creates_with_defaults(self, tmp_path):
        params = PipelineParams(input_dir=tmp_path)
        assert params.input_dir == tmp_path
        assert params.device == DEFAULTS.device
        assert params.batch_size == DEFAULTS.batch_size
        assert params.pooling == DEFAULTS.pooling
        assert params.preprocess == DEFAULTS.preprocess
        assert params.distance_threshold == DEFAULTS.distance_threshold
        assert params.linkage == DEFAULTS.linkage
        assert params.temporal_weight == DEFAULTS.temporal_weight

    def test_creates_with_explicit_values(self, tmp_path):
        params = PipelineParams(
            input_dir=tmp_path,
            device="cpu",
            batch_size=16,
            pooling="cls+avg",
            preprocess="timm",
            distance_threshold=0.5,
            linkage="complete",
            temporal_weight=0.2,
        )
        assert params.device == "cpu"
        assert params.batch_size == 16
        assert params.pooling == "cls+avg"
        assert params.preprocess == "timm"
        assert params.distance_threshold == 0.5
        assert params.linkage == "complete"
        assert params.temporal_weight == 0.2

    def test_is_frozen(self, tmp_path):
        params = PipelineParams(input_dir=tmp_path)
        with pytest.raises(AttributeError):
            params.device = "mps"

    def test_rejects_zero_threshold(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be > 0"):
            PipelineParams(input_dir=tmp_path, distance_threshold=0.0)

    def test_rejects_negative_threshold(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be > 0"):
            PipelineParams(input_dir=tmp_path, distance_threshold=-0.1)

    def test_rejects_threshold_above_upper_bound(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be <= 2.0"):
            PipelineParams(input_dir=tmp_path, distance_threshold=2.5)

    def test_accepts_threshold_at_upper_bound(self, tmp_path):
        params = PipelineParams(input_dir=tmp_path, distance_threshold=2.0)
        assert params.distance_threshold == 2.0

    def test_rejects_negative_temporal_weight(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--temporal-weight must be >= 0"):
            PipelineParams(input_dir=tmp_path, temporal_weight=-0.01)

    def test_accepts_zero_temporal_weight(self, tmp_path):
        params = PipelineParams(input_dir=tmp_path, temporal_weight=0.0)
        assert params.temporal_weight == 0.0

    def test_rejects_zero_batch_size(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--batch-size must be >= 1"):
            PipelineParams(input_dir=tmp_path, batch_size=0)

    def test_rejects_negative_batch_size(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--batch-size must be >= 1"):
            PipelineParams(input_dir=tmp_path, batch_size=-1)

    def test_rejects_invalid_pooling(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--pooling must be one of"):
            PipelineParams(input_dir=tmp_path, pooling="max")

    def test_rejects_invalid_linkage(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--linkage must be one of"):
            PipelineParams(input_dir=tmp_path, linkage="ward")

    def test_rejects_invalid_preprocess(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--preprocess must be one of"):
            PipelineParams(input_dir=tmp_path, preprocess="crop")

    def test_rejects_invalid_device(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--device must be one of"):
            PipelineParams(input_dir=tmp_path, device="tpu")

    def test_accepts_all_valid_pooling_options(self, tmp_path):
        for pooling in VALID_POOLING_OPTIONS:
            params = PipelineParams(input_dir=tmp_path, pooling=pooling)
            assert params.pooling == pooling

    def test_accepts_all_valid_linkage_options(self, tmp_path):
        for linkage in VALID_LINKAGE_OPTIONS:
            params = PipelineParams(input_dir=tmp_path, linkage=linkage)
            assert params.linkage == linkage

    def test_accepts_all_valid_device_options(self, tmp_path):
        for device in VALID_DEVICE_OPTIONS:
            params = PipelineParams(input_dir=tmp_path, device=device)
            assert params.device == device


class TestValidatePipelineParameters:
    """Test the standalone validation function."""

    def test_valid_parameters_pass(self):
        # Should not raise
        validate_pipeline_parameters(
            distance_threshold=0.4,
            temporal_weight=0.1,
            batch_size=8,
            pooling="cls",
            preprocess="letterbox",
            linkage="average",
            device="cpu",
        )

    def test_none_pooling_skips_validation(self):
        # None should be accepted (means not provided)
        validate_pipeline_parameters(
            distance_threshold=0.4,
            temporal_weight=0.0,
            batch_size=1,
            pooling=None,
        )

    def test_none_linkage_skips_validation(self):
        validate_pipeline_parameters(
            distance_threshold=0.4,
            temporal_weight=0.0,
            batch_size=1,
            linkage=None,
        )

    def test_none_preprocess_skips_validation(self):
        validate_pipeline_parameters(
            distance_threshold=0.4,
            temporal_weight=0.0,
            batch_size=1,
            preprocess=None,
        )

    def test_none_device_skips_validation(self):
        validate_pipeline_parameters(
            distance_threshold=0.4,
            temporal_weight=0.0,
            batch_size=1,
            device=None,
        )


class TestPipelineOutcome:
    """Test the immutable result dataclass."""

    def test_creates_with_values(self, tmp_path):
        outcome = PipelineOutcome(
            manifest_path=tmp_path / "manifest.json",
            total_ordered=42,
            n_clusters=5,
        )
        assert outcome.manifest_path == tmp_path / "manifest.json"
        assert outcome.total_ordered == 42
        assert outcome.n_clusters == 5

    def test_is_frozen(self, tmp_path):
        outcome = PipelineOutcome(
            manifest_path=tmp_path / "manifest.json",
            total_ordered=10,
            n_clusters=2,
        )
        with pytest.raises(AttributeError):
            outcome.total_ordered = 20


class TestConstantSets:
    """Test that the valid option sets match expected values."""

    def test_pooling_options(self):
        assert VALID_POOLING_OPTIONS == {"cls", "avg", "cls+avg"}

    def test_preprocess_options(self):
        assert VALID_PREPROCESS_OPTIONS == {"letterbox", "timm"}

    def test_linkage_options(self):
        assert VALID_LINKAGE_OPTIONS == {"average", "complete", "single"}

    def test_device_options(self):
        assert VALID_DEVICE_OPTIONS == {"auto", "cpu", "mps", "cuda"}
