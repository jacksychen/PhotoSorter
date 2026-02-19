"""Tests for photosorter.embeddings utility logic."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import torch
from PIL import Image
from torchvision import transforms

from photosorter import embeddings as emb_mod
from photosorter.config import DEFAULTS, MODEL_TIMM_ID


class _DummyModel:
    def __init__(self):
        self.moved_to = None
        self.eval_called = False

    def to(self, device):
        self.moved_to = device
        return self

    def eval(self):
        self.eval_called = True
        return self


def test_detect_device_explicit():
    assert emb_mod.detect_device("cpu").type == "cpu"


def test_detect_device_auto_prefers_mps(monkeypatch):
    monkeypatch.setattr(emb_mod.torch.backends.mps, "is_available", lambda: True)
    assert emb_mod.detect_device("auto").type == "mps"


def test_detect_device_auto_falls_back_to_cpu(monkeypatch):
    monkeypatch.setattr(emb_mod.torch.backends.mps, "is_available", lambda: False)
    assert emb_mod.detect_device("auto").type == "cpu"


def test_load_model_calls_timm_and_moves_to_device(monkeypatch):
    captured = {}
    model = _DummyModel()

    def fake_create_model(model_id, pretrained):
        captured["model_id"] = model_id
        captured["pretrained"] = pretrained
        return model

    monkeypatch.setattr(emb_mod.timm, "create_model", fake_create_model)
    loaded = emb_mod.load_model(torch.device("cpu"))

    assert loaded is model
    assert captured == {"model_id": MODEL_TIMM_ID, "pretrained": True}
    assert model.moved_to == torch.device("cpu")
    assert model.eval_called is True


def test_build_transform_shape_and_normalization():
    tfm = emb_mod.build_transform()
    assert isinstance(tfm, transforms.Compose)
    assert [type(op).__name__ for op in tfm.transforms] == [
        "Resize",
        "CenterCrop",
        "ToTensor",
        "Normalize",
    ]
    norm = tfm.transforms[-1]
    assert tuple(norm.mean) == DEFAULTS.imagenet_mean
    assert tuple(norm.std) == DEFAULTS.imagenet_std


def test_read_raw_orientation_success(monkeypatch):
    class _FakeImage:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def getexif(self):
            return {0x0112: 6}

    monkeypatch.setattr(emb_mod.Image, "open", lambda _p: _FakeImage())
    assert emb_mod._read_raw_orientation(Path("/tmp/a.cr2")) == 6


def test_read_raw_orientation_failure_returns_none(monkeypatch):
    monkeypatch.setattr(emb_mod.Image, "open", lambda _p: (_ for _ in ()).throw(OSError("bad")))
    assert emb_mod._read_raw_orientation(Path("/tmp/bad.cr2")) is None


def test_load_raw_applies_orientation(monkeypatch):
    class _FakeRaw:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def postprocess(self, half_size, use_camera_wb):
            assert half_size is True
            assert use_camera_wb is True
            return np.zeros((2, 3, 3), dtype=np.uint8)

    monkeypatch.setattr(emb_mod.rawpy, "imread", lambda _p: _FakeRaw())
    monkeypatch.setattr(emb_mod, "_read_raw_orientation", lambda _p: 6)
    img = emb_mod._load_raw(Path("/tmp/a.cr2"))
    assert img.size == (2, 3)


def test_load_raw_without_orientation_keeps_original_size(monkeypatch):
    class _FakeRaw:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def postprocess(self, half_size, use_camera_wb):
            assert half_size is True
            assert use_camera_wb is True
            return np.zeros((2, 3, 3), dtype=np.uint8)

    monkeypatch.setattr(emb_mod.rawpy, "imread", lambda _p: _FakeRaw())
    monkeypatch.setattr(emb_mod, "_read_raw_orientation", lambda _p: None)

    img = emb_mod._load_raw(Path("/tmp/no_orientation.cr2"))
    assert img.size == (3, 2)


def test_prescale_downsizes_large_image():
    img = Image.new("RGB", (2048, 1024))
    out = emb_mod._prescale(img)
    assert max(out.size) <= DEFAULTS.prescale_size


def test_prescale_keeps_small_image():
    img = Image.new("RGB", (200, 120))
    out = emb_mod._prescale(img)
    assert out.size == (200, 120)


def test_load_and_preprocess_image_rgb_branch(tmp_path):
    path = tmp_path / "x.jpg"
    Image.new("RGB", (32, 24), color=(123, 45, 67)).save(path)

    def fake_transform(img):
        return (img.mode, img.size)

    mode, size = emb_mod.load_and_preprocess_image(path, fake_transform)
    assert mode == "RGB"
    assert isinstance(size, tuple)


def test_load_and_preprocess_image_raw_branch(monkeypatch, tmp_path):
    path = tmp_path / "x.CR2"
    path.write_bytes(b"raw")
    monkeypatch.setattr(emb_mod, "_load_raw", lambda _p: Image.new("RGB", (20, 10)))

    result = emb_mod.load_and_preprocess_image(path, lambda img: img.size)
    assert result == (20, 10)


def test_pool_features_variants():
    features = torch.tensor([[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]])
    cls = emb_mod._pool_features(features, "cls")
    avg = emb_mod._pool_features(features, "avg")
    both = emb_mod._pool_features(features, "cls+avg")

    torch.testing.assert_close(cls, torch.tensor([[1.0, 2.0]]))
    torch.testing.assert_close(avg, torch.tensor([[4.0, 5.0]]))
    torch.testing.assert_close(both, torch.tensor([[1.0, 2.0, 4.0, 5.0]]))


def test_extract_embeddings_skips_bad_images_and_normalizes(monkeypatch):
    paths = [Path("a.jpg"), Path("bad.jpg"), Path("c.jpg")]

    monkeypatch.setattr(emb_mod, "build_transform", lambda: "unused")

    def fake_load(path, _transform):
        if path.name == "bad.jpg":
            raise ValueError("bad image")
        marker = 1.0 if path.name == "a.jpg" else 3.0
        return torch.full((3, 2, 2), marker, dtype=torch.float32)

    class _FakeModel:
        def forward_features(self, batch):
            marker = batch[:, 0, 0, 0]
            cls = torch.stack([marker, marker + 1.0], dim=1).unsqueeze(1)
            patches = torch.stack([marker + 2.0, marker + 3.0], dim=1).unsqueeze(1).repeat(1, 2, 1)
            return torch.cat([cls, patches], dim=1)

    monkeypatch.setattr(emb_mod, "load_and_preprocess_image", fake_load)
    emb, valid = emb_mod.extract_embeddings(
        paths=paths,
        model=_FakeModel(),
        device=torch.device("cpu"),
        batch_size=2,
        pooling="cls",
    )

    assert valid == [0, 2]
    assert emb.shape == (2, 2)
    norms = np.linalg.norm(emb, axis=1)
    np.testing.assert_allclose(norms, np.ones_like(norms), atol=1e-6)


def test_extract_embeddings_raises_when_all_images_fail(monkeypatch):
    monkeypatch.setattr(emb_mod, "build_transform", lambda: "unused")
    monkeypatch.setattr(
        emb_mod,
        "load_and_preprocess_image",
        lambda _p, _t: (_ for _ in ()).throw(ValueError("fail")),
    )

    class _FakeModel:
        def forward_features(self, batch):
            return batch

    with pytest.raises(RuntimeError, match="No images could be loaded successfully"):
        emb_mod.extract_embeddings(
            paths=[Path("a.jpg")],
            model=_FakeModel(),
            device=torch.device("cpu"),
            batch_size=1,
            pooling="cls",
        )


def test_extract_embeddings_on_batch_callback(monkeypatch):
    """Verify the on_batch callback is invoked with (processed, total)."""
    paths = [Path("a.jpg"), Path("b.jpg"), Path("c.jpg")]

    monkeypatch.setattr(emb_mod, "build_transform", lambda: "unused")

    def fake_load(path, _transform):
        return torch.full((3, 2, 2), 1.0, dtype=torch.float32)

    class _FakeModel:
        def forward_features(self, batch):
            b = batch.shape[0]
            cls = torch.ones((b, 1, 2))
            patches = torch.ones((b, 2, 2))
            return torch.cat([cls, patches], dim=1)

    monkeypatch.setattr(emb_mod, "load_and_preprocess_image", fake_load)

    progress: list[tuple[int, int]] = []
    emb_mod.extract_embeddings(
        paths=paths,
        model=_FakeModel(),
        device=torch.device("cpu"),
        batch_size=2,
        pooling="cls",
        on_batch=lambda processed, total: progress.append((processed, total)),
    )

    # Two batches: first with 2 images, second with 1
    assert len(progress) == 2
    assert all(total == 3 for _, total in progress)
    assert progress[-1][0] == 3


def test_extract_embeddings_on_batch_none_is_safe(monkeypatch):
    """Verify on_batch=None (default) works without error."""
    monkeypatch.setattr(emb_mod, "build_transform", lambda: "unused")

    def fake_load(path, _transform):
        return torch.full((3, 2, 2), 1.0, dtype=torch.float32)

    class _FakeModel:
        def forward_features(self, batch):
            b = batch.shape[0]
            cls = torch.ones((b, 1, 2))
            patches = torch.ones((b, 2, 2))
            return torch.cat([cls, patches], dim=1)

    monkeypatch.setattr(emb_mod, "load_and_preprocess_image", fake_load)

    emb, valid = emb_mod.extract_embeddings(
        paths=[Path("a.jpg")],
        model=_FakeModel(),
        device=torch.device("cpu"),
        batch_size=1,
        pooling="cls",
        on_batch=None,
    )
    assert emb.shape[0] == 1
    assert valid == [0]


def test_extract_embeddings_empty_batch_calls_on_batch(monkeypatch):
    """When all images in a batch fail, on_batch is still called."""
    monkeypatch.setattr(emb_mod, "build_transform", lambda: "unused")

    def always_fail(path, _transform):
        raise ValueError("corrupt")

    def good_load(path, _transform):
        return torch.full((3, 2, 2), 1.0, dtype=torch.float32)

    call_count = {"n": 0}

    def switching_load(path, _transform):
        # First two calls fail (batch 1), next one succeeds (batch 2)
        call_count["n"] += 1
        if call_count["n"] <= 2:
            raise ValueError("corrupt")
        return torch.full((3, 2, 2), 1.0, dtype=torch.float32)

    class _FakeModel:
        def forward_features(self, batch):
            b = batch.shape[0]
            cls = torch.ones((b, 1, 2))
            patches = torch.ones((b, 2, 2))
            return torch.cat([cls, patches], dim=1)

    monkeypatch.setattr(emb_mod, "load_and_preprocess_image", switching_load)

    progress: list[tuple[int, int]] = []
    emb, valid = emb_mod.extract_embeddings(
        paths=[Path("bad1.jpg"), Path("bad2.jpg"), Path("ok.jpg")],
        model=_FakeModel(),
        device=torch.device("cpu"),
        batch_size=2,
        pooling="cls",
        on_batch=lambda p, t: progress.append((p, t)),
    )

    # Batch 1 (2 images) all fail → on_batch called with empty batch path
    # Batch 2 (1 image) succeeds → on_batch called normally
    assert len(progress) == 2
    assert progress[0] == (2, 3)  # empty batch still advances processed count
    assert progress[1] == (3, 3)
    assert emb.shape[0] == 1
    assert valid == [2]
