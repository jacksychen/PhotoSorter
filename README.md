# PhotoSorter

A CLI tool that reorders travel photos by visual similarity. Photos taken in an A→B→C→B→A pattern get reorganized to A,A,B,B,C,C — no GPS or timestamp metadata required.

Uses [DINOv3](https://github.com/facebookresearch/dinov3) ViT-H+/16 (840M params, 1280-dim embeddings) and agglomerative clustering to group visually similar photos, then outputs them in a coherent sequence.

## How It Works

1. **Discover** — scans a directory for all supported images (JPG, JPEG, PNG, TIFF, TIF, BMP, WebP, ARW, DNG, CR2, CR3, NEF, ORF, RAF, RW2), sorted by natural filename order
2. **Embed** — preprocesses each image (EXIF orientation correction, pre-scaling large images to 512 px long edge, RAW decoding at half resolution via rawpy), then extracts feature vectors using DINOv3 ViT-H+/16 with configurable pooling strategy (`--pooling`) and L2-normalises each embedding; images that fail to load are skipped with a warning
3. **Similarity** — computes a cosine similarity matrix from the normalised embeddings, converts it to a distance matrix (`1 - similarity`, clipped to `[0, 2]`), and optionally adds a temporal penalty weighted by `--temporal-weight`
4. **Cluster** — groups photos via agglomerative clustering (configurable `--linkage` on the precomputed distance matrix) with a configurable `--distance-threshold`
5. **Order** — sorts clusters by their earliest member's original index, preserving original file order within each cluster
6. **Output** — writes a `manifest.json` into the input directory with cluster assignments and the final ordering

## Requirements

- Python 3.10+
- macOS (MPS or CPU)

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .

# Optional: install GUI viewer dependencies
pip install -e ".[gui]"
```

> On first run, DINOv3 ViT-H+/16 weights are downloaded via timm from HuggingFace and cached automatically (~3.4 GB). No HuggingFace login required.

## Usage

### Basic — cluster photos and write manifest

```bash
python -m photosorter /path/to/photos
```

Writes `manifest.json` into the input directory with cluster assignments and ordering.

### Change pooling strategy — control what features are compared

```bash
# Default: CLS token (high-level semantic similarity)
python -m photosorter /path/to/photos --pooling cls

# Average patch tokens (visual appearance: color, texture)
python -m photosorter /path/to/photos --pooling avg

# Both combined (most discriminative, recommended for best results)
python -m photosorter /path/to/photos --pooling cls+avg
```

### Adjust clustering granularity

```bash
# Tighter clusters (more groups)
python -m photosorter /path/to/photos --distance-threshold 0.15

# Looser clusters (fewer groups)
python -m photosorter /path/to/photos --distance-threshold 0.5
```

### Change linkage strategy

```bash
# Strict — all photos in a cluster must be mutually similar
python -m photosorter /path/to/photos --linkage complete

# Balanced (default)
python -m photosorter /path/to/photos --linkage average

# Loose — only needs one similar pair to merge clusters
python -m photosorter /path/to/photos --linkage single
```

### Add temporal bias — prefer grouping consecutive photos

```bash
python -m photosorter /path/to/photos --temporal-weight 0.2
```

### Combined example

```bash
python -m photosorter /path/to/photos \
  --pooling cls+avg \
  --distance-threshold 0.3 \
  --linkage complete \
  --temporal-weight 0.15
```

## CLI Reference

```
python -m photosorter <input_dir> [options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `input_dir` | *(required)* | Directory containing photos |
| `--pooling` | `cls` | Embedding pooling: `cls` (semantic), `avg` (appearance), `cls+avg` (both) |
| `--distance-threshold` | `0.4` | Maximum inter-cluster distance for merging |
| `--linkage` | `average` | Cluster linkage: `average` (balanced), `complete` (strict), `single` (loose) |
| `--temporal-weight` | `0.0` | Weight for temporal (original order) penalty in distance matrix |
| `--device` | `auto` | Compute device: `auto`, `cpu`, or `mps` |
| `--batch-size` | `16` | Inference batch size |

## Image Preprocessing

Each image goes through the following pipeline before embedding extraction:

1. **EXIF orientation** — standard images (JPG, PNG, etc.) are auto-rotated via `ImageOps.exif_transpose`; RAW files have their EXIF Orientation tag read from the TIFF header and applied manually after decoding
2. **RAW decoding** — ARW, DNG, CR2, CR3, NEF, ORF, RAF, RW2 files are decoded via rawpy/LibRaw with `half_size=True` (demosaics at half resolution, ~4x memory savings) and camera white balance
3. **Pre-scaling** — images whose long edge exceeds 512 px are downsampled proportionally via Lanczos resampling before entering the transform pipeline, keeping memory usage low regardless of source resolution
4. **Transform** — `Resize(256)` → `CenterCrop(224)` → `ToTensor()` → `Normalize(ImageNet mean/std)`

Images that fail to load (corrupt files, unsupported formats) are skipped with a warning rather than aborting the entire pipeline.

## Output Format

A `manifest.json` is written into the input directory:

```json
{
  "version": 1,
  "input_dir": "/path/to/photos",
  "total": 440,
  "clusters": [
    {
      "cluster_id": 0,
      "count": 4,
      "photos": [
        {
          "position": 0,
          "original_index": 12,
          "filename": "DSC09604.jpg",
          "original_path": "/path/to/photos/DSC09604.jpg"
        }
      ]
    }
  ]
}
```

## Tuning Tips

| Problem | Solution |
|---------|----------|
| Too many clusters | Raise `--distance-threshold` (e.g. `0.5`) |
| Too few clusters | Lower `--distance-threshold` (e.g. `0.15`) |
| Clusters not pure enough (mixed scenes) | Use `--linkage complete` |
| Different locations with similar look merged | Add `--temporal-weight 0.2` |
| Want most discriminative features | Use `--pooling cls+avg` |

### Pooling strategies explained

| Strategy | What it captures | Cluster tendency |
|----------|-----------------|-----------------|
| `cls` | High-level semantics ("beach", "building") | Coarser — groups by scene type |
| `avg` | Visual appearance (colors, textures) | Finer — distinguishes sunset beach from noon beach |
| `cls+avg` | Both semantics and appearance | Finest — needs both to match for grouping |

### Temporal weight

At `--temporal-weight 0.0` (default), only visual similarity matters. Set to `0.1`–`0.3` to bias clusters toward consecutive runs of photos — useful when nearby photos in the original sequence are more likely to be from the same location. Values above `0.3` will dominate over visual similarity.

## Project Structure

```
photosorter/
├── __init__.py       # Package marker, version
├── __main__.py       # python -m photosorter entry point
├── config.py         # Default constants (frozen dataclass), model config
├── utils.py          # Logging, natural sort, image discovery
├── embeddings.py     # DINOv3 inference via timm, pooling, EXIF handling, RAW decoding, pre-scaling, L2 normalization
├── similarity.py     # Cosine similarity matrix → distance matrix, optional temporal penalty
├── clustering.py     # Agglomerative clustering (configurable linkage)
├── ordering.py       # Build ordered sequence from cluster labels
├── output.py         # Manifest JSON output
├── main.py           # CLI parser and pipeline orchestration
└── gui.py            # PySide6 cluster viewer (optional dependency)
pyproject.toml        # Package metadata and dependencies
```
