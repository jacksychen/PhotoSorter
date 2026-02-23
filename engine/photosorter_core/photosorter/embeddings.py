"""DINOv3 embedding extraction."""

from __future__ import annotations

import logging
import os
import io
from collections.abc import Callable
from pathlib import Path

import numpy as np
import rawpy
import timm
import torch
from timm.data import create_transform, resolve_model_data_config
from timm.models import load_checkpoint
from PIL import Image, ImageOps
from torchvision import transforms
from tqdm import tqdm

from photosorter.config import (
    DEFAULTS,
    MODEL_BUNDLE_FILENAME,
    MODEL_CHECKPOINT_ENV,
    MODEL_DESC,
    MODEL_HF_FILENAME,
    MODEL_OFFLINE_ENV,
    MODEL_TIMM_ID,
)
from photosorter.pipeline import (
    VALID_DEVICE_OPTIONS,
    VALID_POOLING_OPTIONS,
    VALID_PREPROCESS_OPTIONS,
)

logger = logging.getLogger("photosorter")


def detect_device(requested: str = "auto") -> torch.device:
    """Resolve the requested device string into a ``torch.device``.

    Raises ``ValueError`` for unrecognised device strings so callers
    get a clear error instead of a delayed CUDA/MPS failure.
    """
    if requested not in VALID_DEVICE_OPTIONS:
        raise ValueError(
            f"Unknown device '{requested}'. "
            f"Must be one of {sorted(VALID_DEVICE_OPTIONS)}."
        )
    if requested != "auto":
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def _is_truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def _bundled_resources_dir() -> Path | None:
    """Best-effort detection of `.../PhotoSorter.app/Contents/Resources`."""
    this_file = Path(__file__).resolve()
    for parent in this_file.parents:
        if parent.name == "Resources" and parent.parent.name == "Contents":
            return parent
    return None


def _local_model_candidates() -> list[Path]:
    """Return local model checkpoint candidates in priority order."""
    candidates: list[Path] = []

    model_checkpoint_env = os.getenv(MODEL_CHECKPOINT_ENV)
    if model_checkpoint_env:
        candidates.append(Path(model_checkpoint_env).expanduser())

    model_dir_env = os.getenv("PHOTOSORTER_MODEL_DIR")
    if model_dir_env:
        model_dir = Path(model_dir_env).expanduser()
        candidates.append(model_dir / MODEL_BUNDLE_FILENAME)
        candidates.append(model_dir / MODEL_HF_FILENAME)

    resources_dir = _bundled_resources_dir()
    if resources_dir is not None:
        candidates.append(resources_dir / "models" / MODEL_BUNDLE_FILENAME)
        candidates.append(resources_dir / "models" / MODEL_HF_FILENAME)

    project_root = Path(__file__).resolve().parents[3]
    candidates.append(project_root / "models" / MODEL_BUNDLE_FILENAME)
    candidates.append(project_root / "models" / MODEL_HF_FILENAME)

    deduped: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate.resolve(strict=False))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(candidate)
    return deduped


def _resolve_local_model_checkpoint() -> Path | None:
    for candidate in _local_model_candidates():
        if candidate.is_file():
            return candidate
    return None


def load_model(device: torch.device) -> torch.nn.Module:
    """Load the DINOv3 model.

    Local checkpoint takes precedence to support fully-offline,
    self-contained app bundles.

    When `PHOTOSORTER_DISABLE_REMOTE_MODEL=1`, remote download fallback
    is disabled and missing local checkpoints are treated as fatal.
    """
    logger.info("Loading %s on %s …", MODEL_DESC, device)

    local_checkpoint = _resolve_local_model_checkpoint()
    if local_checkpoint is not None:
        logger.info("Loading model weights from local checkpoint: %s", local_checkpoint)
        try:
            model = timm.create_model(MODEL_TIMM_ID, pretrained=False)
            load_checkpoint(model, str(local_checkpoint))
        except Exception as exc:
            raise RuntimeError(
                f"Failed to load local model checkpoint '{local_checkpoint}': {exc}"
            ) from exc
    else:
        if _is_truthy(os.getenv(MODEL_OFFLINE_ENV)):
            searched = "\n".join(str(p) for p in _local_model_candidates())
            raise RuntimeError(
                "Local model checkpoint required, but none was found. "
                f"Set {MODEL_CHECKPOINT_ENV} or bundle the model file. "
                f"Searched paths:\n{searched}"
            )
        try:
            model = timm.create_model(MODEL_TIMM_ID, pretrained=True)
        except Exception as exc:
            raise RuntimeError(
                f"Failed to load model '{MODEL_TIMM_ID}'. "
                f"If this is the first run, an Internet connection is required "
                f"to download the model weights. Original error: {exc}"
            ) from exc

    model = model.to(device)
    model.eval()
    return model


