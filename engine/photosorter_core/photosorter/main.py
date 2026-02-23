"""CLI entry point and pipeline orchestration."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from photosorter.config import DEFAULTS
from photosorter.embeddings import (
    detect_device,
    extract_embeddings,
    load_model,
)
from photosorter.clustering import cluster
from photosorter.ordering import build_ordered_sequence
from photosorter.output import output_manifest
from photosorter.pipeline import (
    PipelineArgumentError,
    PipelineParams,
    run_pipeline_shared,
)
from photosorter.similarity import compute_distance_matrix, compute_similarity_matrix
from photosorter.utils import discover_images, setup_logging


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="photosorter",
        description="Reorder travel photos by visual similarity.",
    )
    p.add_argument("input_dir", type=Path, help="Directory containing photos")

    # Model / device
    p.add_argument("--device", default=DEFAULTS.device, help="Device: auto|cpu|mps")
    p.add_argument("--batch-size", type=int, default=DEFAULTS.batch_size)
    p.add_argument(
        "--pooling", default=DEFAULTS.pooling,
        choices=("cls", "avg", "cls+avg"),
        help="Embedding pooling: avg (model default), cls, or cls+avg",
    )
    p.add_argument(
        "--preprocess",
        default=DEFAULTS.preprocess,
        choices=("letterbox", "timm"),
        help="Image preprocessing: letterbox (current) or timm (strict pretrained_cfg)",
    )

    # Clustering
    p.add_argument("--distance-threshold", type=float, default=DEFAULTS.distance_threshold)
    p.add_argument("--temporal-weight", type=float, default=DEFAULTS.temporal_weight)
    p.add_argument(
        "--linkage", default=DEFAULTS.linkage,
        choices=("average", "complete", "single"),
        help="Cluster linkage: average (balanced), complete (strict), single (loose)",
    )

    return p


def _build_params(args: argparse.Namespace) -> PipelineParams:
    """Convert parsed CLI arguments into a validated PipelineParams."""
    try:
        return PipelineParams(
            input_dir=args.input_dir,
            device=args.device,
            batch_size=int(args.batch_size),
            pooling=args.pooling,
            preprocess=args.preprocess,
            distance_threshold=float(args.distance_threshold),
            linkage=args.linkage,
            temporal_weight=float(args.temporal_weight),
        )
    except PipelineArgumentError as exc:
        raise SystemExit(f"Error: {exc}") from exc


def run_pipeline(args: argparse.Namespace) -> None:
    log = setup_logging()
    params = _build_params(args)

    try:
        outcome = run_pipeline_shared(
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
            log=log,
        )
    except (FileNotFoundError, PipelineArgumentError) as exc:
        log.error("%s", exc)
        sys.exit(1)

    log.info("Done! %d photos → %d clusters", outcome.total_ordered, outcome.n_clusters)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    run_pipeline(args)
