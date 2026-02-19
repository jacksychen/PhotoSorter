"""Tests for photosorter_bridge.pipeline_runner."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pytest

from photosorter_bridge.pipeline_runner import (
    STEPS,
    StepInfo,
    build_args_namespace,
    run_pipeline_with_progress,
)
from photosorter.clustering import ClusterResult
from photosorter.config import DEFAULTS
from photosorter.ordering import OrderedPhoto


class TestBuildArgsNamespace:
    def test_defaults(self, tmp_path):
        ns = build_args_namespace(str(tmp_path), {})
        assert ns.input_dir == Path(str(tmp_path))
        assert ns.device == "auto"
        assert ns.batch_size == DEFAULTS.batch_size
        assert ns.pooling == "cls"
        assert ns.distance_threshold == DEFAULTS.distance_threshold
        assert ns.linkage == "average"
        assert ns.temporal_weight == DEFAULTS.temporal_weight

    def test_display_label_mapping(self, tmp_path):
        params = {
            "device": "Apple GPU",
            "batch_size": 32,
            "pooling": "CLS+AVG",
            "distance_threshold": 0.35,
            "linkage": "Complete",
            "temporal_weight": 0.2,
        }
        ns = build_args_namespace(str(tmp_path), params)
        assert ns.device == "mps"
        assert ns.batch_size == 32
        assert ns.pooling == "cls+avg"
        assert ns.distance_threshold == 0.35
        assert ns.linkage == "complete"
        assert ns.temporal_weight == 0.2

    def test_raw_values_pass_through(self, tmp_path):
        params = {"device": "cpu", "pooling": "avg", "linkage": "single"}
        ns = build_args_namespace(str(tmp_path), params)
        assert ns.device == "cpu"
        assert ns.pooling == "avg"
        assert ns.linkage == "single"


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
    def test_missing_input_dir_raises(self, tmp_path):
        args = argparse.Namespace(input_dir=tmp_path / "nonexistent")
        with pytest.raises(FileNotFoundError, match="does not exist"):
            run_pipeline_with_progress(args, lambda info: None)

    def test_no_images_raises(self, tmp_path, monkeypatch):
        import photosorter_bridge.pipeline_runner as runner_mod

        monkeypatch.setattr(runner_mod, "discover_images", lambda _d: [])

        args = argparse.Namespace(input_dir=tmp_path)
        with pytest.raises(FileNotFoundError, match="No images found"):
            run_pipeline_with_progress(args, lambda info: None)

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
        args = argparse.Namespace(
            input_dir=tmp_path,
            device="cpu",
            batch_size=2,
            pooling="cls",
            distance_threshold=0.4,
            temporal_weight=0.0,
            linkage="average",
        )

        result = run_pipeline_with_progress(
            args, lambda info: progress_steps.append(info.step),
        )

        # All pipeline steps should be reported
        for step in STEPS:
            assert step in progress_steps, f"Missing progress for step: {step}"

        assert result["version"] == 1
        assert result["total"] == 2

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

        args = argparse.Namespace(
            input_dir=tmp_path, device="cpu", batch_size=4, pooling="cls",
            distance_threshold=0.4, temporal_weight=0.0, linkage="average",
        )
        run_pipeline_with_progress(args, lambda info: None)

        # build_ordered_sequence should receive filtered paths (a.jpg, c.jpg)
        assert build_seq_args["paths"] == [fake_paths[0], fake_paths[2]]
        assert build_seq_args["original_indices"] == [0, 2]
