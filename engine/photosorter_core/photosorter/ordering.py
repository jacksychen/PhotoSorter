"""Build the final ordered photo sequence from cluster labels."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class OrderedPhoto:
    position: int
    original_index: int
    path: Path
    cluster_id: int


def build_ordered_sequence(
    paths: list[Path],
    labels: np.ndarray,
    *,
    original_indices: list[int] | None = None,
) -> list[OrderedPhoto]:
    """Group by cluster, sort clusters by earliest member, keep original order within."""
    if original_indices is None:
        original_indices = list(range(len(paths)))
    if len(original_indices) != len(paths):
        raise ValueError("original_indices length must match paths length")

    clusters: dict[int, list[int]] = defaultdict(list)
    for idx, label in enumerate(labels):
        clusters[int(label)].append(idx)

    # Sort clusters by the earliest original index in each cluster
    sorted_cluster_ids = sorted(clusters.keys(), key=lambda cid: clusters[cid][0])

    ordered: list[OrderedPhoto] = []
    position = 0
    for cid in sorted_cluster_ids:
        for idx in clusters[cid]:
            ordered.append(OrderedPhoto(
                position=position,
                original_index=original_indices[idx],
                path=paths[idx],
                cluster_id=cid,
            ))
            position += 1

    return ordered
