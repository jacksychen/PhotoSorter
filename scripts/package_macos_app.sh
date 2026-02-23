#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="${ROOT_DIR}/apps/macos"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="Photo Sorter"
EXECUTABLE_NAME="PhotoSorterApp"
BUNDLE_ID="com.photosorter.app"
APP_BUNDLE_PATH="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
APP_ICON_NAME="PhotoSorter"
APP_ICON_SOURCE_PATH="${PACKAGE_PATH}/Resources/${APP_ICON_NAME}.icns"
APP_ICON_BUNDLE_PATH="${RESOURCES_DIR}/${APP_ICON_NAME}.icns"
PY_RUNTIME_DIR="${RESOURCES_DIR}/python-runtime"
PY_SITE_PACKAGES_DIR="${RESOURCES_DIR}/python-site-packages"
MODEL_DIR="${RESOURCES_DIR}/models"
MODEL_BUNDLE_FILENAME="vit_huge_plus_patch16_dinov3.lvd1689m.safetensors"
MODEL_BUNDLE_PATH="${MODEL_DIR}/${MODEL_BUNDLE_FILENAME}"
MODEL_REPO_ID="${PHOTOSORTER_MODEL_REPO_ID:-timm/vit_huge_plus_patch16_dinov3.lvd1689m}"
MODEL_FILENAME="${PHOTOSORTER_MODEL_FILENAME:-model.safetensors}"
MODEL_SOURCE_PATH="${PHOTOSORTER_MODEL_PATH:-}"

APP_VERSION="${PHOTOSORTER_APP_VERSION:-1.0.0}"
APP_BUILD="${PHOTOSORTER_APP_BUILD:-1}"

BUNDLE_PYTHON_RUNTIME=true
BUILD_PYTHON="${PHOTOSORTER_BUILD_PYTHON:-}"
SIGN_IDENTITY="${PHOTOSORTER_SIGN_IDENTITY:--}"
NOTARIZE_PROFILE="${PHOTOSORTER_NOTARIZE_PROFILE:-}"

usage() {
  cat <<USAGE
Usage: ./scripts/package_macos_app.sh [options]

Options:
  --build-python <path>       Python used to bundle runtime/dependencies.
  --model-path <path>         Local model checkpoint path (preferred over HF cache/download).
  --skip-python-runtime       Skip bundling runtime/dependencies (development only).
  --sign-identity <identity>  codesign identity. Default is ad-hoc "-".
  --notarize-profile <name>   notarytool keychain profile name (requires non ad-hoc signing).
  -h, --help                  Show this help.

Environment overrides:
  PHOTOSORTER_BUILD_PYTHON
  PHOTOSORTER_MODEL_PATH
  PHOTOSORTER_MODEL_REPO_ID
  PHOTOSORTER_MODEL_FILENAME
  PHOTOSORTER_SIGN_IDENTITY
  PHOTOSORTER_NOTARIZE_PROFILE
  PHOTOSORTER_APP_VERSION
  PHOTOSORTER_APP_BUILD
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-python)
      BUILD_PYTHON="${2:-}"
      shift 2
      ;;
    --model-path)
      MODEL_SOURCE_PATH="${2:-}"
      shift 2
      ;;
    --skip-python-runtime)
      BUNDLE_PYTHON_RUNTIME=false
      shift
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --notarize-profile)
      NOTARIZE_PROFILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "${NOTARIZE_PROFILE}" && "${SIGN_IDENTITY}" == "-" ]]; then
  echo "error: --notarize-profile requires a real Developer ID identity (not ad-hoc '-')" >&2
  exit 1
fi

if [[ ! -d "${PACKAGE_PATH}" ]]; then
  echo "error: package path not found: ${PACKAGE_PATH}" >&2
  exit 1
fi

if [[ ! -d "${ROOT_DIR}/engine" ]]; then
  echo "error: engine directory not found at ${ROOT_DIR}/engine" >&2
  exit 1
fi

resolve_build_python() {
  if [[ -n "${BUILD_PYTHON}" ]]; then
    if [[ ! -x "${BUILD_PYTHON}" ]]; then
      echo "error: build python is not executable: ${BUILD_PYTHON}" >&2
      exit 1
    fi
    return
  fi

  if [[ -x "${ROOT_DIR}/.venv/bin/python" ]]; then
    BUILD_PYTHON="${ROOT_DIR}/.venv/bin/python"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    BUILD_PYTHON="$(command -v python3)"
    return
  fi

  echo "error: could not find a build python. Use --build-python." >&2
  exit 1
}

