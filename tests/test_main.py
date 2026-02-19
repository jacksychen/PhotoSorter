"""Tests for photosorter.main — argument checks and pipeline orchestration."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pytest

from photosorter import main as main_mod
from photosorter.clustering import ClusterResult
from photosorter.config import DEFAULTS
from photosorter.ordering import OrderedPhoto


class _FakeLogger:
    def __init__(self) -> None:
        self.records: list[tuple[str, str]] = []

    def info(self, message: str, *args) -> None:
        self.records.append(("info", message % args if args else message))

    def warning(self, message: str, *args) -> None:
        self.records.append(("warning", message % args if args else message))

    def error(self, message: str, *args) -> None:
        self.records.append(("error", message % args if args else message))


def _args(input_dir: Path, **overrides) -> argparse.Namespace:
    values = {
        "input_dir": input_dir,
        "device": "cpu",
        "batch_size": 4,
        "pooling": "cls",
        "distance_threshold": 0.4,
        "temporal_weight": 0.0,
        "linkage": "average",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def test_build_parser_defaults():
    parser = main_mod.build_parser()
    args = parser.parse_args(["/tmp/photos"])

    assert args.input_dir == Path("/tmp/photos")
    assert args.batch_size == DEFAULTS.batch_size
    assert args.pooling == DEFAULTS.pooling
    assert args.distance_threshold == DEFAULTS.distance_threshold
    assert args.temporal_weight == DEFAULTS.temporal_weight
    assert args.linkage == DEFAULTS.linkage


def test_validate_args_rejects_non_positive_threshold(tmp_path):
    args = _args(tmp_path, distance_threshold=0.0)
    with pytest.raises(SystemExit, match="--distance-threshold must be > 0"):
        main_mod._validate_args(args)


def test_validate_args_rejects_negative_temporal_weight(tmp_path):
    args = _args(tmp_path, temporal_weight=-0.1)
    with pytest.raises(SystemExit, match="--temporal-weight must be >= 0"):
        main_mod._validate_args(args)


def test_validate_args_rejects_invalid_batch_size(tmp_path):
    args = _args(tmp_path, batch_size=0)
    with pytest.raises(SystemExit, match="--batch-size must be >= 1"):
        main_mod._validate_args(args)


def test_run_pipeline_exits_when_input_dir_missing(tmp_path, monkeypatch):
    fake_log = _FakeLogger()
    monkeypatch.setattr(main_mod, "setup_logging", lambda: fake_log)

    args = _args(tmp_path / "missing")
    with pytest.raises(SystemExit) as exc:
        main_mod.run_pipeline(args)

    assert exc.value.code == 1
    assert ("error", f"Input directory does not exist: {(tmp_path / 'missing').resolve()}") in fake_log.records


def test_run_pipeline_exits_when_no_images(tmp_path, monkeypatch):
    fake_log = _FakeLogger()
    monkeypatch.setattr(main_mod, "setup_logging", lambda: fake_log)
    monkeypatch.setattr(main_mod, "discover_images", lambda _input_dir: [])

    args = _args(tmp_path)
    with pytest.raises(SystemExit) as exc:
        main_mod.run_pipeline(args)

    assert exc.value.code == 1
    assert any(level == "error" and "No images found in" in message for level, message in fake_log.records)


def test_run_pipeline_happy_path_with_skipped_images(tmp_path, monkeypatch):
    fake_log = _FakeLogger()
    monkeypatch.setattr(main_mod, "setup_logging", lambda: fake_log)

    discovered = [tmp_path / "a.jpg", tmp_path / "b.jpg", tmp_path / "c.jpg"]
    calls: dict[str, object] = {}

    def fake_discover_images(input_dir: Path):
        calls["discover_images"] = input_dir
        return discovered

    def fake_detect_device(requested: str):
        calls["detect_device"] = requested
        return "cpu"

    def fake_load_model(device):
        calls["load_model"] = device
        return "fake-model"

    def fake_extract_embeddings(paths, model, device, batch_size, pooling):
        calls["extract_embeddings"] = (list(paths), model, device, batch_size, pooling)
        emb = np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float64)
        return emb, [0, 2]  # Skip middle image

    def fake_compute_similarity_matrix(embeddings):
        calls["compute_similarity_matrix"] = embeddings.copy()
        return np.array([[1.0, 0.2], [0.2, 1.0]], dtype=np.float64)

    def fake_compute_distance_matrix(similarity, temporal_weight):
        calls["compute_distance_matrix"] = (similarity.copy(), temporal_weight)
        return np.array([[0.0, 0.8], [0.8, 0.0]], dtype=np.float64)

    def fake_cluster(distance, threshold, linkage):
        calls["cluster"] = (distance.copy(), threshold, linkage)
        return ClusterResult(labels=np.array([10, 20]), n_clusters=2)

    def fake_build_ordered_sequence(paths, labels):
        calls["build_ordered_sequence"] = (list(paths), labels.copy())
        return [
            OrderedPhoto(position=0, original_index=0, path=paths[0], cluster_id=10),
            OrderedPhoto(position=1, original_index=1, path=paths[1], cluster_id=20),
        ]

    def fake_output_manifest(ordered, output_path, **kwargs):
        calls["output_manifest"] = (list(ordered), output_path, kwargs)

    monkeypatch.setattr(main_mod, "discover_images", fake_discover_images)
    monkeypatch.setattr(main_mod, "detect_device", fake_detect_device)
    monkeypatch.setattr(main_mod, "load_model", fake_load_model)
    monkeypatch.setattr(main_mod, "extract_embeddings", fake_extract_embeddings)
    monkeypatch.setattr(main_mod, "compute_similarity_matrix", fake_compute_similarity_matrix)
    monkeypatch.setattr(main_mod, "compute_distance_matrix", fake_compute_distance_matrix)
    monkeypatch.setattr(main_mod, "cluster", fake_cluster)
    monkeypatch.setattr(main_mod, "build_ordered_sequence", fake_build_ordered_sequence)
    monkeypatch.setattr(main_mod, "output_manifest", fake_output_manifest)

    args = _args(
        tmp_path,
        device="auto",
        batch_size=8,
        pooling="cls+avg",
        distance_threshold=0.55,
        temporal_weight=0.25,
        linkage="complete",
    )
    main_mod.run_pipeline(args)

    filtered_paths, labels = calls["build_ordered_sequence"]
    assert filtered_paths == [discovered[0], discovered[2]]
    np.testing.assert_array_equal(labels, np.array([10, 20]))

    _, manifest_path, manifest_kwargs = calls["output_manifest"]
    assert manifest_path == tmp_path / DEFAULTS.manifest_filename
    assert manifest_kwargs["input_dir"] == tmp_path
    assert manifest_kwargs["distance_threshold"] == 0.55
    assert manifest_kwargs["temporal_weight"] == 0.25
    assert manifest_kwargs["linkage"] == "complete"
    assert manifest_kwargs["pooling"] == "cls+avg"
    assert manifest_kwargs["batch_size"] == 8
    assert manifest_kwargs["device"] == "cpu"
    assert any(level == "warning" and "Skipped 1 unreadable images" in message for level, message in fake_log.records)


def test_run_pipeline_happy_path_without_skipped_images(tmp_path, monkeypatch):
    fake_log = _FakeLogger()
    monkeypatch.setattr(main_mod, "setup_logging", lambda: fake_log)

    discovered = [tmp_path / "a.jpg", tmp_path / "b.jpg"]

    monkeypatch.setattr(main_mod, "discover_images", lambda _input_dir: discovered)
    monkeypatch.setattr(main_mod, "detect_device", lambda _requested: "cpu")
    monkeypatch.setattr(main_mod, "load_model", lambda _device: "fake-model")
    monkeypatch.setattr(
        main_mod,
        "extract_embeddings",
        lambda paths, model, device, batch_size, pooling: (
            np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float64),
            [0, 1],  # no skipped images
        ),
    )
    monkeypatch.setattr(main_mod, "compute_similarity_matrix", lambda _emb: np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float64))
    monkeypatch.setattr(main_mod, "compute_distance_matrix", lambda _sim, _w: np.array([[0.0, 1.0], [1.0, 0.0]], dtype=np.float64))
    monkeypatch.setattr(main_mod, "cluster", lambda _dist, _th, _link: ClusterResult(labels=np.array([0, 1]), n_clusters=2))
    monkeypatch.setattr(
        main_mod,
        "build_ordered_sequence",
        lambda paths, labels: [
            OrderedPhoto(position=0, original_index=0, path=paths[0], cluster_id=0),
            OrderedPhoto(position=1, original_index=1, path=paths[1], cluster_id=1),
        ],
    )

    output_calls = {}

    def fake_output_manifest(ordered, output_path, **kwargs):
        output_calls["ordered"] = list(ordered)
        output_calls["path"] = output_path
        output_calls["kwargs"] = kwargs

    monkeypatch.setattr(main_mod, "output_manifest", fake_output_manifest)

    args = _args(tmp_path)
    main_mod.run_pipeline(args)

    assert output_calls["path"] == tmp_path / DEFAULTS.manifest_filename
    assert len(output_calls["ordered"]) == 2
    assert not any(level == "warning" and "Skipped" in message for level, message in fake_log.records)
