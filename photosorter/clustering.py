"""Agglomerative clustering on precomputed distance matrices."""

import logging
from dataclasses import dataclass

import numpy as np
from sklearn.cluster import AgglomerativeClustering

from photosorter.config import DEFAULTS

logger = logging.getLogger("photosorter")


@dataclass(frozen=True)
class ClusterResult:
    labels: np.ndarray
    n_clusters: int


def cluster(
    dist: np.ndarray,
    distance_threshold: float = DEFAULTS.distance_threshold,
    linkage: str = DEFAULTS.linkage,
) -> ClusterResult:
    n = dist.shape[0]
    if n < 2:
        labels = np.zeros(n, dtype=int)
        logger.info("Single photo — assigned to cluster 0")
        return ClusterResult(labels=labels, n_clusters=max(n, 0))

    clusterer = AgglomerativeClustering(
        n_clusters=None,
        distance_threshold=distance_threshold,
        metric="precomputed",
        linkage=linkage,
    )
    labels = clusterer.fit_predict(dist)
    n_clusters = len(set(labels))
    logger.info("Agglomerative found %d clusters (threshold=%.3f, linkage=%s)", n_clusters, distance_threshold, linkage)
    return ClusterResult(labels=labels, n_clusters=n_clusters)
