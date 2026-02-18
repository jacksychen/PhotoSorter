"""Output: write clustering manifest."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from photosorter.ordering import OrderedPhoto

logger = logging.getLogger("photosorter")


def output_manifest(
    ordered: list[OrderedPhoto],
    output_path: Path,
    *,
    input_dir: Path,
) -> None:
    # Group photos by cluster
    grouped: dict[int, list[OrderedPhoto]] = {}
    for photo in ordered:
        grouped.setdefault(photo.cluster_id, []).append(photo)

    manifest = {
        "version": 1,
        "input_dir": str(input_dir),
        "total": len(ordered),
        "clusters": [
            {
                "cluster_id": cid,
                "count": len(photos),
                "photos": [
                    {
                        "position": photo.position,
                        "original_index": photo.original_index,
                        "filename": photo.path.name,
                        "original_path": str(photo.path.resolve()),
                    }
                    for photo in photos
                ],
            }
            for cid, photos in sorted(grouped.items())
        ],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2) + "\n")
    logger.info("Manifest written → %s", output_path)
