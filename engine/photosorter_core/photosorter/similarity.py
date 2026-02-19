"""Similarity and distance matrix computation."""

import numpy as np


def compute_similarity_matrix(embeddings: np.ndarray) -> np.ndarray:
    """Cosine similarity via dot product (embeddings are L2-normalised)."""
    return embeddings @ embeddings.T


def compute_distance_matrix(
    similarity: np.ndarray,
    temporal_weight: float = 0.0,
) -> np.ndarray:
    """Convert similarity to distance, optionally adding temporal penalty."""
    dist = np.clip(1.0 - similarity, 0.0, 2.0)

    if temporal_weight > 0.0:
        n = dist.shape[0]
        indices = np.arange(n)
        temporal = np.abs(indices[:, None] - indices[None, :]) / max(n - 1, 1)
        dist = dist + temporal_weight * temporal

    return dist
