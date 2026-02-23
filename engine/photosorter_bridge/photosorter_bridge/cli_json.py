"""JSON Lines CLI entry point for SwiftUI subprocess communication.

All structured output goes to stdout as JSON Lines (one JSON object per line).
All logging and diagnostic output goes to stderr.

Usage:
    python -m photosorter_bridge.cli_json run --input-dir /path [options]
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from photosorter_bridge.pipeline_runner import (
    StepInfo,
    build_pipeline_params,
    run_pipeline_with_progress,
)
from photosorter.config import DEFAULTS
from photosorter.pipeline import PipelineParams


def _setup_stderr_logging() -> None:
    """Force all logging output to stderr so stdout stays clean for JSON."""
    root = logging.getLogger()
    root.handlers.clear()
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)-8s %(message)s", datefmt="%H:%M:%S"),
    )
    root.addHandler(handler)
    root.setLevel(logging.INFO)


def _emit(obj: dict) -> None:
    """Write a single JSON object as one line to stdout and flush."""
    sys.stdout.write(json.dumps(obj, default=str) + "\n")
    sys.stdout.flush()


def _on_progress(info: StepInfo) -> None:
    """Convert a StepInfo dataclass into a JSON Lines progress message."""
    _emit({
        "type": "progress",
        "step": info.step,
        "detail": info.detail,
        "processed": info.processed,
        "total": info.total,
    })


def _build_run_parser(subparsers: argparse._SubParsersAction) -> None:
    run_p = subparsers.add_parser("run", help="Run the full pipeline")
    run_p.add_argument("--input-dir", type=Path, required=True, help="Directory containing photos")
    run_p.add_argument("--device", default=DEFAULTS.device, help="Device: auto|cpu|mps")
    run_p.add_argument("--batch-size", type=int, default=DEFAULTS.batch_size)
    run_p.add_argument(
        "--pooling",
        default=DEFAULTS.pooling,
        choices=("cls", "avg", "cls+avg"),
    )
    run_p.add_argument(
        "--preprocess",
        default=DEFAULTS.preprocess,
        choices=("letterbox", "timm"),
    )
    run_p.add_argument("--distance-threshold", type=float, default=DEFAULTS.distance_threshold)
    run_p.add_argument(
        "--linkage",
        default=DEFAULTS.linkage,
        choices=("average", "complete", "single"),
    )
    run_p.add_argument("--temporal-weight", type=float, default=DEFAULTS.temporal_weight)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="photosorter-json",
        description="PhotoSorter JSON Lines CLI for SwiftUI integration.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    _build_run_parser(subparsers)
    return parser


def _handle_run(args: argparse.Namespace) -> None:
    """Execute the full pipeline, emitting JSON Lines progress to stdout."""
    pipeline_params = build_pipeline_params(
        str(args.input_dir),
        {
            "device": args.device,
            "batch_size": args.batch_size,
            "pooling": args.pooling,
            "preprocess": args.preprocess,
            "distance_threshold": args.distance_threshold,
            "linkage": args.linkage,
            "temporal_weight": args.temporal_weight,
        },
    )

    try:
        outcome = run_pipeline_with_progress(pipeline_params, on_progress=_on_progress)
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})
        sys.exit(1)

    # Use manifest_path from outcome (DRY — no duplicate path calculation)
    _emit({"type": "complete", "manifest_path": str(outcome.manifest_path)})


def main() -> None:
    _setup_stderr_logging()

    parser = build_parser()
    args = parser.parse_args()
    _handle_run(args)


if __name__ == "__main__":  # pragma: no cover
    main()