def _resize_and_pad_to_square(img: Image.Image, size: int) -> Image.Image:
    """Resize with aspect ratio preserved, then center-pad to a square."""
    if size <= 0:
        raise ValueError(f"Square size must be > 0, got {size}")
    width, height = img.size
    if width <= 0 or height <= 0:
        raise ValueError(f"Invalid image size: {img.size}")

    scale = min(size / width, size / height)
    new_width = max(1, min(size, int(round(width * scale))))
    new_height = max(1, min(size, int(round(height * scale))))

    if (new_width, new_height) == img.size:
        resized = img
    else:
        resized = img.resize((new_width, new_height), Image.BICUBIC)

    if (new_width, new_height) == (size, size):
        return resized

    fill = tuple(int(round(c * 255)) for c in DEFAULTS.imagenet_mean)
    canvas = Image.new("RGB", (size, size), fill)
    offset = ((size - new_width) // 2, (size - new_height) // 2)
    canvas.paste(resized, offset)
    return canvas


class ResizeAndPadToSquare:
    """Torchvision-compatible PIL transform for square letterboxing."""

    def __init__(self, size: int) -> None:
        self.size = size

    def __call__(self, img: Image.Image) -> Image.Image:
        return _resize_and_pad_to_square(img, self.size)


def build_transform() -> transforms.Compose:
    return build_transform_for_mode(DEFAULTS.preprocess)


def build_transform_for_mode(
    preprocess: str,
    model: torch.nn.Module | None = None,
) -> transforms.Compose:
    """Build the preprocessing transform for a configured mode."""
    if preprocess not in VALID_PREPROCESS_OPTIONS:
        raise ValueError(
            f"Unknown preprocess mode '{preprocess}'. "
            f"Must be one of {sorted(VALID_PREPROCESS_OPTIONS)}."
        )

    if preprocess == "letterbox":
        # DINOv3 ViT-H+/16 pretrained config expects fixed 256x256 input.
        return transforms.Compose([
            ResizeAndPadToSquare(DEFAULTS.crop_size),
            transforms.ToTensor(),
            transforms.Normalize(
                mean=list(DEFAULTS.imagenet_mean),
                std=list(DEFAULTS.imagenet_std),
            ),
        ])

    if model is None:
        raise ValueError("model is required for preprocess='timm'")
    data_cfg = resolve_model_data_config(model)
    return create_transform(**data_cfg, is_training=False)


_ORIENTATION_TO_TRANSPOSE = {
    2: Image.FLIP_LEFT_RIGHT,
    3: Image.ROTATE_180,
    4: Image.FLIP_TOP_BOTTOM,
    5: Image.TRANSPOSE,
    6: Image.ROTATE_270,
    7: Image.TRANSVERSE,
    8: Image.ROTATE_90,
}


def _read_raw_orientation(path: Path) -> int | None:
    """Read EXIF Orientation tag from a RAW file via PIL.

    Most RAW formats (ARW, DNG, CR2, NEF) are TIFF-based, so PIL can
    parse the EXIF header without fully decoding the image data.
    """
    try:
        with Image.open(path) as img:
            return img.getexif().get(0x0112)
    except Exception:
        return None


def _apply_orientation(img: Image.Image, orientation: int | None) -> Image.Image:
    """Apply TIFF/EXIF orientation using PIL transpose constants."""
    if orientation and orientation in _ORIENTATION_TO_TRANSPOSE:
        return img.transpose(_ORIENTATION_TO_TRANSPOSE[orientation])
    return img


def _load_raw_preview(
    raw: rawpy.RawPy,
    path: Path,
) -> Image.Image | None:
    """Load an embedded RAW preview if available.

    Prefers the camera-generated JPEG thumbnail/preview because it is
    dramatically faster than full RAW demosaic for embedding extraction.
    Returns ``None`` when no supported preview is available.
    """
    try:
        thumb = raw.extract_thumb()
    except Exception:
        return None

    if thumb.format == rawpy.ThumbFormat.JPEG:
        try:
            with Image.open(io.BytesIO(thumb.data)) as preview:
                # Preview JPEG may carry its own EXIF orientation.
                return ImageOps.exif_transpose(preview).convert("RGB")
        except Exception:
            return None

    if thumb.format == rawpy.ThumbFormat.BITMAP:
        img = Image.fromarray(thumb.data)
        # Bitmap previews usually lack EXIF, so use RAW container orientation.
        img = _apply_orientation(img, _read_raw_orientation(path))
        return img

    return None


def _load_raw_postprocess(raw: rawpy.RawPy, path: Path) -> Image.Image:
    """Decode a RAW file via rawpy/LibRaw full postprocess path."""
    rgb = raw.postprocess(half_size=True, use_camera_wb=True)
    img = Image.fromarray(rgb)
    img = _apply_orientation(img, _read_raw_orientation(path))
    return img


def _load_raw(path: Path) -> Image.Image:
    """Load a RAW file for embeddings, preferring embedded preview JPEG.

    Fast path: use embedded preview (typically JPEG) when present.
    Fallback: rawpy/LibRaw demosaic with ``half_size=True`` to reduce
    memory while still far exceeding the 256px model input.
    """
    with rawpy.imread(str(path)) as raw:
        preview = _load_raw_preview(raw, path)
        if preview is not None:
            return preview
        return _load_raw_postprocess(raw, path)


def _prescale(img: Image.Image) -> Image.Image:
    """Downsample large images before the transform pipeline.

    Returns a *new* image when resizing is needed so the caller's
    original is never mutated.  When no resizing is needed the same
    object is returned (no copy overhead).
    """
    max_dim = max(img.size)  # (width, height)
    limit = DEFAULTS.prescale_size
    if max_dim > limit:
        # Use Image.copy().thumbnail() to avoid mutating the original.
        copy = img.copy()
        copy.thumbnail((limit, limit), Image.LANCZOS)
        return copy
    return img


def load_and_preprocess_image(
    path: Path,
    transform: transforms.Compose,
) -> torch.Tensor:
    if path.suffix.lower() in DEFAULTS.raw_extensions:
        img = _load_raw(path)
    else:
        with Image.open(path) as raw_img:
            img = ImageOps.exif_transpose(raw_img.convert("RGB"))

    img = _prescale(img)
    tensor = transform(img)
    img.close()
    return tensor


def _pool_features(
    features: torch.Tensor,
    pooling: str,
    *,
    num_prefix_tokens: int = 1,
) -> torch.Tensor:
    """Pool transformer features into a single embedding per image.

    features shape: (batch, seq_len, embed_dim)
    - seq_len[0] is the CLS token.
    - seq_len[num_prefix_tokens:] are patch tokens.

    Raises ``ValueError`` for unknown pooling strategies.
    """
    if pooling not in VALID_POOLING_OPTIONS:
        raise ValueError(
            f"Unknown pooling strategy '{pooling}'. "
            f"Must be one of {sorted(VALID_POOLING_OPTIONS)}."
        )
    if num_prefix_tokens < 1:
        raise ValueError(
            f"num_prefix_tokens must be >= 1, got {num_prefix_tokens}"
        )
    cls_token = features[:, 0]
    if pooling == "cls":
        return cls_token
    if features.shape[1] <= num_prefix_tokens:
        raise ValueError(
            "Cannot compute patch average: no patch tokens remain after "
            f"excluding {num_prefix_tokens} prefix tokens"
        )
    patch_avg = features[:, num_prefix_tokens:].mean(dim=1)
    if pooling == "avg":
        return patch_avg
    # cls+avg: concatenate both
    return torch.cat([cls_token, patch_avg], dim=1)


def extract_embeddings(
    paths: list[Path],
    model: torch.nn.Module,
    device: torch.device,
    batch_size: int = DEFAULTS.batch_size,
    pooling: str = DEFAULTS.pooling,
    preprocess: str = DEFAULTS.preprocess,
    on_batch: Callable[[int, int], None] | None = None,
) -> tuple[np.ndarray, list[int]]:
    """Extract embeddings, skipping images that fail to load.

    Returns (embeddings, valid_indices) where valid_indices maps each
    embedding row back to the original index in *paths*.

    If *on_batch* is provided, it is called after each batch with
    (processed_count, total_count) for progress reporting.
    """
    transform = build_transform_for_mode(preprocess, model=model)
    all_embeddings: list[np.ndarray] = []
    valid_indices: list[int] = []
    total = len(paths)
    processed = 0
    num_prefix_tokens = int(getattr(model, "num_prefix_tokens", 1) or 1)

    for start in tqdm(range(0, total, batch_size), desc="Extracting embeddings"):
        batch_paths = paths[start : start + batch_size]
        batch_tensors: list[torch.Tensor] = []
        batch_indices: list[int] = []

        for i, p in enumerate(batch_paths):
            try:
                tensor = load_and_preprocess_image(p, transform)
                batch_tensors.append(tensor)
                batch_indices.append(start + i)
            except Exception as exc:
                logger.warning("Skipping %s: %s", p.name, exc)

        if not batch_tensors:
            processed += len(batch_paths)
            if on_batch is not None:
                on_batch(processed, total)
            continue

        batch = torch.stack(batch_tensors).to(device)

        with torch.inference_mode():
            features = model.forward_features(batch)
            emb = _pool_features(
                features,
                pooling,
                num_prefix_tokens=num_prefix_tokens,
            )

        emb = emb.cpu().float().numpy()
        del batch, features
        # L2-normalize each embedding
        norms = np.linalg.norm(emb, axis=1, keepdims=True)
        norms = np.clip(norms, 1e-12, None)
        emb = emb / norms
        all_embeddings.append(emb)
        valid_indices.extend(batch_indices)

        processed += len(batch_paths)
        if on_batch is not None:
            on_batch(processed, total)

    if not all_embeddings:
        raise RuntimeError("No images could be loaded successfully")

    return np.concatenate(all_embeddings, axis=0), valid_indices
