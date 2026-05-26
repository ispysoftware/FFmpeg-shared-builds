#!/bin/bash
# =============================================================================
# notarize_macos.sh — Sign and notarize pre-built FFmpeg macOS zips
#
# Works with output from build_macos.sh (zips already contain bin/ and lib/
# with correct rpath install names).  This script adds the @loader_path rpath
# needed for .NET / FFmpeg.AutoGen, signs everything, and submits to Apple.
#
# Prerequisites:
#   - Xcode command-line tools (codesign, xcrun notarytool)
#   - Developer ID Application certificate in your keychain
#   - sign_pwd.txt in the same directory as this script containing your
#     Apple app-specific password (generate at appleid.apple.com)
#     NEVER commit sign_pwd.txt to git — it is in .gitignore.
#
# Usage:
#   ./notarize_macos.sh                   # notarize all zips in out/
#   ./notarize_macos.sh 8.1               # notarize all zips for version 8.1
#   ./notarize_macos.sh 8.1 arm64         # notarize just arm64
# =============================================================================
set -e

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"

# Credentials are kept outside the repo in notarize_config.sh (gitignored).
# Copy notarize_config.sh.example to notarize_config.sh and fill it in.
CONFIG_FILE="${SCRIPT_DIR}/notarize_config.sh"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: ${CONFIG_FILE} not found."
    echo "Copy notarize_config.sh.example to notarize_config.sh and fill in your credentials."
    exit 1
fi
# shellcheck source=notarize_config.sh.example
# Strip Windows CRLF line endings before sourcing (in case edited on Windows)
sed -i '' 's/\r//' "${CONFIG_FILE}"
source "${CONFIG_FILE}"

# App-specific password — read from sign_pwd.txt, never hardcoded.
SIGN_PWD_FILE="${SCRIPT_DIR}/sign_pwd.txt"
if [ ! -f "${SIGN_PWD_FILE}" ]; then
    echo "ERROR: ${SIGN_PWD_FILE} not found."
    echo "Create it containing your app-specific password from appleid.apple.com."
    exit 1
fi
APP_PASSWORD="$(cat "${SIGN_PWD_FILE}" | tr -d '[:space:]')"

# --- Arguments ---
VERSION="${1:-}"
ARCH_FILTER="${2:-}"  # optional: arm64 or x86_64

read -p "Please enter the FFmpeg version to notarize [default: 8.1]: " INPUT_VER
VERSION="${INPUT_VER:-${VERSION:-8.1}}"
if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Invalid FFmpeg version."
    exit 1
fi
echo "✅ Version: ${VERSION}"
echo

OUT_DIR="${SCRIPT_DIR}/out"

# Build list of zips to process
ZIPS=()
for arch in arm64 x86_64; do
    [ -n "${ARCH_FILTER}" ] && [ "${arch}" != "${ARCH_FILTER}" ] && continue
    ZIP="${OUT_DIR}/ffmpeg${VERSION}-macos-${arch}.zip"
    if [ -f "${ZIP}" ]; then
        ZIPS+=("${ZIP}")
    else
        echo "⚠️  Not found, skipping: ${ZIP}"
    fi
done

if [ ${#ZIPS[@]} -eq 0 ]; then
    echo "ERROR: No matching zips found in ${OUT_DIR}/"
    echo "Run build_macos.sh first, or check the version number."
    exit 1
fi

# --- Process each zip ---
for INPUT_ZIP in "${ZIPS[@]}"; do
    BASENAME="$(basename "${INPUT_ZIP}" .zip)"
    echo "================================================="
    echo " Processing: ${BASENAME}"
    echo "================================================="

    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${WORK_DIR}"' EXIT

    echo "📦 Unpacking..."
    unzip -q "${INPUT_ZIP}" -d "${WORK_DIR}"

    BIN_DIR="${WORK_DIR}/bin"
    LIB_DIR="${WORK_DIR}/lib"

    # --- Add @loader_path rpath to dylibs ---
    # When FFmpeg.AutoGen (or any dlopen caller) loads a dylib, that dylib
    # must be able to find its own sibling dylibs.  @loader_path resolves
    # relative to the directory containing the dylib being loaded.
    echo "⚙️  Adding @loader_path rpath to dylibs..."
    for file in "${LIB_DIR}"/*.dylib; do
        [ -L "$file" ] && continue  # skip symlinks
        install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
    done

    # --- Sign ---
    echo "✍️  Signing with Developer ID (Hardened Runtime)..."
    for file in "${LIB_DIR}"/*.dylib "${BIN_DIR}"/*; do
        [ -L "$file" ] && continue  # skip symlinks
        [ -f "$file" ] || continue
        echo "    $(basename "${file}")"
        codesign --force \
                 --sign "${DEVELOPER_ID}" \
                 --options runtime \
                 --timestamp \
                 "$file"
    done
    echo "✅ Signed."

    # --- Repack ---
    SIGNED_ZIP="${OUT_DIR}/${BASENAME}-notarized.zip"
    echo "📦 Repacking → $(basename "${SIGNED_ZIP}")..."
    (cd "${WORK_DIR}" && zip -r -y -q -X "${SIGNED_ZIP}" bin lib -x "*.DS_Store")

    rm -rf "${WORK_DIR}"
    trap - EXIT

    # --- Notarize ---
    echo "⬆️  Uploading for notarization (may take a few minutes)..."
    xcrun notarytool submit "${SIGNED_ZIP}" \
        --apple-id  "${APPLE_ID}" \
        --password  "${APP_PASSWORD}" \
        --team-id   "${TEAM_ID}" \
        --wait
    echo "✅ Notarization accepted."
    echo
done

echo "================================================="
echo "🎉 All done!"
for ZIP in "${ZIPS[@]}"; do
    BASENAME="$(basename "${ZIP}" .zip)"
    echo "    out/${BASENAME}-notarized.zip"
done
echo "================================================="
