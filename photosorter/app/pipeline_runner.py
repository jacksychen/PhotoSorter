"""Background pipeline execution with progress callbacks."""

from __future__ import annotations

import argparse
import json
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


def build_args_namespace(input_dir: str, parameters: dict[str, Any]) -> argparse.Namespace:
    """Convert GUI parameters dict into an argparse.Namespace for the pipeline."""
    device_map = {"Auto": "auto", "Apple GPU": "mps", "CPU": "cpu"}
    pooling_map = {"CLS": "cls", "AVG": "avg", "CLS+AVG": "cls+avg"}
    linkage_map = {"Average": "average", "Complete": "complete", "Single": "single"}

    raw_device = parameters.get("device", "Auto")
    raw_pooling = parameters.get("pooling", "CLS")
    raw_linkage = parameters.get("linkage", "Average")

    return argparse.Namespace(
        input_dir=Path(input_dir),
        device=device_map.get(raw_device, raw_device),
        batch_size=int(parameters.get("batch_size", DEFAULTS.batch_size)),
        pooling=pooling_map.get(raw_pooling, raw_pooling),
        distance_threshold=float(
            parameters.get("distance_threshold", DEFAULTS.distance_threshold),
        ),
        linkage=linkage_map.get(raw_linkage, raw_linkage),
        temporal_weight=float(
            parameters.get("temporal_weight", DEFAULTS.temporal_weight),
        ),
    )


def run_pipeline_with_progress(
    args: argparse.Namespace,
    on_progress: Callable[[StepInfo], None],
) -> dict:
    """Run the full pipeline, calling *on_progress* at each step.

    Returns the parsed manifest dict on success.
    Raises on failure (the caller is responsible for catching exceptions).
    """
    input_dir = args.input_dir.resolve()
    if not input_dir.is_dir():
        raise FileNotFoundError(f"Input directory does not exist: {input_dir}")

    # Step 1 — discover images
    on_progress(StepInfo("discover", "Discovering images…"))
    paths = discover_images(input_dir)
    if not paths:
        raise FileNotFoundError(f"No images found in {input_dir}")
    on_progress(StepInfo("discover", f"Found {len(paths)} images", len(paths), len(paths)))

    # Step 2 — load model
    on_progress(StepInfo("model", "Loading DINOv3 model…"))
    device = detect_device(args.device)
    model = load_model(device)
    on_progress(StepInfo("model", "Model loaded"))

    # Step 3 — extract embeddings (with batch-level progress)
    total_images = len(paths)
    on_progress(StepInfo("embed", "Extracting embeddings…", 0, total_images))

    def _on_batch(processed: int, total: int) -> None:
        on_progress(StepInfo("embed", f"{processed}/{total}", processed, total))

    embeddings, valid_indices = extract_embeddings(
        paths, model, device, args.batch_size, args.pooling, on_batch=_on_batch,
    )
    if len(valid_indices) < len(paths):
        skipped = len(paths) - len(valid_indices)
        logger.warning("Skipped %d unreadable images", skipped)
        paths = [paths[i] for i in valid_indices]
    on_progress(StepInfo("embed", "Embeddings extracted", total_images, total_images))

    # Step 4 — similarity & distance
    on_progress(StepInfo("similarity", "Computing similarity matrix…"))
    sim = compute_similarity_matrix(embeddings)
    dist = compute_distance_matrix(sim, args.temporal_weight)
    on_progress(StepInfo("similarity", "Distance matrix ready"))

    # Step 5 — clustering
    on_progress(StepInfo("cluster", "Clustering…"))
    result = cluster(dist, args.distance_threshold, args.linkage)
    on_progress(StepInfo("cluster", f"{result.n_clusters} clusters found"))

    # Step 6 — write manifest
    on_progress(StepInfo("output", "Writing manifest…"))
    ordered = build_ordered_sequence(paths, result.labels)
    manifest_path = input_dir / DEFAULTS.manifest_filename
    output_manifest(
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
    on_progress(StepInfo("output", "Manifest written"))

    manifest_data = json.loads(manifest_path.read_text())
    return manifest_data
