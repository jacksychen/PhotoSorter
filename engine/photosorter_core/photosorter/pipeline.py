"""Shared pipeline orchestration used by CLI and bridge layers."""

from __future__ import annotations

import inspect
import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from photosorter.config import DEFAULTS
from photosorter.cache_paths import manifest_path_for_input
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

# Valid values for categorical parameters
VALID_POOLING_OPTIONS = frozenset({"cls", "avg", "cls+avg"})
VALID_PREPROCESS_OPTIONS = frozenset({"letterbox", "timm"})
VALID_LINKAGE_OPTIONS = frozenset({"average", "complete", "single"})
VALID_DEVICE_OPTIONS = frozenset({"auto", "cpu", "mps", "cuda"})


class PipelineArgumentError(ValueError):
    """Raised when runtime pipeline parameters are invalid."""


@dataclass(frozen=True)
class PipelineParams:
    """Typed, validated pipeline parameters — replaces raw argparse.Namespace.

    All callers (CLI, bridge, tests) should construct this instead of
    passing an ``argparse.Namespace``.
    """

    input_dir: Path
    device: str = DEFAULTS.device
    batch_size: int = DEFAULTS.batch_size
    pooling: str = DEFAULTS.pooling
    preprocess: str = DEFAULTS.preprocess
    distance_threshold: float = DEFAULTS.distance_threshold
    linkage: str = DEFAULTS.linkage
    temporal_weight: float = DEFAULTS.temporal_weight

    def __post_init__(self) -> None:
        validate_pipeline_parameters(
            distance_threshold=self.distance_threshold,
            temporal_weight=self.temporal_weight,
            batch_size=self.batch_size,
            pooling=self.pooling,
            preprocess=self.preprocess,
            linkage=self.linkage,
            device=self.device,
        )


def validate_pipeline_parameters(
    *,
    distance_threshold: float,
    temporal_weight: float,
    batch_size: int,
    pooling: str | None = None,
    preprocess: str | None = None,
    linkage: str | None = None,
    device: str | None = None,
) -> None:
    """Validate user-facing pipeline parameters.

    This validation is shared by both CLI and JSON-bridge execution paths.
    """
    if distance_threshold <= 0:
        raise PipelineArgumentError("--distance-threshold must be > 0")
    if distance_threshold > 2.0:
        raise PipelineArgumentError(
            "--distance-threshold must be <= 2.0 (cosine distance range)"
        )
    if temporal_weight < 0:
        raise PipelineArgumentError("--temporal-weight must be >= 0")
    if batch_size < 1:
        raise PipelineArgumentError("--batch-size must be >= 1")
    if pooling is not None and pooling not in VALID_POOLING_OPTIONS:
        raise PipelineArgumentError(
            f"--pooling must be one of {sorted(VALID_POOLING_OPTIONS)}, got '{pooling}'"
        )
    if preprocess is not None and preprocess not in VALID_PREPROCESS_OPTIONS:
        raise PipelineArgumentError(
            "--preprocess must be one of "
            f"{sorted(VALID_PREPROCESS_OPTIONS)}, got '{preprocess}'"
        )
    if linkage is not None and linkage not in VALID_LINKAGE_OPTIONS:
        raise PipelineArgumentError(
            f"--linkage must be one of {sorted(VALID_LINKAGE_OPTIONS)}, got '{linkage}'"
        )
    if device is not None and device not in VALID_DEVICE_OPTIONS:
        raise PipelineArgumentError(
            f"--device must be one of {sorted(VALID_DEVICE_OPTIONS)}, got '{device}'"
        )


@dataclass(frozen=True)
class PipelineOutcome:
    manifest_path: Path
    total_ordered: int
    n_clusters: int


def run_pipeline_shared(
    *,
    params: PipelineParams,
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

    device = params.device
    batch_size = params.batch_size
    pooling = params.pooling
    preprocess = params.preprocess
    distance_threshold = params.distance_threshold
    linkage = params.linkage
    temporal_weight = params.temporal_weight

    input_dir = params.input_dir.resolve()
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
    resolved_device = detect_device_fn(device)
    model = load_model_fn(resolved_device)
    emit("model", "Model loaded")

    # Step 3 — extract embeddings
    total_images = len(paths)
    emit("embed", "Extracting embeddings…", 0, total_images)

    def _on_batch(processed: int, total: int) -> None:
        emit("embed", f"{processed}/{total}", processed, total)

    has_on_batch = False
    has_preprocess = False
    try:
        extract_params = inspect.signature(extract_embeddings_fn).parameters
        has_on_batch = "on_batch" in extract_params
        has_preprocess = "preprocess" in extract_params
    except (TypeError, ValueError):
        # Some callables (e.g. C-extensions or heavily wrapped functions) may not
        # expose a signature. In that case, use the basic call path.
        has_on_batch = False
        has_preprocess = False

    extract_kwargs: dict[str, Any] = {}
    if has_on_batch:
        extract_kwargs["on_batch"] = _on_batch
    if has_preprocess:
        extract_kwargs["preprocess"] = preprocess

    embeddings, valid_indices = extract_embeddings_fn(
        paths,
        model,
        resolved_device,
        batch_size,
        pooling,
        **extract_kwargs,
    )
    if len(valid_indices) < len(paths):
        skipped = len(paths) - len(valid_indices)
        logger.warning("Skipped %d unreadable images", skipped)
        paths = [paths[i] for i in valid_indices]

    emit("embed", "Embeddings extracted", total_images, total_images)

    # Step 4 — similarity & distance
    emit("similarity", "Computing similarity matrix…")
    sim = compute_similarity_matrix_fn(embeddings)
    dist = compute_distance_matrix_fn(sim, temporal_weight)
    emit("similarity", "Distance matrix ready")

    # Step 5 — clustering
    emit("cluster", "Clustering…")
    result = cluster_fn(dist, distance_threshold, linkage)
    emit("cluster", f"{result.n_clusters} clusters found")

    # Step 6 — write manifest
    emit("output", "Writing manifest…")
    ordered = build_ordered_sequence_fn(
        paths,
        result.labels,
        original_indices=valid_indices,
    )
    manifest_path = manifest_path_for_input(input_dir)
    output_manifest_fn(
        ordered,
        manifest_path,
        input_dir=input_dir,
        distance_threshold=distance_threshold,
        temporal_weight=temporal_weight,
        linkage=linkage,
        pooling=pooling,
        preprocess=preprocess,
        batch_size=batch_size,
        device=str(resolved_device),
    )
    emit("output", "Manifest written")

    return PipelineOutcome(
        manifest_path=manifest_path,
        total_ordered=len(ordered),
        n_clusters=result.n_clusters,
    )
