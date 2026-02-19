"""Default configuration constants."""

from dataclasses import dataclass


# Model configuration
MODEL_TIMM_ID = "vit_huge_plus_patch16_dinov3.lvd1689m"
MODEL_DESC = "DINOv3 ViT-H+/16 — 840M params"


@dataclass(frozen=True)
class Defaults:
    # Model
    batch_size: int = 16
    pooling: str = "cls"

    # Device
    device: str = "auto"

    # Image preprocessing
    resize_size: int = 256
    crop_size: int = 224
    imagenet_mean: tuple = (0.485, 0.456, 0.406)
    imagenet_std: tuple = (0.229, 0.224, 0.225)

    # Clustering
    distance_threshold: float = 0.4
    linkage: str = "average"

    # Temporal
    temporal_weight: float = 0.0

    # Output
    manifest_filename: str = "manifest.json"

    # Supported image extensions
    image_extensions: tuple = (
        ".jpg", ".jpeg", ".png", ".tiff", ".tif", ".bmp", ".webp",
    )
    raw_extensions: tuple = (
        ".arw", ".dng", ".cr2", ".cr3", ".nef", ".orf", ".raf", ".rw2",
    )

    # Pre-scale threshold: images larger than this (long edge) get
    # downsampled before the transform pipeline to save memory.
    prescale_size: int = 512


DEFAULTS = Defaults()
