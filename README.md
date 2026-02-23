# PhotoSorter

PhotoSorter is a GUI-first macOS app for grouping and reordering travel photos by visual similarity.

The project is split into:
- SwiftUI desktop app: `apps/macos`
- Python core pipeline: `engine/photosorter_core`
- Python bridge (JSON Lines subprocess API): `engine/photosorter_bridge`

## Runtime Architecture (Current)

### App phases

`AppState.phase` has four phases:
1. `folderSelect`
2. `parameters`
3. `progress`
4. `results`

### Folder selection behavior

When a folder is selected, Swift currently checks `<input_dir>/PhotoSorter_Cache/manifest.json`:
- If manifest exists and decodes: jump to `results` and hydrate parameter UI from manifest.
- If manifest exists but is invalid: show warning and go to `parameters`.
- If manifest is missing: go to `parameters`.

### Pipeline execution behavior

From the progress page, Swift launches:

```bash
python -m photosorter_bridge.cli_json run ...
```

Bridge stdout streams one JSON object per line (`progress`, `complete`, `error`).
Swift updates step UI in real time.

Shared step identifiers (Swift/Python):
- `discover`
- `model`
- `embed`
- `similarity`
- `cluster`
- `output`

### Core pipeline order

1. Discover images in selected folder (top-level only, non-recursive), natural-sort by filename.
2. Detect device (`auto` prefers MPS, else CPU).
3. Load DINOv3 model from `timm` (`vit_huge_plus_patch16_dinov3.lvd1689m`).
4. Extract and L2-normalize embeddings (skip unreadable files with warning).
5. Build cosine similarity matrix; convert to distance matrix; optionally add temporal penalty.
6. Run agglomerative clustering (`metric=precomputed`, configurable linkage + threshold).
7. Build ordered sequence (cluster order by earliest original index; keep original order inside each cluster).
8. Write `manifest.json` under the cache directory (`<input_dir>/PhotoSorter_Cache/`).

### Output artifact

Primary artifact: `<input_dir>/PhotoSorter_Cache/manifest.json`

Related cache artifacts under `<input_dir>/PhotoSorter_Cache/`:
- `GridThumb/` (grid thumbnails)
- `DetailProxy/` (detail/Quick Look proxies)

Includes:
- global metadata (`version`, `input_dir`, `total`)
- run parameters (`distance_threshold`, `temporal_weight`, `linkage`, `pooling`, `preprocess`, `batch_size`, `device`)
- clustered photo list (`cluster_id`, `count`, `photos[]`)

Important:
- Core pipeline does not rename/move/copy photos.
- The GUI "mark checked" action renames files by toggling `CHECK_` prefix and persists back to the cache manifest (`PhotoSorter_Cache/manifest.json`).

## Supported Input Formats

Standard images:
- `.jpg`, `.jpeg`, `.png`, `.tiff`, `.tif`, `.bmp`, `.webp`

RAW images:
- `.arw`, `.dng`, `.cr2`, `.cr3`, `.nef`, `.orf`, `.raf`, `.rw2`

## Default Parameters

- `device`: `auto` (`auto`, `mps`, `cpu`)
- `batch_size`: `16` (min `1`)
- `pooling`: `avg` (`cls`, `avg`, `cls+avg`) — matches the timm model's default global pool
- `preprocess`: `letterbox` (`letterbox`, `timm`)
- `distance_threshold`: `0.2` (`> 0`)
- `linkage`: `complete` (`average`, `complete`, `single`)
- `temporal_weight`: `0.0` (`>= 0`)

## Image Preprocessing

For each image:
1. EXIF orientation handling.
2. RAW decode via `rawpy` (RAW only, `half_size=True`).
3. Pre-scale long edge to 512 when needed.
4. Default (`preprocess=letterbox`): aspect-preserving resize + center pad to `256x256`, then `ToTensor() -> ImageNet normalize`.
5. Optional A/B mode (`preprocess=timm`): strict timm pretrained transform `Resize(256) -> CenterCrop(256) -> ToTensor() -> ImageNet normalize`.

