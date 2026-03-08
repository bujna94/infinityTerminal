#!/bin/bash
# Builds a proper .app bundle for Infinity Terminal.
# Usage:  ./build-app.sh
# Output: .build/InfinityTerminal.app  (double-click or: open .build/InfinityTerminal.app)
set -e

PRODUCT="InfinityTerminal"
APP="${PRODUCT}.app"
BUILD_DIR=".build/release"
APP_PATH=".build/${APP}"

echo "→ Building ${PRODUCT} (release)…"
swift build -c release 2>&1

echo "→ Packaging ${APP}…"

# ── Bundle skeleton ──────────────────────────────────────────────────────────
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

# ── Executable ───────────────────────────────────────────────────────────────
cp "${BUILD_DIR}/${PRODUCT}" "${APP_PATH}/Contents/MacOS/${PRODUCT}"

# ── SPM resource bundle (Bundle.module searches Contents/Resources/) ──────────
cp -r "${BUILD_DIR}/${PRODUCT}_${PRODUCT}.bundle" \
      "${APP_PATH}/Contents/Resources/"

# ── App icon for Finder / Dock ────────────────────────────────────────────────
ICON_SRC="${BUILD_DIR}/${PRODUCT}_${PRODUCT}.bundle/Contents/Resources/AppIcon.icns"
[ -f "${ICON_SRC}" ] && cp "${ICON_SRC}" "${APP_PATH}/Contents/Resources/AppIcon.icns"

# ── Info.plist ────────────────────────────────────────────────────────────────
cat > "${APP_PATH}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.infinityterminal.app</string>
    <key>CFBundleName</key>
    <string>Infinity Terminal</string>
    <key>CFBundleDisplayName</key>
    <string>Infinity Terminal</string>
    <key>CFBundleExecutable</key>
    <string>InfinityTerminal</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# ── Ad-hoc code sign (required for .app bundles on macOS) ────────────────────
# Strip quarantine / resource-fork metadata that blocks codesign
xattr -cr "${APP_PATH}" 2>/dev/null || true
if codesign --force --deep --sign - "${APP_PATH}" 2>&1 | grep -v "replacing existing signature"; then
    echo "→ Signed (ad-hoc)"
else
    echo "⚠ codesign failed – app may not launch"
fi

echo ""
echo "✓  ${APP_PATH}"
echo ""
echo "Run with:"
echo "   open ${APP_PATH}"
