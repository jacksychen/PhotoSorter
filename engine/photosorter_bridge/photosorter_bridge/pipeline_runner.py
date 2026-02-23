"""Background pipeline execution with progress callbacks."""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from photosorter.clustering import cluster
from photosorter.config import DEFAULTS
from photosorter.embeddings import detect_device, extract_embeddings, load_model
from photosorter.ordering import build_ordered_sequence
from photosorter.output import output_manifest
from photosorter.pipeline import PipelineOutcome, PipelineParams, run_pipeline_shared
from photosorter.similarity import compute_distance_matrix, compute_similarity_matrix
from photosorter.utils import discover_images

logger = logging.getLogger("photosorter")


@dataclass(frozen=True)
class StepInfo:
    """Immutable snapshot of pipeline progress."""

    step: str
    detail: str
    processed: int = 0
    total: int = 0


# Pipeline step identifiers (in order)
STEPS = (
    "discover",
    "model",
    "embed",
    "similarity",
    "cluster",
    "output",
)


def build_pipeline_params(
    input_dir: str, parameters: dict[str, Any]
) -> PipelineParams:
    """Convert GUI parameters dict into a validated PipelineParams.

    Handles both display-label values (e.g. ``"Apple GPU"``) and raw
    Python values (e.g. ``"mps"``), so callers from either the Swift
    bridge layer or Python tests work transparently.
    """
    device_map = {"Auto": "auto", "Apple GPU": "mps", "CPU": "cpu"}
    pooling_map = {"CLS": "cls", "AVG": "avg", "CLS+AVG": "cls+avg"}
    preprocess_map = {
        "Letterbox": "letterbox",
        "TIMM": "timm",
        "TIMM (strict)": "timm",
    }
    linkage_map = {"Average": "average", "Complete": "complete", "Single": "single"}

    raw_device = parameters.get("device", "Auto")
    raw_pooling = parameters.get("pooling", "AVG")
    raw_preprocess = parameters.get("preprocess", DEFAULTS.preprocess)
    raw_linkage = parameters.get("linkage", DEFAULTS.linkage)

    return PipelineParams(
        input_dir=Path(input_dir),
        device=device_map.get(raw_device, raw_device),
        batch_size=int(parameters.get("batch_size", DEFAULTS.batch_size)),
        pooling=pooling_map.get(raw_pooling, raw_pooling),
        preprocess=preprocess_map.get(raw_preprocess, raw_preprocess),
        distance_threshold=float(
            parameters.get("distance_threshold", DEFAULTS.distance_threshold),
        ),
        linkage=linkage_map.get(raw_linkage, raw_linkage),
        temporal_weight=float(
            parameters.get("temporal_weight", DEFAULTS.temporal_weight),
        ),
    )


# Backward-compatible alias used by existing tests and cli_json
build_args_namespace = build_pipeline_params


def run_pipeline_with_progress(
    params: PipelineParams,
    on_progress: Callable[[StepInfo], None],
) -> PipelineOutcome:
    """Run the full pipeline, calling *on_progress* at each step.

    Returns the PipelineOutcome on success (contains manifest_path).
    Raises on failure (the caller is responsible for catching exceptions).
    """
    return run_pipeline_shared(
        params=params,
        discover_images_fn=discover_images,
        detect_device_fn=detect_device,
        load_model_fn=load_model,
        extract_embeddings_fn=extract_embeddings,
        compute_similarity_matrix_fn=compute_similarity_matrix,
        compute_distance_matrix_fn=compute_distance_matrix,
        cluster_fn=cluster,
        build_ordered_sequence_fn=build_ordered_sequence,
        output_manifest_fn=output_manifest,
        on_progress=lambda step, detail, processed, total: on_progress(
            StepInfo(step, detail, processed, total),
        ),
        log=logger,
    )