bundle_python_runtime() {
  local py_base_prefix py_site_packages py_mm

  resolve_build_python

  py_base_prefix="$("${BUILD_PYTHON}" -c 'import sys; print(sys.base_prefix)')"
  py_site_packages="$("${BUILD_PYTHON}" -c 'import site; print(site.getsitepackages()[0])')"
  py_mm="$("${BUILD_PYTHON}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

  if [[ ! -d "${py_base_prefix}" ]]; then
    echo "error: python base_prefix does not exist: ${py_base_prefix}" >&2
    exit 1
  fi

  if [[ ! -d "${py_site_packages}" ]]; then
    echo "error: python site-packages does not exist: ${py_site_packages}" >&2
    exit 1
  fi

  echo "Bundling Python runtime from: ${py_base_prefix}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${py_base_prefix}/" "${PY_RUNTIME_DIR}/"
  else
    rm -rf "${PY_RUNTIME_DIR}"
    cp -R "${py_base_prefix}" "${PY_RUNTIME_DIR}"
  fi

  mkdir -p "${PY_SITE_PACKAGES_DIR}"
  echo "Bundling Python dependencies from: ${py_site_packages}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --delete \
      --exclude "__pycache__/" \
      --exclude "*.pyc" \
      --exclude "__editable__.*" \
      --exclude "*.egg-link" \
      "${py_site_packages}/" "${PY_SITE_PACKAGES_DIR}/"
  else
    rm -rf "${PY_SITE_PACKAGES_DIR}"
    cp -R "${py_site_packages}" "${PY_SITE_PACKAGES_DIR}"
    find "${PY_SITE_PACKAGES_DIR}" -type d -name "__pycache__" -prune -exec rm -rf {} +
    find "${PY_SITE_PACKAGES_DIR}" -type f -name "*.pyc" -delete
    find "${PY_SITE_PACKAGES_DIR}" -maxdepth 1 -type f -name "__editable__.*" -delete
    find "${PY_SITE_PACKAGES_DIR}" -maxdepth 1 -type f -name "*.egg-link" -delete
  fi

  # Ensure a predictable python3 path exists for the launcher.
  if [[ -x "${PY_RUNTIME_DIR}/bin/python3" ]]; then
    :
  elif [[ -x "${PY_RUNTIME_DIR}/bin/python${py_mm}" ]]; then
    ln -sf "python${py_mm}" "${PY_RUNTIME_DIR}/bin/python3"
  elif [[ -x "${PY_RUNTIME_DIR}/bin/python" ]]; then
    ln -sf "python" "${PY_RUNTIME_DIR}/bin/python3"
  else
    echo "error: could not find bundled Python executable under ${PY_RUNTIME_DIR}/bin" >&2
    exit 1
  fi

  # Homebrew Python ships lib/pythonX.Y/site-packages as a symlink that points
  # outside the app bundle. Replace it with an internal empty directory so the
  # bundle does not depend on external paths.
  rm -rf "${PY_RUNTIME_DIR}/lib/python${py_mm}/site-packages"
  mkdir -p "${PY_RUNTIME_DIR}/lib/python${py_mm}/site-packages"
}

prune_site_packages() {
  # Remove build/test tooling that is not needed in production app runtime.
  local removable=(
    "_pytest"
    "pytest"
    "pytest-*.dist-info"
    "iniconfig"
    "iniconfig-*.dist-info"
    "pluggy"
    "pluggy-*.dist-info"
    "coverage"
    "coverage-*.dist-info"
    "pytest_cov"
    "pytest_cov-*.dist-info"
    "pip"
    "pip-*.dist-info"
    "setuptools"
    "setuptools-*.dist-info"
    "pkg_resources"
  )

  for pattern in "${removable[@]}"; do
    find "${PY_SITE_PACKAGES_DIR}" -maxdepth 1 -name "${pattern}" -prune -exec rm -rf {} +
  done
}

resolve_model_source() {
  resolve_build_python

  if [[ -n "${MODEL_SOURCE_PATH}" ]]; then
    if [[ ! -f "${MODEL_SOURCE_PATH}" ]]; then
      echo "error: --model-path does not exist: ${MODEL_SOURCE_PATH}" >&2
      exit 1
    fi
    echo "${MODEL_SOURCE_PATH}"
    return
  fi

  local downloaded_model
  downloaded_model="$("${BUILD_PYTHON}" - <<PY
from huggingface_hub import hf_hub_download
print(hf_hub_download(repo_id='${MODEL_REPO_ID}', filename='${MODEL_FILENAME}'))
PY
)"

  downloaded_model="${downloaded_model//$'\r'/}"
  downloaded_model="${downloaded_model//$'\n'/}"

  if [[ -z "${downloaded_model}" || ! -f "${downloaded_model}" ]]; then
    echo "error: failed to resolve model checkpoint from HF repo '${MODEL_REPO_ID}' (file '${MODEL_FILENAME}')" >&2
    exit 1
  fi

  echo "${downloaded_model}"
}

