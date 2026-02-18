"""Tests for photosorter.output — manifest generation."""

import json
from pathlib import Path

import pytest

from photosorter.ordering import OrderedPhoto
from photosorter.output import output_manifest


def _photo(
    cluster_id: int,
    position: int = 0,
    original_index: int = 0,
    name: str = "IMG_001.jpg",
) -> OrderedPhoto:
    return OrderedPhoto(
        position=position,
        original_index=original_index,
        path=Path(f"/fake/{name}"),
        cluster_id=cluster_id,
    )


class TestOutputManifest:
    def test_writes_valid_json(self, tmp_path):
        ordered = [_photo(0, position=0, original_index=0, name="a.jpg")]
        manifest_path = tmp_path / "manifest.json"
        output_manifest(ordered, manifest_path, input_dir=Path("/input"))
        data = json.loads(manifest_path.read_text())
        assert data["version"] == 1
        assert data["input_dir"] == "/input"
        assert data["total"] == 1

    def test_no_output_dir_field(self, tmp_path):
        ordered = [_photo(0)]
        manifest_path = tmp_path / "manifest.json"
        output_manifest(ordered, manifest_path, input_dir=Path("/input"))
        data = json.loads(manifest_path.read_text())
        assert "output_dir" not in data

    def test_no_output_filename_field(self, tmp_path):
        ordered = [_photo(0)]
        manifest_path = tmp_path / "manifest.json"
        output_manifest(ordered, manifest_path, input_dir=Path("/input"))
        data = json.loads(manifest_path.read_text())
        photos = data["clusters"][0]["photos"]
        assert "output_filename" not in photos[0]

    def test_clusters_grouped_correctly(self, tmp_path):
        ordered = [
            _photo(0, position=0, original_index=0, name="a.jpg"),
            _photo(0, position=1, original_index=1, name="b.jpg"),
            _photo(1, position=2, original_index=2, name="c.jpg"),
        ]
        manifest_path = tmp_path / "manifest.json"
        output_manifest(ordered, manifest_path, input_dir=Path("/input"))
        data = json.loads(manifest_path.read_text())
        assert data["total"] == 3
        assert len(data["clusters"]) == 2
        assert data["clusters"][0]["cluster_id"] == 0
        assert data["clusters"][0]["count"] == 2
        assert data["clusters"][1]["cluster_id"] == 1
        assert data["clusters"][1]["count"] == 1

    def test_empty_list(self, tmp_path):
        manifest_path = tmp_path / "manifest.json"
        output_manifest([], manifest_path, input_dir=Path("/input"))
        data = json.loads(manifest_path.read_text())
        assert data["total"] == 0
        assert data["clusters"] == []

    def test_photo_fields(self, tmp_path):
        ordered = [_photo(0, position=3, original_index=5, name="IMG_001.jpg")]
        manifest_path = tmp_path / "manifest.json"
        output_manifest(ordered, manifest_path, input_dir=Path("/input"))
        data = json.loads(manifest_path.read_text())
        photo = data["clusters"][0]["photos"][0]
        assert photo["position"] == 3
        assert photo["original_index"] == 5
        assert photo["filename"] == "IMG_001.jpg"
        assert "original_path" in photo

    def test_creates_parent_dirs(self, tmp_path):
        manifest_path = tmp_path / "sub" / "dir" / "manifest.json"
        output_manifest([], manifest_path, input_dir=Path("/input"))
        assert manifest_path.exists()
