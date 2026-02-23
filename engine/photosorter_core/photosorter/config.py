"""Default configuration constants."""

from __future__ import annotations

from dataclasses import dataclass


# Model configuration
MODEL_TIMM_ID = "vit_huge_plus_patch16_dinov3.lvd1689m"
MODEL_DESC = "DINOv3 ViT-H+/16 — 840M params"
MODEL_HF_REPO_ID = "timm/vit_huge_plus_patch16_dinov3.lvd1689m"
MODEL_HF_FILENAME = "model.safetensors"
MODEL_BUNDLE_FILENAME = "vit_huge_plus_patch16_dinov3.lvd1689m.safetensors"
MODEL_CHECKPOINT_ENV = "PHOTOSORTER_MODEL_CHECKPOINT"
MODEL_OFFLINE_ENV = "PHOTOSORTER_DISABLE_REMOTE_MODEL"


@dataclass(frozen=True)
class Defaults:
    # Model
    batch_size: int = 16
    pooling: str = "avg"
    preprocess: str = "letterbox"

    # Device
    device: str = "auto"

    # Image preprocessing
    resize_size: int = 256
    crop_size: int = 256
    imagenet_mean: tuple[float, float, float] = (0.485, 0.456, 0.406)
    imagenet_std: tuple[float, float, float] = (0.229, 0.224, 0.225)

    # Clustering
    distance_threshold: float = 0.2
    linkage: str = "complete"

    # Temporal
    temporal_weight: float = 0.0

    # Output
    manifest_filename: str = "manifest.json"
    cache_dirname: str = "PhotoSorter_Cache"
    grid_thumb_dirname: str = "GridThumb"
    detail_proxy_dirname: str = "DetailProxy"

    # Supported image extensions
    image_extensions: tuple[str, ...] = (
        ".jpg", ".jpeg", ".png", ".tiff", ".tif", ".bmp", ".webp",
    )
    raw_extensions: tuple[str, ...] = (
        ".arw", ".dng", ".cr2", ".cr3", ".nef", ".orf", ".raf", ".rw2",
    )

    # Pre-scale threshold: images larger than this (long edge) get
    # downsampled before the transform pipeline to save memory.
    prescale_size: int = 512


DEFAULTS = Defaults()
