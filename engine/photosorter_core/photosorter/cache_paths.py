"""Helpers for PhotoSorter cache and manifest paths."""

from __future__ import annotations

from pathlib import Path

from photosorter.config import DEFAULTS


def cache_dir_for_input(input_dir: Path) -> Path:
    """Return the cache root directory for a selected input folder."""
    return input_dir / DEFAULTS.cache_dirname


def manifest_path_for_input(input_dir: Path) -> Path:
    """Return the manifest path under the cache root."""
    return cache_dir_for_input(input_dir) / DEFAULTS.manifest_filename
