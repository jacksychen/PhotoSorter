# PhotoSorter

PhotoSorter is a GUI-first macOS app for grouping and reordering travel photos by visual similarity.

The product is split across:
- SwiftUI desktop app (`apps/macos`) for UX/state/rendering
- Python core pipeline (`engine/photosorter_core`) for model inference + clustering
- Python bridge (`engine/photosorter_bridge`) for JSON-lines subprocess communication

## Current Runtime Architecture

### 1) App state machine (SwiftUI)

The app uses four phases (`AppState.phase`):
1. `folderSelect`
2. `parameters`
3. `progress`
4. `results`

Current behavior when selecting a folder:
- App first calls bridge `check-manifest` to detect whether a prior `manifest.json` exists.
- If `manifest.json` exists and can be decoded, app jumps directly to `results` and back-fills parameter UI from the manifest.
- If `manifest.json` exists but is invalid, app records an error message and proceeds to `parameters`.
- If no manifest exists, app proceeds to `parameters`.

### 2) Pipeline execution model

From the progress page, Swift launches:

```bash
python -m photosorter_bridge.cli_json run ...
```

The bridge streams JSON lines to stdout (`progress`, `complete`, `error`), and Swift updates UI step states in real time.

Pipeline step identifiers are shared by Swift and Python:
- `discover`
- `model`
- `embed`
- `similarity`
- `cluster`
- `output`

### 3) Python pipeline logic (actual order)

The core pipeline (`photosorter.main.run_pipeline` / bridge runner) is:
1. Discover images in the selected folder (top-level only, non-recursive), natural-sort by filename.
2. Detect device (`auto` prefers MPS, else CPU).
3. Load DINOv3 model via `timm` (`vit_huge_plus_patch16_dinov3.lvd1689m`).
4. Extract and L2-normalize embeddings (with unreadable-file skipping).
5. Build cosine similarity matrix, convert to distance matrix, optionally add temporal penalty.
6. Run agglomerative clustering (`metric=precomputed`, configurable linkage + threshold).
7. Build final ordered sequence (cluster order by earliest original index; preserve in-cluster original order).
8. Write `manifest.json` to the input folder.

### 4) Output contract

Primary artifact is `<input_dir>/manifest.json`, including:
- global metadata (`version`, `input_dir`, `total`)
- run parameters (`distance_threshold`, `temporal_weight`, `linkage`, `pooling`, `batch_size`, `device`)
- clustered ordered photo list (`cluster_id`, `count`, `photos[]`)

Minimal structure:

```json
{
  "version": 1,
  "input_dir": "/path/to/photos",
  "total": 123,
  "parameters": {},
  "clusters": [
    {
      "cluster_id": 0,
      "count": 10,
      "photos": [
        {
          "position": 0,
          "original_index": 5,
          "filename": "IMG_0001.JPG",
          "original_path": "/path/to/photos/IMG_0001.JPG"
        }
      ]
    }
  ]
}
```

Important: current pipeline does **not** rename/move/copy photo files. It only writes the manifest used by the app UI.

## Supported Input Formats

Standard images:
- `.jpg`, `.jpeg`, `.png`, `.tiff`, `.tif`, `.bmp`, `.webp`

RAW images:
- `.arw`, `.dng`, `.cr2`, `.cr3`, `.nef`, `.orf`, `.raf`, `.rw2`

## Parameters (Current Defaults)

- `device`: `auto` (choices: `auto`, `mps`, `cpu`)
- `batch_size`: `16` (min `1`)
- `pooling`: `cls` (choices: `cls`, `avg`, `cls+avg`)
- `distance_threshold`: `0.4` (must be `> 0`)
- `linkage`: `average` (choices: `average`, `complete`, `single`)
- `temporal_weight`: `0.0` (must be `>= 0`)

## Image Preprocessing Details

Before feature extraction, each image goes through:
1. EXIF orientation handling.
2. RAW decode via `rawpy` (for RAW formats, demosaic with `half_size=True`).
3. Pre-scale for large inputs (`prescale_size=512` long edge).
4. Transform pipeline: `Resize(256)` -> `CenterCrop(224)` -> `ToTensor()` -> ImageNet normalization.

Unreadable files are skipped with warnings instead of failing the whole run.

## Bridge Message Contract (JSON Lines)

Bridge stdout emits one JSON object per line:
- `progress`: `{type, step, detail, processed, total}`
- `complete`: `{type, manifest_path}`
- `error`: `{type, message}`
- `manifest`: `{type, exists, path?}` (for `check-manifest`)

See canonical schema definitions in `contracts/`.

## Requirements

- macOS 14+
- Python 3.10+
- Xcode command line tools (for `swift`)

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[test]"
```

First model load downloads DINOv3 weights via `timm` (large one-time download).

## Run

### 1) GUI (primary path)

```bash
swift run --package-path apps/macos PhotoSorterApp
```

### 2) Build a double-clickable `.app`

```bash
./scripts/package_macos_app.sh
open "./dist/PhotoSorter.app"
```

Notes:
- The script builds a Release binary, wraps it into `dist/PhotoSorter.app`, and embeds `engine/` resources.
- Runtime still needs Python + dependencies (`timm`, `torch`, etc.). By default, the bundled launcher will try:
  1. `PHOTOSORTER_PYTHON` (if set)
  2. nearest `.venv/bin/python` found by walking upward from the app bundle
  3. `/usr/bin/python3`
  4. `python3` in `PATH`

### 3) Core CLI

```bash
photosorter /path/to/photos
```

or:

```bash
python -m photosorter /path/to/photos
```

### 4) JSON bridge CLI

```bash
photosorter-json run --input-dir /path/to/photos
photosorter-json check-manifest --input-dir /path/to/photos
```

or module form:

```bash
python -m photosorter_bridge.cli_json run --input-dir /path/to/photos
python -m photosorter_bridge.cli_json check-manifest --input-dir /path/to/photos
```

`check-manifest` is used by folder selection to decide whether to resume from an existing manifest.

## Tests

Python:

```bash
pytest
```

Swift GUI logic checks:

```bash
swift run --package-path apps/macos PhotoSorterAppGUITests
```

## Contracts

- `contracts/pipeline_parameters.schema.json`
- `contracts/pipeline_message.schema.json`

These JSON Schemas define the Swift↔Python bridge interface.

## Project Layout

```text
apps/
└── macos/
    ├── Package.swift
    └── Sources/
        ├── PhotoSorterApp/          # SwiftUI UI/state/services/models
        ├── PhotoSorterAppMain/      # @main application target
        └── PhotoSorterAppGUITests/  # Swift executable test target

engine/
├── photosorter_core/
│   └── photosorter/                 # Core pipeline + CLI
│       ├── __main__.py
│       ├── main.py
│       ├── embeddings.py
│       ├── similarity.py
│       ├── clustering.py
│       ├── ordering.py
│       ├── pipeline.py
│       └── output.py
└── photosorter_bridge/
    └── photosorter_bridge/          # JSON-lines bridge for subprocess integration
        ├── cli_json.py
        └── pipeline_runner.py

contracts/
├── pipeline_message.schema.json
└── pipeline_parameters.schema.json

tests/
└── python/
```