bundle_model_checkpoint() {
  local model_source

  model_source="$(resolve_model_source)"
  mkdir -p "${MODEL_DIR}"

  echo "Bundling model checkpoint from: ${model_source}"
  cp -f "${model_source}" "${MODEL_BUNDLE_PATH}"
  chmod 644 "${MODEL_BUNDLE_PATH}"
}

write_launcher() {
  cat > "${RESOURCES_DIR}/photosorter-cli" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_dir="${script_dir}/python-runtime"
site_dir="${script_dir}/python-site-packages"
engine_bridge_dir="${script_dir}/engine/photosorter_bridge"
engine_core_dir="${script_dir}/engine/photosorter_core"
model_checkpoint="${script_dir}/models/vit_huge_plus_patch16_dinov3.lvd1689m.safetensors"

if [[ -f "${model_checkpoint}" ]]; then
  export PHOTOSORTER_MODEL_CHECKPOINT="${model_checkpoint}"
  export PHOTOSORTER_DISABLE_REMOTE_MODEL=1
  export HF_HUB_OFFLINE=1
fi

if [[ -n "${PHOTOSORTER_PYTHON:-}" ]]; then
  exec "${PHOTOSORTER_PYTHON}" "$@"
fi

augment_pythonpath() {
  local extra_path="$1"
  if [[ -z "${extra_path}" ]]; then
    return
  fi
  if [[ -n "${PYTHONPATH:-}" ]]; then
    export PYTHONPATH="${extra_path}:${PYTHONPATH}"
  else
    export PYTHONPATH="${extra_path}"
  fi
}

pick_runtime_python() {
  local root="$1"
  local candidate

  if [[ -x "${root}/bin/python3" ]]; then
    echo "${root}/bin/python3"
    return 0
  fi

  for candidate in "${root}"/bin/python3.* "${root}"/bin/python3 "${root}"/bin/python; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  return 1
}

if [[ -d "${runtime_dir}" ]]; then
  if runtime_python="$(pick_runtime_python "${runtime_dir}")"; then
    export PYTHONHOME="${runtime_dir}"
    export PYTHONNOUSERSITE=1

    if [[ -d "${engine_bridge_dir}" && -d "${engine_core_dir}" ]]; then
      augment_pythonpath "${engine_bridge_dir}:${engine_core_dir}"
    fi

    if [[ -d "${site_dir}" ]]; then
      augment_pythonpath "${site_dir}"
    fi

    exec "${runtime_python}" "$@"
  fi
fi

candidate="${script_dir}"

for _ in {1..12}; do
  if [[ -x "${candidate}/.venv/bin/python" ]]; then
    exec "${candidate}/.venv/bin/python" "$@"
  fi
  parent="$(dirname "${candidate}")"
  if [[ "${parent}" == "${candidate}" ]]; then
    break
  fi
  candidate="${parent}"
done

if [[ -x "/usr/bin/python3" ]]; then
  exec "/usr/bin/python3" "$@"
fi

exec python3 "$@"
WRAPPER
  chmod +x "${RESOURCES_DIR}/photosorter-cli"
}

verify_bundle_resources() {
  local missing=0

  local required_files=(
    "${RESOURCES_DIR}/photosorter-cli"
    "${APP_ICON_BUNDLE_PATH}"
    "${RESOURCES_DIR}/engine/photosorter_core/photosorter/__init__.py"
    "${RESOURCES_DIR}/engine/photosorter_bridge/photosorter_bridge/cli_json.py"
    "${MODEL_BUNDLE_PATH}"
  )

  if [[ "${BUNDLE_PYTHON_RUNTIME}" == true ]]; then
    required_files+=("${PY_RUNTIME_DIR}/bin/python3")
    required_files+=("${PY_SITE_PACKAGES_DIR}/torch")
  fi

  for required_file in "${required_files[@]}"; do
    if [[ ! -e "${required_file}" ]]; then
      echo "error: missing required bundled resource: ${required_file}" >&2
      missing=1
    fi
  done

  if [[ ${missing} -ne 0 ]]; then
    exit 1
  fi

  echo "Checking bundle symlinks stay inside .app..."
  python3 - <<PY
from pathlib import Path
import sys

app = Path("${APP_BUNDLE_PATH}").resolve()
outside = []
for path in app.rglob("*"):
    if not path.is_symlink():
        continue
    target = path.readlink()
    resolved = (path.parent / target).resolve() if not target.is_absolute() else target
    try:
        resolved.relative_to(app)
    except Exception:
        outside.append((path, target, resolved))

if outside:
    print("error: bundle contains symlinks that resolve outside the app bundle:", file=sys.stderr)
    for path, target, resolved in outside:
        print(f"  {path} -> {target} (resolved: {resolved})", file=sys.stderr)
    raise SystemExit(1)
PY

  if [[ "${BUNDLE_PYTHON_RUNTIME}" == true ]]; then
    echo "Verifying bundled runtime can import core modules without external paths..."
    "${RESOURCES_DIR}/photosorter-cli" - <<'PY'
import os
import pathlib
import sys

checkpoint = os.environ.get("PHOTOSORTER_MODEL_CHECKPOINT")
if not checkpoint:
    raise SystemExit("PHOTOSORTER_MODEL_CHECKPOINT is not set by launcher")
if not pathlib.Path(checkpoint).is_file():
    raise SystemExit(f"Bundled checkpoint missing: {checkpoint}")

if os.environ.get("PHOTOSORTER_DISABLE_REMOTE_MODEL") not in {"1", "true", "True"}:
    raise SystemExit("PHOTOSORTER_DISABLE_REMOTE_MODEL is not enabled")
if os.environ.get("HF_HUB_OFFLINE") not in {"1", "true", "True"}:
    raise SystemExit("HF_HUB_OFFLINE is not enabled")

import photosorter  # noqa: F401
import photosorter_bridge  # noqa: F401
import rawpy  # noqa: F401
import timm  # noqa: F401
import torch  # noqa: F401

print("bundle_verify_ok")
print(f"python_executable={sys.executable}")
print(f"model_checkpoint={checkpoint}")
PY
  else
    echo "warning: skipped runtime import verification because --skip-python-runtime was used" >&2
  fi
}

