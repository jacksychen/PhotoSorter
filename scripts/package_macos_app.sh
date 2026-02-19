#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="${ROOT_DIR}/apps/macos"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="PhotoSorter"
EXECUTABLE_NAME="PhotoSorterApp"
BUNDLE_ID="com.photosorter.app"
APP_BUNDLE_PATH="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

if [[ ! -d "${PACKAGE_PATH}" ]]; then
  echo "error: package path not found: ${PACKAGE_PATH}" >&2
  exit 1
fi

if [[ ! -d "${ROOT_DIR}/engine" ]]; then
  echo "error: engine directory not found at ${ROOT_DIR}/engine" >&2
  exit 1
fi

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

cat > "${RESOURCES_DIR}/photosorter-cli" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${PHOTOSORTER_PYTHON:-}" ]]; then
  exec "${PHOTOSORTER_PYTHON}" "$@"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "${APP_BUNDLE_PATH}" >/dev/null
fi

echo "Done: ${APP_BUNDLE_PATH}"
echo "Launch: open \"${APP_BUNDLE_PATH}\""
