#!/bin/bash
#
# Builds the macOS distribution of DOOM 2 RT (Apple silicon, RTGL1's Metal backend):
#
#   DOOM2RT-macOS.dmg
#     Install DOOM 2 RT.app        installer (Installer.swift) carrying
#       DOOM 2 RT.aar              DOOM 2 RT.app (build_app.sh), as an Apple Archive
#
# The installer finds the user's DOOM2.WAD (Steam, also in CrossOver bottles, or chosen),
# copies it to ~/Library/Application Support/GZDoom and DOOM 2 RT.app to Applications.
# DOOM2.WAD is never part of the distribution.
#
# Usage: setup/macos/build_installer.sh [output dir]
#   the same environment variables as build_app.sh; SIGN_ID: a Developer ID (default: ad hoc)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="${ROOT}/setup/macos"
OUT="${1:-${ROOT}/build-macos-dist}"
APP_NAME="DOOM 2 RT"
APP="${OUT}/${APP_NAME}.app"
STAGE="${OUT}/stage"
INSTALLER="${STAGE}/Install ${APP_NAME}.app"
DMG="${OUT}/DOOM2RT-macOS.dmg"
MIN_MACOS="26.0"    # MetalFX denoiser / frame interpolation APIs; RTGL1 needs Metal ray tracing

"${SETUP}/build_app.sh" "${OUT}"

VERSION="$(git -C "${ROOT}" describe --tags --always 2>/dev/null || echo 1.0)"
SIGN_ID="${SIGN_ID:--}"

rm -rf "${STAGE}"
mkdir -p "${INSTALLER}/Contents/MacOS" "${INSTALLER}/Contents/Resources"

echo "Archiving ${APP_NAME}.app"
aa archive -d "${APP}" -o "${INSTALLER}/Contents/Resources/${APP_NAME}.aar" -a lzfse

xcrun swiftc -O -swift-version 5 -target "arm64-apple-macos13.0" \
    "${SETUP}/Installer.swift" -o "${INSTALLER}/Contents/MacOS/installer"
cp "${APP}/Contents/Resources/doom2rt.icns" "${INSTALLER}/Contents/Resources/installer.icns"

cat > "${INSTALLER}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>installer</string>
    <key>CFBundleIdentifier</key>          <string>org.drdteam.gzdoom-rt.installer</string>
    <key>CFBundleName</key>                <string>Install ${APP_NAME}</string>
    <key>CFBundleDisplayName</key>         <string>Install ${APP_NAME}</string>
    <key>CFBundleIconFile</key>            <string>installer</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundleVersion</key>             <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>      <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
EOF

# the installer contains no nested code, so it can be sealed
SIGN_OPTS=()
[[ "${SIGN_ID}" != "-" ]] && SIGN_OPTS=(--options runtime --timestamp)
codesign --force --sign "${SIGN_ID}" "${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"}" "${INSTALLER}"

cp "${ROOT}/docs/licenses/gpl.txt" "${STAGE}/License.txt" 2>/dev/null || true

echo "Creating the disk image"
rm -f "${DMG}"
# the archive is already compressed
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDRO "${DMG}" >/dev/null
echo "Created ${DMG} ($(du -sh "${DMG}" | cut -f1))"
