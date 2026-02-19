"""Shared pipeline orchestration used by CLI and bridge layers."""

from __future__ import annotations

import argparse
import inspect
import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from photosorter.config import DEFAULTS
from photosorter.ordering import OrderedPhoto

ProgressCallback = Callable[[str, str, int, int], None]
DiscoverFn = Callable[[Path], list[Path]]
DeviceFn = Callable[[str], Any]
LoadModelFn = Callable[[Any], Any]
ExtractFn = Callable[..., tuple[np.ndarray, list[int]]]
SimilarityFn = Callable[[np.ndarray], np.ndarray]
DistanceFn = Callable[[np.ndarray, float], np.ndarray]
ClusterFn = Callable[[np.ndarray, float, str], Any]
BuildOrderFn = Callable[..., list[OrderedPhoto]]
OutputFn = Callable[..., None]


@dataclass(frozen=True)
class PipelineOutcome:
    manifest_path: Path
    total_ordered: int
    n_clusters: int


def run_pipeline_shared(
    *,
    args: argparse.Namespace,
    discover_images_fn: DiscoverFn,
    detect_device_fn: DeviceFn,
    load_model_fn: LoadModelFn,
    extract_embeddings_fn: ExtractFn,
    compute_similarity_matrix_fn: SimilarityFn,
    compute_distance_matrix_fn: DistanceFn,
    cluster_fn: ClusterFn,
    build_ordered_sequence_fn: BuildOrderFn,
    output_manifest_fn: OutputFn,
    on_progress: ProgressCallback | None = None,
    log: logging.Logger | None = None,
) -> PipelineOutcome:
    logger = log or logging.getLogger("photosorter")

    def emit(step: str, detail: str, processed: int = 0, total: int = 0) -> None:
        if on_progress is not None:
            on_progress(step, detail, processed, total)

    input_dir = args.input_dir.resolve()
    if not input_dir.is_dir():
        raise FileNotFoundError(f"Input directory does not exist: {input_dir}")

    # Step 1 — discover images
    emit("discover", "Discovering images…")
    paths = discover_images_fn(input_dir)
    if not paths:
        raise FileNotFoundError(f"No images found in {input_dir}")
    logger.info("Found %d images in %s", len(paths), input_dir)
    emit("discover", f"Found {len(paths)} images", len(paths), len(paths))

    # Step 2 — load model
    emit("model", "Loading DINOv3 model…")
    device = detect_device_fn(args.device)
    model = load_model_fn(device)
    emit("model", "Model loaded")

    # Step 3 — extract embeddings
    total_images = len(paths)
    emit("embed", "Extracting embeddings…", 0, total_images)

    def _on_batch(processed: int, total: int) -> None:
        emit("embed", f"{processed}/{total}", processed, total)

    has_on_batch = False
    try:
        has_on_batch = "on_batch" in inspect.signature(extract_embeddings_fn).parameters
    except (TypeError, ValueError):
        # Some callables (e.g. C-extensions or heavily wrapped functions) may not
        # expose a signature. In that case, use the basic call path.
        has_on_batch = False

    if has_on_batch:
        embeddings, valid_indices = extract_embeddings_fn(
            paths, model, device, args.batch_size, args.pooling, on_batch=_on_batch,
        )
    else:
        embeddings, valid_indices = extract_embeddings_fn(
            paths, model, device, args.batch_size, args.pooling,
        )
    if len(valid_indices) < len(paths):
        skipped = len(paths) - len(valid_indices)
        logger.warning("Skipped %d unreadable images", skipped)
        paths = [paths[i] for i in valid_indices]

    emit("embed", "Embeddings extracted", total_images, total_images)

    # Step 4 — similarity & distance
    emit("similarity", "Computing similarity matrix…")
    sim = compute_similarity_matrix_fn(embeddings)
    dist = compute_distance_matrix_fn(sim, args.temporal_weight)
    emit("similarity", "Distance matrix ready")

    # Step 5 — clustering
    emit("cluster", "Clustering…")
    result = cluster_fn(dist, args.distance_threshold, args.linkage)
    emit("cluster", f"{result.n_clusters} clusters found")

    # Step 6 — write manifest
    emit("output", "Writing manifest…")
    ordered = build_ordered_sequence_fn(
        paths,
        result.labels,
        original_indices=valid_indices,
    )
    manifest_path = input_dir / DEFAULTS.manifest_filename
    output_manifest_fn(
        ordered,
        manifest_path,
        input_dir=input_dir,
        distance_threshold=args.distance_threshold,
        temporal_weight=args.temporal_weight,
        linkage=args.linkage,
        pooling=args.pooling,
        batch_size=args.batch_size,
        device=str(device),
    )
    emit("output", "Manifest written")

    return PipelineOutcome(
        manifest_path=manifest_path,
        total_ordered=len(ordered),
        n_clusters=result.n_clusters,
    )
