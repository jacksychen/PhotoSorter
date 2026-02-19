"""Utility helpers: logging, natural sort, image discovery."""

from __future__ import annotations

import logging
import re
from pathlib import Path

from photosorter.config import DEFAULTS


def setup_logging() -> logging.Logger:
    logging.basicConfig(
        format="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%H:%M:%S",
        level=logging.INFO,
    )
    return logging.getLogger("photosorter")


def natural_sort_key(path: Path) -> list:
    """Split filename on digit groups so 1-2 sorts before 1-10."""
    parts = re.split(r"(\d+)", path.stem)
    return [int(p) if p.isdigit() else p.lower() for p in parts]


def discover_images(input_dir: Path) -> list[Path]:
    """Find all supported images in *input_dir*, naturally sorted."""
    extensions = DEFAULTS.image_extensions + DEFAULTS.raw_extensions
    images = [
        p for p in input_dir.iterdir()
        if p.is_file() and p.suffix.lower() in extensions
    ]
    images.sort(key=natural_sort_key)
    return images
