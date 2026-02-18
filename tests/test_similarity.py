"""Tests for photosorter.similarity — distance matrix computation."""

import numpy as np
import pytest

from photosorter.similarity import compute_distance_matrix, compute_similarity_matrix


class TestComputeSimilarityMatrix:
    def test_identity_on_normalized_vectors(self):
        # Two identical unit vectors → similarity = 1.0
        emb = np.array([[1.0, 0.0], [1.0, 0.0]])
        sim = compute_similarity_matrix(emb)
        np.testing.assert_allclose(sim, [[1.0, 1.0], [1.0, 1.0]])

    def test_orthogonal_vectors(self):
        emb = np.array([[1.0, 0.0], [0.0, 1.0]])
        sim = compute_similarity_matrix(emb)
        np.testing.assert_allclose(sim[0, 1], 0.0, atol=1e-10)

    def test_opposite_vectors(self):
        emb = np.array([[1.0, 0.0], [-1.0, 0.0]])
        sim = compute_similarity_matrix(emb)
        np.testing.assert_allclose(sim[0, 1], -1.0)

    def test_symmetric(self):
        rng = np.random.default_rng(42)
        emb = rng.standard_normal((10, 64))
        norms = np.linalg.norm(emb, axis=1, keepdims=True)
        emb = emb / norms
        sim = compute_similarity_matrix(emb)
        np.testing.assert_allclose(sim, sim.T, atol=1e-10)


class TestComputeDistanceMatrix:
    def test_identical_vectors_zero_distance(self):
        sim = np.array([[1.0, 1.0], [1.0, 1.0]])
        dist = compute_distance_matrix(sim)
        np.testing.assert_allclose(dist, [[0.0, 0.0], [0.0, 0.0]])

    def test_orthogonal_vectors_unit_distance(self):
        sim = np.array([[1.0, 0.0], [0.0, 1.0]])
        dist = compute_distance_matrix(sim)
        np.testing.assert_allclose(dist[0, 1], 1.0)

    def test_clipping(self):
        # Similarity slightly > 1 due to float rounding → distance should be 0, not negative
        sim = np.array([[1.0, 1.0001], [1.0001, 1.0]])
        dist = compute_distance_matrix(sim)
        assert np.all(dist >= 0.0)

    def test_temporal_weight_zero_has_no_effect(self):
        sim = np.eye(3)
        dist_base = compute_distance_matrix(sim)
        dist_zero = compute_distance_matrix(sim, temporal_weight=0.0)
        # Both should equal 1 - sim, clipped
        expected = np.clip(1.0 - sim, 0.0, 2.0)
        np.testing.assert_array_equal(dist_base, expected)
        np.testing.assert_array_equal(dist_zero, expected)

    def test_temporal_weight_increases_distance_for_far_apart_photos(self):
        n = 5
        sim = np.ones((n, n))  # All identical photos
        dist_no_temp = compute_distance_matrix(sim, temporal_weight=0.0)
        dist_with_temp = compute_distance_matrix(sim, temporal_weight=0.1)

        # Without temporal weight, all distances should be ~0
        assert np.allclose(dist_no_temp, 0.0, atol=1e-10)
        # With temporal weight, photos far apart in sequence should have > 0 distance
        assert dist_with_temp[0, -1] > 0.0
        # Diagonal should still be 0
        np.testing.assert_allclose(np.diag(dist_with_temp), 0.0)