## Bridge Message Contract (JSON Lines)

Bridge emits one JSON object per line:
- `progress`: `{type, step, detail, processed, total}`
- `complete`: `{type, manifest_path}`
- `error`: `{type, message}`

Schemas:
- `contracts/pipeline_parameters.schema.json`
- `contracts/pipeline_message.schema.json`

## Requirements

- macOS 26+ (Swift package currently sets `.macOS(.v26)`)
- Python 3.10+
- Xcode command line tools

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[test]"
```

Model packaging is handled by `scripts/package_macos_app.sh`:
- it resolves `model.safetensors` from `timm/vit_huge_plus_patch16_dinov3.lvd1689m` (or `--model-path`)
- it bundles the file into `PhotoSorter.app/Contents/Resources/models/`
- runtime then loads only this local checkpoint (offline mode), without Hugging Face requests

## Run

### GUI (primary path)

```bash
swift run --package-path apps/macos PhotoSorterApp
```

### Build app bundle

```bash
./scripts/package_macos_app.sh
open "./dist/PhotoSorter.app"
```

Packaging notes:
- Builds release executable and creates `dist/PhotoSorter.app`.
- Copies `engine/` into app resources.
- Bundles a Python runtime and Python dependencies into app resources by default.
- Bundles the DINOv3 checkpoint into app resources (`Contents/Resources/models/`).
- Use `--skip-python-runtime` only for local development smoke tests.
- Bundled launcher resolves Python in this order:
1. `PHOTOSORTER_PYTHON`
2. bundled runtime at `Contents/Resources/python-runtime`
3. nearest `.venv/bin/python` found by walking upward from bundle location
4. `/usr/bin/python3`
5. `python3` in `PATH`

Model options:

```bash
./scripts/package_macos_app.sh --model-path /absolute/path/to/model.safetensors
```

If `--model-path` is omitted, packaging pulls from Hugging Face once (or cache) and embeds it.

### Distribution signing & notarization

Developer ID signing:

```bash
./scripts/package_macos_app.sh \
  --sign-identity "Developer ID Application: YOUR NAME (TEAMID)"
```

Developer ID + notarization:

```bash
./scripts/package_macos_app.sh \
  --sign-identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --notarize-profile "AC_NOTARY_PROFILE"
```

`--notarize-profile` maps to `xcrun notarytool --keychain-profile`.

### Core CLI

```bash
photosorter /path/to/photos
```

or:

```bash
python -m photosorter /path/to/photos
```

Example A/B preprocessing runs:

```bash
photosorter /path/to/photos --preprocess letterbox
photosorter /path/to/photos --preprocess timm
```

### Bridge CLI

```bash
photosorter-json run --input-dir /path/to/photos
```

or:

```bash
python -m photosorter_bridge.cli_json run --input-dir /path/to/photos
```

## Tests

Python:

```bash
./.venv/bin/pytest
```

Coverage report:

```bash
./.venv/bin/pytest --cov=photosorter --cov=photosorter_bridge --cov-report=term-missing
```

Swift GUI logic checks:

```bash
swift run --package-path apps/macos PhotoSorterAppGUITests
```

## Project Layout

```text
apps/
└── macos/
    ├── Package.swift
    └── Sources/
        ├── PhotoSorterApp/          # SwiftUI UI/state/services/models
        ├── PhotoSorterAppMain/      # @main executable
        └── PhotoSorterAppGUITests/  # GUI logic test executable

engine/
├── photosorter_core/
│   └── photosorter/                 # Core pipeline + CLI
└── photosorter_bridge/
    └── photosorter_bridge/          # JSON-lines bridge layer

contracts/
├── pipeline_message.schema.json
└── pipeline_parameters.schema.json

tests/
└── python/
```
