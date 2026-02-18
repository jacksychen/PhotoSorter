"""Tests for photosorter.ordering — build_ordered_sequence logic."""

from pathlib import Path

import numpy as np
import pytest

from photosorter.ordering import OrderedPhoto, build_ordered_sequence


def _paths(n: int) -> list[Path]:
    """Create n fake image paths."""
    return [Path(f"/fake/IMG_{i:03d}.jpg") for i in range(n)]


class TestBuildOrderedSequence:
    def test_single_cluster(self):
        paths = _paths(3)
        labels = np.array([0, 0, 0])
        result = build_ordered_sequence(paths, labels)

        assert len(result) == 3
        assert all(p.cluster_id == 0 for p in result)
        # Positions should be sequential
        assert [p.position for p in result] == [0, 1, 2]
        # Original order preserved within cluster
        assert [p.original_index for p in result] == [0, 1, 2]

    def test_two_clusters_sorted_by_earliest_member(self):
        paths = _paths(4)
        # Photo 0,2 in cluster 1; photo 1,3 in cluster 0
        labels = np.array([1, 0, 1, 0])
        result = build_ordered_sequence(paths, labels)

        assert len(result) == 4
        # Cluster 1 has earliest member at index 0, cluster 0 at index 1
        # So cluster 1 should come first
        assert result[0].cluster_id == 1
        assert result[1].cluster_id == 1
        assert result[2].cluster_id == 0
        assert result[3].cluster_id == 0

    def test_interleaved_pattern_abc_ba(self):
        """Simulate A→B→C→B→A pattern: photos get grouped by cluster."""
        paths = _paths(5)
        # A=0, B=1, C=2, B=1, A=0
        labels = np.array([0, 1, 2, 1, 0])
        result = build_ordered_sequence(paths, labels)

        # Cluster 0 (A) earliest at index 0, cluster 1 (B) at index 1, cluster 2 (C) at index 2
        cluster_order = [p.cluster_id for p in result]
        assert cluster_order == [0, 0, 1, 1, 2]

    def test_preserves_original_order_within_cluster(self):
        paths = _paths(6)
        labels = np.array([0, 1, 0, 1, 0, 1])
        result = build_ordered_sequence(paths, labels)

        cluster_0 = [p for p in result if p.cluster_id == 0]
        cluster_1 = [p for p in result if p.cluster_id == 1]
        # Original indices should be sorted within each cluster
        assert [p.original_index for p in cluster_0] == [0, 2, 4]
        assert [p.original_index for p in cluster_1] == [1, 3, 5]

    def test_single_photo(self):
        paths = _paths(1)
        labels = np.array([0])
        result = build_ordered_sequence(paths, labels)

        assert len(result) == 1
        assert result[0].position == 0
        assert result[0].cluster_id == 0

    def test_all_different_clusters(self):
        """Each photo in its own cluster."""
        paths = _paths(5)
        labels = np.array([0, 1, 2, 3, 4])
        result = build_ordered_sequence(paths, labels)

        assert len(result) == 5
        # Each in its own cluster, order follows original sequence
        assert [p.original_index for p in result] == [0, 1, 2, 3, 4]
        assert [p.cluster_id for p in result] == [0, 1, 2, 3, 4]

    def test_positions_are_contiguous(self):
        paths = _paths(10)
        labels = np.array([2, 0, 1, 2, 0, 1, 2, 0, 1, 0])
        result = build_ordered_sequence(paths, labels)

        assert [p.position for p in result] == list(range(10))

    def test_paths_are_correct(self):
        paths = _paths(3)
        labels = np.array([1, 0, 1])
        result = build_ordered_sequence(paths, labels)

        # Cluster 1 first (earliest member at index 0)
        assert result[0].path == paths[0]
        assert result[1].path == paths[2]
        # Cluster 0 second
        assert result[2].path == paths[1]
