"""Tests for photosorter_bridge.pipeline_runner."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from photosorter_bridge.pipeline_runner import (
    STEPS,
    StepInfo,
    build_args_namespace,
    build_pipeline_params,
    run_pipeline_with_progress,
)
from photosorter.cache_paths import manifest_path_for_input
from photosorter.clustering import ClusterResult
from photosorter.config import DEFAULTS
from photosorter.ordering import OrderedPhoto
from photosorter.pipeline import PipelineArgumentError, PipelineParams


class TestBuildPipelineParams:
    def test_defaults(self, tmp_path):
        params = build_pipeline_params(str(tmp_path), {})
        assert isinstance(params, PipelineParams)
        assert params.input_dir == Path(str(tmp_path))
        assert params.device == "auto"
        assert params.batch_size == DEFAULTS.batch_size
        assert params.pooling == DEFAULTS.pooling
        assert params.preprocess == DEFAULTS.preprocess
        assert params.distance_threshold == DEFAULTS.distance_threshold
        assert params.linkage == DEFAULTS.linkage
        assert params.temporal_weight == DEFAULTS.temporal_weight

    def test_display_label_mapping(self, tmp_path):
        params_dict = {
            "device": "Apple GPU",
            "batch_size": 32,
            "pooling": "CLS+AVG",
            "preprocess": "TIMM (strict)",
            "distance_threshold": 0.35,
            "linkage": "Complete",
            "temporal_weight": 0.2,
        }
        params = build_pipeline_params(str(tmp_path), params_dict)
        assert params.device == "mps"
        assert params.batch_size == 32
        assert params.pooling == "cls+avg"
        assert params.preprocess == "timm"
        assert params.distance_threshold == 0.35
        assert params.linkage == "complete"
        assert params.temporal_weight == 0.2

    def test_raw_values_pass_through(self, tmp_path):
        params_dict = {
            "device": "cpu",
            "pooling": "avg",
            "preprocess": "letterbox",
            "linkage": "single",
        }
        params = build_pipeline_params(str(tmp_path), params_dict)
        assert params.device == "cpu"
        assert params.pooling == "avg"
        assert params.preprocess == "letterbox"
        assert params.linkage == "single"

    def test_backward_compat_alias(self, tmp_path):
        """build_args_namespace is an alias for build_pipeline_params."""
        params = build_args_namespace(str(tmp_path), {"device": "cpu"})
        assert isinstance(params, PipelineParams)
        assert params.device == "cpu"

    def test_invalid_pooling_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--pooling must be one of"):
            build_pipeline_params(str(tmp_path), {"pooling": "invalid"})

    def test_invalid_linkage_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--linkage must be one of"):
            build_pipeline_params(str(tmp_path), {"linkage": "ward"})

    def test_invalid_preprocess_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--preprocess must be one of"):
            build_pipeline_params(str(tmp_path), {"preprocess": "crop"})

    def test_invalid_device_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--device must be one of"):
            build_pipeline_params(str(tmp_path), {"device": "tpu"})

    def test_invalid_threshold_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be > 0"):
            build_pipeline_params(str(tmp_path), {"distance_threshold": 0.0})

    def test_threshold_upper_bound_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be <= 2.0"):
            build_pipeline_params(str(tmp_path), {"distance_threshold": 3.0})


class TestStepInfo:
    def test_frozen(self):
        info = StepInfo(step="discover", detail="test")
        with pytest.raises(AttributeError):
            info.step = "other"

    def test_defaults(self):
        info = StepInfo(step="embed", detail="working")
        assert info.processed == 0
        assert info.total == 0


class TestRunPipelineWithProgress:
    def _params(self, input_dir: Path, **overrides) -> PipelineParams:
        values = {
            "input_dir": input_dir,
            "device": "cpu",
            "batch_size": 4,
            "pooling": "cls",
            "preprocess": DEFAULTS.preprocess,
            "distance_threshold": DEFAULTS.distance_threshold,
            "temporal_weight": 0.0,
            "linkage": DEFAULTS.linkage,
        }
        values.update(overrides)
        return PipelineParams(**values)

    def test_missing_input_dir_raises(self, tmp_path):
        params = self._params(tmp_path / "nonexistent")
        with pytest.raises(FileNotFoundError, match="does not exist"):
            run_pipeline_with_progress(params, lambda info: None)

    def test_no_images_raises(self, tmp_path, monkeypatch):
        import photosorter_bridge.pipeline_runner as runner_mod

        monkeypatch.setattr(runner_mod, "discover_images", lambda _d: [])

        params = self._params(tmp_path)
        with pytest.raises(FileNotFoundError, match="No images found"):
            run_pipeline_with_progress(params, lambda info: None)

    def test_invalid_distance_threshold_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--distance-threshold must be > 0"):
            self._params(tmp_path, distance_threshold=0.0)

    def test_invalid_temporal_weight_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--temporal-weight must be >= 0"):
            self._params(tmp_path, temporal_weight=-0.1)

    def test_invalid_batch_size_raises(self, tmp_path):
        with pytest.raises(PipelineArgumentError, match="--batch-size must be >= 1"):
            self._params(tmp_path, batch_size=0)

    def test_happy_path_reports_all_steps(self, tmp_path, monkeypatch):
        import photosorter_bridge.pipeline_runner as runner_mod

        fake_paths = [tmp_path / "a.jpg", tmp_path / "b.jpg"]
        monkeypatch.setattr(runner_mod, "discover_images", lambda _d: fake_paths)
        monkeypatch.setattr(runner_mod, "detect_device", lambda _d: "cpu")
        monkeypatch.setattr(runner_mod, "load_model", lambda _d: "fake-model")

        def fake_extract(paths, model, device, batch_size, pooling, on_batch=None):
            if on_batch:
                on_batch(2, 2)
            return np.array([[1.0, 0.0], [0.0, 1.0]]), [0, 1]

        monkeypatch.setattr(runner_mod, "extract_embeddings", fake_extract)
        monkeypatch.setattr(
            runner_mod,
            "compute_similarity_matrix",
            lambda e: np.array([[1.0, 0.2], [0.2, 1.0]]),
        )
        monkeypatch.setattr(
            runner_mod,
            "compute_distance_matrix",
            lambda s, tw: np.array([[0.0, 0.8], [0.8, 0.0]]),
        )
        monkeypatch.setattr(
            runner_mod,
            "cluster",
            lambda d, dt, l: ClusterResult(labels=np.array([0, 1]), n_clusters=2),
        )
        monkeypatch.setattr(
            runner_mod,
            "build_ordered_sequence",
            lambda p, l, *, original_indices=None: [
                OrderedPhoto(0, original_indices[0] if original_indices else 0, p[0], 0),
                OrderedPhoto(1, original_indices[1] if original_indices else 1, p[1], 1),
            ],
        )

        def fake_output_manifest(ordered, path, **kwargs):
            manifest = {
                "version": 1,
                "input_dir": str(tmp_path),
                "total": 2,
                "parameters": {},
                "clusters": [
                    {"cluster_id": 0, "count": 1, "photos": []},
                    {"cluster_id": 1, "count": 1, "photos": []},
                ],
            }
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(manifest))

        monkeypatch.setattr(runner_mod, "output_manifest", fake_output_manifest)

        progress_steps: list[str] = []
        params = self._params(tmp_path, batch_size=2)

        result = run_pipeline_with_progress(
            params, lambda info: progress_steps.append(info.step),
        )

        # All pipeline steps should be reported
        for step in STEPS:
            assert step in progress_steps, f"Missing progress for step: {step}"

        # Result is a PipelineOutcome
        assert result.total_ordered == 2
        assert result.n_clusters == 2
        assert result.manifest_path == manifest_path_for_input(tmp_path)

    def test_skipped_images_filters_paths(self, tmp_path, monkeypatch):
        """When extract_embeddings skips images, paths should be filtered."""
        import photosorter_bridge.pipeline_runner as runner_mod

        fake_paths = [tmp_path / "a.jpg", tmp_path / "bad.jpg", tmp_path / "c.jpg"]
        monkeypatch.setattr(runner_mod, "discover_images", lambda _d: fake_paths)
        monkeypatch.setattr(runner_mod, "detect_device", lambda _d: "cpu")
        monkeypatch.setattr(runner_mod, "load_model", lambda _d: "fake-model")

        def fake_extract(paths, model, device, batch_size, pooling, on_batch=None):
            if on_batch:
                on_batch(3, 3)
            # Skip middle image (index 1)
            return np.array([[1.0, 0.0], [0.0, 1.0]]), [0, 2]

        monkeypatch.setattr(runner_mod, "extract_embeddings", fake_extract)
        monkeypatch.setattr(
            runner_mod, "compute_similarity_matrix",
            lambda e: np.array([[1.0, 0.2], [0.2, 1.0]]),
        )
        monkeypatch.setattr(
            runner_mod, "compute_distance_matrix",
            lambda s, tw: np.array([[0.0, 0.8], [0.8, 0.0]]),
        )

        build_seq_args = {}

        def fake_cluster(d, dt, l):
            return ClusterResult(labels=np.array([0, 1]), n_clusters=2)

        def fake_build_ordered_sequence(paths, labels, *, original_indices=None):
            build_seq_args["paths"] = list(paths)
            build_seq_args["original_indices"] = list(original_indices or [])
            return [
                OrderedPhoto(0, original_indices[0] if original_indices else 0, paths[0], 0),
                OrderedPhoto(1, original_indices[1] if original_indices else 1, paths[1], 1),
            ]

        monkeypatch.setattr(runner_mod, "cluster", fake_cluster)
        monkeypatch.setattr(runner_mod, "build_ordered_sequence", fake_build_ordered_sequence)

        def fake_output_manifest(ordered, path, **kwargs):
            manifest = {
                "version": 1, "input_dir": str(tmp_path), "total": 2,
                "parameters": {}, "clusters": [],
            }
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(manifest))

        monkeypatch.setattr(runner_mod, "output_manifest", fake_output_manifest)

        params = self._params(tmp_path)
        run_pipeline_with_progress(params, lambda info: None)

        # build_ordered_sequence should receive filtered paths (a.jpg, c.jpg)
        assert build_seq_args["paths"] == [fake_paths[0], fake_paths[2]]
        assert build_seq_args["original_indices"] == [0, 2]

    def test_preprocess_is_forwarded_when_extract_supports_it(self, tmp_path, monkeypatch):
        import photosorter_bridge.pipeline_runner as runner_mod

        fake_paths = [tmp_path / "a.jpg"]
        monkeypatch.setattr(runner_mod, "discover_images", lambda _d: fake_paths)
        monkeypatch.setattr(runner_mod, "detect_device", lambda _d: "cpu")
        monkeypatch.setattr(runner_mod, "load_model", lambda _d: "fake-model")

        seen: dict[str, object] = {}

        def fake_extract(paths, model, device, batch_size, pooling, preprocess=None, on_batch=None):
            seen["preprocess"] = preprocess
            if on_batch:
                on_batch(1, 1)
            return np.array([[1.0, 0.0]]), [0]

        monkeypatch.setattr(runner_mod, "extract_embeddings", fake_extract)
        monkeypatch.setattr(runner_mod, "compute_similarity_matrix", lambda e: np.array([[1.0]]))
        monkeypatch.setattr(runner_mod, "compute_distance_matrix", lambda s, tw: np.array([[0.0]]))
        monkeypatch.setattr(
            runner_mod,
            "cluster",
            lambda d, dt, l: ClusterResult(labels=np.array([0]), n_clusters=1),
        )
        monkeypatch.setattr(
            runner_mod,
            "build_ordered_sequence",
            lambda p, l, *, original_indices=None: [
                OrderedPhoto(0, original_indices[0] if original_indices else 0, p[0], 0),
            ],
        )
        monkeypatch.setattr(
            runner_mod,
            "output_manifest",
            lambda ordered, path, **kwargs: path.parent.mkdir(parents=True, exist_ok=True) or path.write_text("{}"),
        )

        params = self._params(tmp_path, preprocess="timm")
        run_pipeline_with_progress(params, lambda info: None)

        assert seen["preprocess"] == "timm"

    def test_extract_signature_introspection_failure_uses_basic_call(self, tmp_path, monkeypatch):
        import photosorter.pipeline as pipeline_mod
        import photosorter_bridge.pipeline_runner as runner_mod

        fake_paths = [tmp_path / "a.jpg"]
        monkeypatch.setattr(runner_mod, "discover_images", lambda _d: fake_paths)
        monkeypatch.setattr(runner_mod, "detect_device", lambda _d: "cpu")
        monkeypatch.setattr(runner_mod, "load_model", lambda _d: "fake-model")
        monkeypatch.setattr(pipeline_mod.inspect, "signature", lambda _fn: (_ for _ in ()).throw(TypeError("no signature")))

        seen_kwargs: dict[str, object] = {}

        def fake_extract(paths, model, device, batch_size, pooling, **kwargs):
            seen_kwargs.update(kwargs)
            return np.array([[1.0, 0.0]]), [0]

        monkeypatch.setattr(runner_mod, "extract_embeddings", fake_extract)
        monkeypatch.setattr(runner_mod, "compute_similarity_matrix", lambda e: np.array([[1.0]]))
        monkeypatch.setattr(runner_mod, "compute_distance_matrix", lambda s, tw: np.array([[0.0]]))
        monkeypatch.setattr(
            runner_mod,
            "cluster",
            lambda d, dt, l: ClusterResult(labels=np.array([0]), n_clusters=1),
        )
        monkeypatch.setattr(
            runner_mod,
            "build_ordered_sequence",
            lambda p, l, *, original_indices=None: [
                OrderedPhoto(0, original_indices[0] if original_indices else 0, p[0], 0),
            ],
        )
        monkeypatch.setattr(
            runner_mod,
            "output_manifest",
            lambda ordered, path, **kwargs: path.parent.mkdir(parents=True, exist_ok=True) or path.write_text("{}"),
        )

        params = self._params(tmp_path)
        result = run_pipeline_with_progress(params, lambda info: None)

        assert result.manifest_path == manifest_path_for_input(tmp_path)
        assert seen_kwargs == {}
