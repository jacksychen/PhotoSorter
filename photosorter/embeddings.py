"""DINOv3 embedding extraction."""

from __future__ import annotations

import logging
from pathlib import Path

import numpy as np
import rawpy
import timm
import torch
from PIL import Image, ImageOps
from torchvision import transforms
from tqdm import tqdm

from photosorter.config import DEFAULTS, MODEL_TIMM_ID, MODEL_DESC

logger = logging.getLogger("photosorter")


def detect_device(requested: str = "auto") -> torch.device:
    if requested != "auto":
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def load_model(device: torch.device) -> torch.nn.Module:
    logger.info("Loading %s on %s …", MODEL_DESC, device)
    model = timm.create_model(MODEL_TIMM_ID, pretrained=True)
    model = model.to(device)
    model.eval()
    return model


def build_transform() -> transforms.Compose:
    return transforms.Compose([
        transforms.Resize(DEFAULTS.resize_size),
        transforms.CenterCrop(DEFAULTS.crop_size),
        transforms.ToTensor(),
        transforms.Normalize(
            mean=list(DEFAULTS.imagenet_mean),
            std=list(DEFAULTS.imagenet_std),
        ),
    ])


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


def _load_raw(path: Path) -> Image.Image:
    """Decode a RAW file (ARW, DNG, CR2, …) via rawpy/LibRaw.

    Uses half_size=True to demosaic at half resolution — reduces memory
    by ~4x while still far exceeding the 224px needed by DINOv3.
    Applies EXIF Orientation rotation since rawpy does not handle it.
    """
    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(half_size=True, use_camera_wb=True)
    img = Image.fromarray(rgb)
    orientation = _read_raw_orientation(path)
    if orientation and orientation in _ORIENTATION_TO_TRANSPOSE:
        img = img.transpose(_ORIENTATION_TO_TRANSPOSE[orientation])
    return img


def _prescale(img: Image.Image) -> Image.Image:
    """Downsample large images before the transform pipeline.

    If the long edge exceeds prescale_size (default 512), shrink
    proportionally so the full pixel buffer stays small in memory.
    The torchvision Resize(256) → CenterCrop(224) only needs ~256px,
    so 512px is more than enough headroom.
    """
    max_dim = max(img.size)  # (width, height)
    limit = DEFAULTS.prescale_size
    if max_dim > limit:
        img.thumbnail((limit, limit), Image.LANCZOS)
    return img


def load_and_preprocess_image(
    path: Path, transform: transforms.Compose,
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


def _pool_features(features: torch.Tensor, pooling: str) -> torch.Tensor:
    """Pool transformer features into a single embedding per image.

    features shape: (batch, seq_len, embed_dim)
    - seq_len[0] is the CLS token, seq_len[1:] are patch tokens.
    """
    cls_token = features[:, 0]
    if pooling == "cls":
        return cls_token
    patch_avg = features[:, 1:].mean(dim=1)
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
) -> tuple[np.ndarray, list[int]]:
    """Extract embeddings, skipping images that fail to load.

    Returns (embeddings, valid_indices) where valid_indices maps each
    embedding row back to the original index in *paths*.
    """
    transform = build_transform()
    all_embeddings: list[np.ndarray] = []
    valid_indices: list[int] = []

    for start in tqdm(range(0, len(paths), batch_size), desc="Extracting embeddings"):
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
            continue

        batch = torch.stack(batch_tensors).to(device)

        with torch.no_grad():
            features = model.forward_features(batch)
            emb = _pool_features(features, pooling)

        emb = emb.cpu().float().numpy()
        del batch, features
        # L2-normalize each embedding
        norms = np.linalg.norm(emb, axis=1, keepdims=True)
        norms = np.clip(norms, 1e-12, None)
        emb = emb / norms
        all_embeddings.append(emb)
        valid_indices.extend(batch_indices)

    if not all_embeddings:
        raise RuntimeError("No images could be loaded successfully")

    return np.concatenate(all_embeddings, axis=0), valid_indices


