#!/bin/bash
#
# build-dmg.sh
# Script to build SimVirtualLocation DMG installer
#
# Usage: ./scripts/build-dmg.sh [configuration]
# Configuration: Debug (default) or Release
#

set -e

# Configuration
CONFIGURATION="${1:-Release}"
PROJECT_NAME="SimVirtualLocation"
SCHEME="SimVirtualLocation"
PROJECT_FILE="SimVirtualLocation.xcodeproj"
DMG_NAME="${PROJECT_NAME}-${CONFIGURATION}.dmg"
VOLUME_NAME="${PROJECT_NAME}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
TEMP_DMG_DIR="${BUILD_DIR}/dmg-temp"
APP_PATH=""

echo "=========================================="
echo "Building ${PROJECT_NAME} DMG"
echo "Configuration: ${CONFIGURATION}"
echo "=========================================="

# Clean previous builds
echo "Cleaning previous builds..."
if [ -d "${BUILD_DIR}" ]; then
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"
mkdir -p "${TEMP_DMG_DIR}"

# Build the application
echo "Building application..."
cd "${PROJECT_DIR}"

if [ "${CONFIGURATION}" = "Debug" ]; then
    xcodebuild -project "${PROJECT_FILE}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_DIR}" \
        build \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGN_ENTITLEMENTS=""
else
    xcodebuild -project "${PROJECT_FILE}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_DIR}" \
        build
fi

# Find the built app
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}/${PROJECT_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: Application not found at ${APP_PATH}"
    exit 1
fi

echo "Application built successfully at: ${APP_PATH}"

# Copy app to temp DMG directory
echo "Preparing DMG contents..."
cp -R "${APP_PATH}" "${TEMP_DMG_DIR}/"

# Create Applications symlink
ln -s /Applications "${TEMP_DMG_DIR}/Applications"

# Create DMG
echo "Creating DMG..."
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

# Remove existing DMG if present
if [ -f "${DMG_PATH}" ]; then
    rm "${DMG_PATH}"
fi

# Create DMG using hdiutil
hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${TEMP_DMG_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}"

# Clean up temp directory
echo "Cleaning up temporary files..."
rm -rf "${TEMP_DMG_DIR}"

echo "=========================================="
echo "DMG created successfully!"
echo "Location: ${DMG_PATH}"
echo "=========================================="

# Get DMG size
DMG_SIZE=$(du -h "${DMG_PATH}" | cut -f1)
echo "DMG Size: ${DMG_SIZE}"

# Optional: Open the build folder
if command -v open &> /dev/null; then
    echo ""
    read -p "Open build folder? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "${BUILD_DIR}"
    fi
fi

echo "Done!"
