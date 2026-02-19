"""Tests for photosorter.clustering — agglomerative clustering."""

import numpy as np
import pytest

from photosorter.clustering import ClusterResult, cluster


def _make_block_distance(groups: list[int], intra: float = 0.1, inter: float = 0.8) -> np.ndarray:
    """Build a synthetic distance matrix with known cluster structure.

    Args:
        groups: cluster assignment for each point, e.g. [0, 0, 1, 1, 2]
        intra: distance between points in the same group
        inter: distance between points in different groups
    """
    n = len(groups)
    dist = np.full((n, n), inter, dtype=np.float64)
    for i in range(n):
        for j in range(n):
            if groups[i] == groups[j]:
                dist[i, j] = intra
        dist[i, i] = 0.0
    return dist


class TestCluster:
    def test_recovers_two_clusters(self):
        # Two tight groups well-separated
        groups = [0, 0, 0, 1, 1, 1]
        dist = _make_block_distance(groups)
        result = cluster(dist, distance_threshold=0.5)

        assert isinstance(result, ClusterResult)
        assert result.n_clusters == 2
        # Photos 0,1,2 should be in one cluster and 3,4,5 in another
        assert result.labels[0] == result.labels[1] == result.labels[2]
        assert result.labels[3] == result.labels[4] == result.labels[5]
        assert result.labels[0] != result.labels[3]

    def test_recovers_three_clusters(self):
        groups = [0, 0, 1, 1, 2, 2]
        dist = _make_block_distance(groups)
        result = cluster(dist, distance_threshold=0.5)

        assert result.n_clusters == 3

    def test_all_same_become_one_cluster(self):
        # All points identical → distance = 0 everywhere
        n = 5
        dist = np.zeros((n, n))
        result = cluster(dist, distance_threshold=0.5)

        assert result.n_clusters == 1
        assert len(set(result.labels)) == 1

    def test_all_different_become_singletons(self):
        # Every pair is very far apart → each becomes its own cluster
        n = 4
        dist = np.full((n, n), 2.0)
        np.fill_diagonal(dist, 0.0)
        result = cluster(dist, distance_threshold=0.1)

        assert result.n_clusters == n

    def test_threshold_controls_granularity(self):
        groups = [0, 0, 1, 1]
        dist = _make_block_distance(groups, intra=0.1, inter=0.5)

        # Tight threshold → more clusters
        tight = cluster(dist, distance_threshold=0.2)
        # Loose threshold → fewer clusters
        loose = cluster(dist, distance_threshold=0.9)

        assert tight.n_clusters >= loose.n_clusters

    def test_single_photo(self):
        dist = np.array([[0.0]])
        result = cluster(dist, distance_threshold=0.5)

        assert result.n_clusters == 1
        assert result.labels[0] == 0

    def test_empty_input_returns_empty_result(self):
        dist = np.zeros((0, 0), dtype=np.float64)
        result = cluster(dist, distance_threshold=0.5)

        assert result.n_clusters == 0
        assert result.labels.size == 0

    def test_labels_length_matches_input(self):
        groups = [0, 0, 1, 1, 2, 2, 2]
        dist = _make_block_distance(groups)
        result = cluster(dist, distance_threshold=0.5)

        assert len(result.labels) == len(groups)