sign_app() {
  if ! command -v codesign >/dev/null 2>&1; then
    echo "warning: codesign not found; skipping signing" >&2
    return
  fi

  echo "Signing app bundle with identity: ${SIGN_IDENTITY}"
  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign - "${APP_BUNDLE_PATH}" >/dev/null
  else
    codesign \
      --force \
      --deep \
      --options runtime \
      --timestamp \
      --sign "${SIGN_IDENTITY}" \
      "${APP_BUNDLE_PATH}" >/dev/null
  fi
}

notarize_app() {
  if [[ -z "${NOTARIZE_PROFILE}" ]]; then
    return
  fi

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun not found; cannot notarize" >&2
    exit 1
  fi

  local zip_path="${DIST_DIR}/${APP_NAME}.zip"

  echo "Creating notarization archive: ${zip_path}"
  rm -f "${zip_path}"
  ditto -c -k --keepParent "${APP_BUNDLE_PATH}" "${zip_path}"

  echo "Submitting for notarization using profile: ${NOTARIZE_PROFILE}"
  xcrun notarytool submit "${zip_path}" --keychain-profile "${NOTARIZE_PROFILE}" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "${APP_BUNDLE_PATH}"
  xcrun stapler validate "${APP_BUNDLE_PATH}"
}

echo "Building ${EXECUTABLE_NAME} (release)..."
swift build --package-path "${PACKAGE_PATH}" -c release --product "${EXECUTABLE_NAME}"

BIN_DIR="$(swift build --package-path "${PACKAGE_PATH}" -c release --show-bin-path)"
BIN_PATH="${BIN_DIR}/${EXECUTABLE_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "error: built executable not found: ${BIN_PATH}" >&2
  exit 1
fi

echo "Creating app bundle at ${APP_BUNDLE_PATH}..."
rm -rf "${APP_BUNDLE_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

if [[ ! -f "${APP_ICON_SOURCE_PATH}" ]]; then
  echo "error: app icon not found: ${APP_ICON_SOURCE_PATH}" >&2
  echo "hint: run python3 scripts/generate_app_icon.py" >&2
  exit 1
fi
cp -f "${APP_ICON_SOURCE_PATH}" "${APP_ICON_BUNDLE_PATH}"
chmod 644 "${APP_ICON_BUNDLE_PATH}"

if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --delete \
    --exclude "__pycache__/" \
    --exclude "*.pyc" \
    "${ROOT_DIR}/engine/" "${RESOURCES_DIR}/engine/"
else
  cp -R "${ROOT_DIR}/engine" "${RESOURCES_DIR}/engine"
  find "${RESOURCES_DIR}/engine" -type d -name "__pycache__" -prune -exec rm -rf {} +
  find "${RESOURCES_DIR}/engine" -type f -name "*.pyc" -delete
fi

if [[ "${BUNDLE_PYTHON_RUNTIME}" == true ]]; then
  bundle_python_runtime
  prune_site_packages
else
  echo "Skipping bundled Python runtime (--skip-python-runtime)."
fi

bundle_model_checkpoint
write_launcher
verify_bundle_resources

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>${APP_ICON_NAME}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_app
notarize_app

echo "Done: ${APP_BUNDLE_PATH}"
echo "Launch: open \"${APP_BUNDLE_PATH}\""
if [[ -n "${NOTARIZE_PROFILE}" ]]; then
  echo "Notarized archive: ${DIST_DIR}/${APP_NAME}.zip"
fi
