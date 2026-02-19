"""CLI entry point and pipeline orchestration."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from photosorter.clustering import cluster
from photosorter.config import DEFAULTS
from photosorter.embeddings import (
    detect_device,
    extract_embeddings,
    load_model,
)
from photosorter.ordering import build_ordered_sequence
from photosorter.output import output_manifest
from photosorter.similarity import compute_distance_matrix, compute_similarity_matrix
from photosorter.utils import discover_images, setup_logging

logger = logging.getLogger("photosorter")


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
        help="Embedding pooling: cls (semantic), avg (appearance), cls+avg (both)",
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


def _validate_args(args: argparse.Namespace) -> None:
    if args.distance_threshold <= 0:
        raise SystemExit("Error: --distance-threshold must be > 0")
    if args.temporal_weight < 0:
        raise SystemExit("Error: --temporal-weight must be >= 0")
    if args.batch_size < 1:
        raise SystemExit("Error: --batch-size must be >= 1")


def run_pipeline(args: argparse.Namespace) -> None:
    log = setup_logging()
    _validate_args(args)

    input_dir = args.input_dir.resolve()
    if not input_dir.is_dir():
        log.error("Input directory does not exist: %s", input_dir)
        sys.exit(1)

    # Step 1: discover images
    paths = discover_images(input_dir)
    if not paths:
        log.error("No images found in %s", input_dir)
        sys.exit(1)
    log.info("Found %d images in %s", len(paths), input_dir)

    # Step 2: extract embeddings
    device = detect_device(args.device)
    model = load_model(device)
    embeddings, valid_indices = extract_embeddings(
        paths, model, device, args.batch_size, args.pooling,
    )
    if len(valid_indices) < len(paths):
        skipped = len(paths) - len(valid_indices)
        log.warning("Skipped %d unreadable images", skipped)
        paths = [paths[i] for i in valid_indices]

    # Step 3: similarity & distance
    sim = compute_similarity_matrix(embeddings)
    dist = compute_distance_matrix(sim, args.temporal_weight)

    # Step 4: clustering
    result = cluster(dist, args.distance_threshold, args.linkage)

    # Step 5: ordering
    ordered = build_ordered_sequence(paths, result.labels)

    # Step 6: write manifest
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

    log.info("Done! %d photos → %d clusters", len(ordered), result.n_clusters)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    run_pipeline(args)
