"""Tests for photosorter.embeddings utility logic."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import torch
from PIL import Image
from torchvision import transforms

from photosorter import embeddings as emb_mod
from photosorter.config import (
    DEFAULTS,
    MODEL_BUNDLE_FILENAME,
    MODEL_CHECKPOINT_ENV,
    MODEL_HF_FILENAME,
    MODEL_OFFLINE_ENV,
    MODEL_TIMM_ID,
)


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


def test_bundled_resources_dir_detects_app_resources(monkeypatch, tmp_path):
    fake_file = (
        tmp_path
        / "PhotoSorter.app"
        / "Contents"
        / "Resources"
        / "engine"
        / "photosorter_core"
        / "photosorter"
        / "embeddings.py"
    )
    monkeypatch.setattr(emb_mod, "__file__", str(fake_file))

    resources = emb_mod._bundled_resources_dir()
    assert resources == fake_file.parents[3]  # .../Contents/Resources


def test_local_model_candidates_include_env_model_dir_and_dedupe(monkeypatch, tmp_path):
    model_dir = tmp_path / "models"
    resources_dir = tmp_path / "PhotoSorter.app" / "Contents" / "Resources"
    checkpoint_path = model_dir / MODEL_BUNDLE_FILENAME

    monkeypatch.setenv(MODEL_CHECKPOINT_ENV, str(checkpoint_path))
    monkeypatch.setenv("PHOTOSORTER_MODEL_DIR", str(model_dir))
    monkeypatch.setattr(emb_mod, "_bundled_resources_dir", lambda: resources_dir)

    candidates = emb_mod._local_model_candidates()

    assert candidates[0] == checkpoint_path
    assert checkpoint_path in candidates
    assert model_dir / MODEL_HF_FILENAME in candidates
    assert resources_dir / "models" / MODEL_BUNDLE_FILENAME in candidates
    assert resources_dir / "models" / MODEL_HF_FILENAME in candidates
    # Duplicate env checkpoint + model_dir/bundle path should be deduped.
    assert candidates.count(checkpoint_path) == 1


def test_resolve_local_model_checkpoint_returns_first_existing(monkeypatch, tmp_path):
    missing = tmp_path / "missing.safetensors"
    existing = tmp_path / "existing.safetensors"
    existing.write_bytes(b"x")
    monkeypatch.setattr(emb_mod, "_local_model_candidates", lambda: [missing, existing])

    assert emb_mod._resolve_local_model_checkpoint() == existing


def test_load_model_uses_local_checkpoint_when_available(monkeypatch, tmp_path):
    captured = {}
    model = _DummyModel()
    checkpoint = tmp_path / "model.safetensors"
    checkpoint.write_bytes(b"local-checkpoint")

    def fake_create_model(model_id, pretrained):
        captured["model_id"] = model_id
        captured["pretrained"] = pretrained
        return model

    def fake_load_checkpoint(_model, checkpoint_path):
        captured["checkpoint_path"] = checkpoint_path

    monkeypatch.setenv(MODEL_CHECKPOINT_ENV, str(checkpoint))
    monkeypatch.delenv(MODEL_OFFLINE_ENV, raising=False)
    monkeypatch.setattr(emb_mod, "_resolve_local_model_checkpoint", lambda: checkpoint)
    monkeypatch.setattr(emb_mod.timm, "create_model", fake_create_model)
    monkeypatch.setattr(emb_mod, "load_checkpoint", fake_load_checkpoint)
    loaded = emb_mod.load_model(torch.device("cpu"))

    assert loaded is model
    assert captured["model_id"] == MODEL_TIMM_ID
    assert captured["pretrained"] is False
    assert captured["checkpoint_path"] == str(checkpoint)
    assert model.moved_to == torch.device("cpu")
    assert model.eval_called is True


def test_load_model_falls_back_to_remote_when_local_missing(monkeypatch):
    captured = {}
    model = _DummyModel()

    def fake_create_model(model_id, pretrained):
        captured["model_id"] = model_id
        captured["pretrained"] = pretrained
        return model

    monkeypatch.delenv(MODEL_CHECKPOINT_ENV, raising=False)
    monkeypatch.delenv(MODEL_OFFLINE_ENV, raising=False)
    monkeypatch.setattr(emb_mod, "_resolve_local_model_checkpoint", lambda: None)
    monkeypatch.setattr(emb_mod.timm, "create_model", fake_create_model)
    loaded = emb_mod.load_model(torch.device("cpu"))

    assert loaded is model
    assert captured == {"model_id": MODEL_TIMM_ID, "pretrained": True}
    assert model.moved_to == torch.device("cpu")
    assert model.eval_called is True


def test_load_model_offline_requires_local_checkpoint(monkeypatch):
    monkeypatch.setattr(emb_mod, "_resolve_local_model_checkpoint", lambda: None)
    monkeypatch.setenv(MODEL_OFFLINE_ENV, "1")

    def fail_create_model(*_args, **_kwargs):
        raise AssertionError("timm.create_model should not be called in offline-only mode without a local checkpoint")

    monkeypatch.setattr(emb_mod.timm, "create_model", fail_create_model)

    with pytest.raises(RuntimeError, match="Local model checkpoint required"):
        emb_mod.load_model(torch.device("cpu"))


def test_load_model_wraps_local_checkpoint_error(monkeypatch, tmp_path):
    checkpoint = tmp_path / "bad-model.safetensors"
    checkpoint.write_bytes(b"bad")

    monkeypatch.setattr(emb_mod, "_resolve_local_model_checkpoint", lambda: checkpoint)
    monkeypatch.setattr(emb_mod.timm, "create_model", lambda *args, **kwargs: _DummyModel())
    monkeypatch.setattr(
        emb_mod,
        "load_checkpoint",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(ValueError("corrupt checkpoint")),
    )

    with pytest.raises(RuntimeError, match="Failed to load local model checkpoint"):
        emb_mod.load_model(torch.device("cpu"))


def test_build_transform_shape_and_normalization():
    tfm = emb_mod.build_transform()
    assert isinstance(tfm, transforms.Compose)
    assert [type(op).__name__ for op in tfm.transforms] == [
        "ResizeAndPadToSquare",
        "ToTensor",
        "Normalize",
    ]
    assert tfm.transforms[0].size == DEFAULTS.crop_size
    norm = tfm.transforms[-1]
    assert tuple(norm.mean) == DEFAULTS.imagenet_mean
    assert tuple(norm.std) == DEFAULTS.imagenet_std


def test_build_transform_for_mode_timm_uses_timm_factory(monkeypatch):
    fake_model = object()
    seen = {}

    monkeypatch.setattr(
        emb_mod,
        "resolve_model_data_config",
        lambda model: {"input_size": (3, 256, 256), "mean": (0.1, 0.2, 0.3)},
    )

    def fake_create_transform(**kwargs):
        seen.update(kwargs)
        return "timm-transform"

    monkeypatch.setattr(emb_mod, "create_transform", fake_create_transform)

    out = emb_mod.build_transform_for_mode("timm", model=fake_model)

    assert out == "timm-transform"
    assert seen["input_size"] == (3, 256, 256)
    assert seen["mean"] == (0.1, 0.2, 0.3)
    assert seen["is_training"] is False


def test_build_transform_for_mode_rejects_unknown_mode():
    with pytest.raises(ValueError, match="Unknown preprocess mode 'bad'"):
        emb_mod.build_transform_for_mode("bad")


def test_build_transform_for_mode_timm_requires_model():
    with pytest.raises(ValueError, match="model is required"):
        emb_mod.build_transform_for_mode("timm")


def test_resize_and_pad_to_square_preserves_aspect_ratio():
    img = Image.new("RGB", (400, 200), color=(255, 0, 0))
    out = emb_mod._resize_and_pad_to_square(img, 256)

    assert out.size == (256, 256)

    arr = np.array(out)
    fill = np.array([round(c * 255) for c in DEFAULTS.imagenet_mean], dtype=np.uint8)
    # Letterbox padding on top/bottom for a wide image.
    np.testing.assert_array_equal(arr[10, 10], fill)
    np.testing.assert_array_equal(arr[128, 128], np.array([255, 0, 0], dtype=np.uint8))


def test_resize_and_pad_to_square_rejects_non_positive_size():
    with pytest.raises(ValueError, match="Square size must be > 0"):
        emb_mod._resize_and_pad_to_square(Image.new("RGB", (10, 10)), 0)


def test_resize_and_pad_to_square_rejects_invalid_image_size():
    class _BadImage:
        size = (0, 10)

    with pytest.raises(ValueError, match="Invalid image size"):
        emb_mod._resize_and_pad_to_square(_BadImage(), 256)


def test_resize_and_pad_to_square_returns_same_object_when_already_square():
    img = Image.new("RGB", (256, 256), color=(1, 2, 3))
    out = emb_mod._resize_and_pad_to_square(img, 256)
    assert out is img


def test_resize_and_pad_transform_calls_underlying_helper(monkeypatch):
    seen = {}

    def fake_resize(img, size):
        seen["img"] = img
        seen["size"] = size
        return "resized"

    monkeypatch.setattr(emb_mod, "_resize_and_pad_to_square", fake_resize)
    transform = emb_mod.ResizeAndPadToSquare(128)
    src = Image.new("RGB", (64, 32))

    assert transform(src) == "resized"
    assert seen == {"img": src, "size": 128}


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


def test_load_raw_prefers_embedded_jpeg_preview(monkeypatch):
    preview_img = Image.new("RGB", (960, 640), color=(10, 20, 30))
    from io import BytesIO

    buf = BytesIO()
    preview_img.save(buf, format="JPEG")
    jpeg_bytes = buf.getvalue()

    class _FakeThumb:
        format = emb_mod.rawpy.ThumbFormat.JPEG
        data = jpeg_bytes

    class _FakeRaw:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract_thumb(self):
            return _FakeThumb()

        def postprocess(self, *args, **kwargs):
            raise AssertionError("postprocess should not run when preview JPEG exists")

    monkeypatch.setattr(emb_mod.rawpy, "imread", lambda _p: _FakeRaw())

    img = emb_mod._load_raw(Path("/tmp/has_preview.arw"))
    assert img.size == (960, 640)


def test_load_raw_preview_failure_falls_back_to_postprocess(monkeypatch):
    class _FakeThumb:
        format = emb_mod.rawpy.ThumbFormat.JPEG
        data = b"not-a-jpeg"

    class _FakeRaw:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract_thumb(self):
            return _FakeThumb()

        def postprocess(self, half_size, use_camera_wb):
            assert half_size is True
            assert use_camera_wb is True
            return np.zeros((4, 5, 3), dtype=np.uint8)

    monkeypatch.setattr(emb_mod.rawpy, "imread", lambda _p: _FakeRaw())
    monkeypatch.setattr(emb_mod, "_read_raw_orientation", lambda _p: None)

    img = emb_mod._load_raw(Path("/tmp/bad_preview.dng"))
    assert img.size == (5, 4)


def test_load_raw_preview_bitmap_uses_raw_orientation(monkeypatch):
    thumb_data = np.zeros((2, 3, 3), dtype=np.uint8)

    class _FakeThumb:
        format = emb_mod.rawpy.ThumbFormat.BITMAP
        data = thumb_data

    class _FakeRaw:
        def extract_thumb(self):
            return _FakeThumb()

    monkeypatch.setattr(emb_mod, "_read_raw_orientation", lambda _p: 8)
    monkeypatch.setattr(
        emb_mod,
        "_apply_orientation",
        lambda img, orientation: ("applied", img.size, orientation),
    )

    out = emb_mod._load_raw_preview(_FakeRaw(), Path("/tmp/thumb.nef"))
    assert out == ("applied", (3, 2), 8)


def test_load_raw_preview_unsupported_format_returns_none():
    class _FakeThumb:
        format = object()
        data = b"unused"

    class _FakeRaw:
        def extract_thumb(self):
            return _FakeThumb()

    assert emb_mod._load_raw_preview(_FakeRaw(), Path("/tmp/thumb.raw")) is None


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


def test_pool_features_avg_excludes_all_prefix_tokens():
    # 5 prefix tokens (DINOv3 in timm) + 2 patch tokens
    features = torch.tensor([[
        [1.0, 1.0],   # cls
        [2.0, 2.0],   # prefix
        [3.0, 3.0],   # prefix
        [4.0, 4.0],   # prefix
        [5.0, 5.0],   # prefix
        [10.0, 20.0],  # patch
        [30.0, 40.0],  # patch
    ]])

    avg = emb_mod._pool_features(features, "avg", num_prefix_tokens=5)
    both = emb_mod._pool_features(features, "cls+avg", num_prefix_tokens=5)

    torch.testing.assert_close(avg, torch.tensor([[20.0, 30.0]]))
    torch.testing.assert_close(both, torch.tensor([[1.0, 1.0, 20.0, 30.0]]))


def test_extract_embeddings_skips_bad_images_and_normalizes(monkeypatch):
    paths = [Path("a.jpg"), Path("bad.jpg"), Path("c.jpg")]

    monkeypatch.setattr(
        emb_mod,
        "build_transform_for_mode",
        lambda preprocess, model=None: "unused",
    )

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
    monkeypatch.setattr(
        emb_mod,
        "build_transform_for_mode",
        lambda preprocess, model=None: "unused",
    )
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

    monkeypatch.setattr(
        emb_mod,
        "build_transform_for_mode",
        lambda preprocess, model=None: "unused",
    )

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
    monkeypatch.setattr(
        emb_mod,
        "build_transform_for_mode",
        lambda preprocess, model=None: "unused",
    )

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


def test_prescale_does_not_mutate_original():
    """_prescale should return a copy, not modify the input image."""
    img = Image.new("RGB", (2048, 1024), color=(100, 150, 200))
    original_size = img.size
    out = emb_mod._prescale(img)
    # Original must be unchanged
    assert img.size == original_size
    # Output should be different
    assert out is not img
    assert max(out.size) <= DEFAULTS.prescale_size


def test_detect_device_rejects_unknown_device():
    """detect_device should raise ValueError for invalid device strings."""
    with pytest.raises(ValueError, match="Unknown device 'tpu'"):
        emb_mod.detect_device("tpu")


def test_detect_device_accepts_valid_devices():
    """detect_device should accept all valid device strings."""
    # 'cpu' is always safe to test without GPU hardware
    result = emb_mod.detect_device("cpu")
    assert result.type == "cpu"


def test_pool_features_rejects_unknown_strategy():
    """_pool_features should raise ValueError for invalid pooling strings."""
    features = torch.tensor([[[1.0, 2.0], [3.0, 4.0]]])
    with pytest.raises(ValueError, match="Unknown pooling strategy 'bad'"):
        emb_mod._pool_features(features, "bad")


def test_pool_features_rejects_invalid_prefix_count():
    features = torch.tensor([[[1.0, 2.0], [3.0, 4.0]]])
    with pytest.raises(ValueError, match="num_prefix_tokens must be >= 1"):
        emb_mod._pool_features(features, "avg", num_prefix_tokens=0)


def test_pool_features_rejects_when_no_patch_tokens_remain():
    features = torch.tensor([[[1.0, 2.0]]])  # CLS only
    with pytest.raises(ValueError, match="no patch tokens remain"):
        emb_mod._pool_features(features, "avg", num_prefix_tokens=1)


def test_load_model_wraps_network_error(monkeypatch):
    """load_model should wrap download/network errors with a clear message."""
    def fail_create_model(model_id, pretrained):
        raise ConnectionError("Network unreachable")

    monkeypatch.setattr(emb_mod.timm, "create_model", fail_create_model)

    with pytest.raises(RuntimeError, match="Failed to load model"):
        emb_mod.load_model(torch.device("cpu"))


def test_extract_embeddings_empty_batch_calls_on_batch(monkeypatch):
    """When all images in a batch fail, on_batch is still called."""
    monkeypatch.setattr(
        emb_mod,
        "build_transform_for_mode",
        lambda preprocess, model=None: "unused",
    )

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
