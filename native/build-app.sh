#!/bin/bash
# Builds, signs, notarizes, and packages Infinity Terminal as a DMG.
# Usage:  ./build-app.sh [--dmg]
# Output: .build/InfinityTerminal.app  (always)
#         .build/InfinityTerminal.dmg  (with --dmg flag)
#
# Notarization requires:
#   APPLE_ID       – your Apple ID email
#   APPLE_PASSWORD – app-specific password (appleid.apple.com → Security)
#   APPLE_TEAM     – your Team ID (334EJ7NNV2)
set -e

PRODUCT="InfinityTerminal"
APP="${PRODUCT}.app"
DMG="${PRODUCT}.dmg"
BUILD_DIR=".build/release"
APP_PATH=".build/${APP}"
DMG_PATH=".build/${DMG}"

SIGN_ID="Developer ID Application: Pavol Bujna (334EJ7NNV2)"
TEAM_ID="334EJ7NNV2"

ENTITLEMENTS_FILE=".build/entitlements.plist"

# ── Entitlements (Hardened Runtime — no sandbox for full PTY support) ─────────
mkdir -p .build
cat > "${ENTITLEMENTS_FILE}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo "→ Building ${PRODUCT} (release)…"
swift build -c release 2>&1

echo "→ Packaging ${APP}…"

# ── Bundle skeleton ───────────────────────────────────────────────────────────
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

# ── Executable ────────────────────────────────────────────────────────────────
cp "${BUILD_DIR}/${PRODUCT}" "${APP_PATH}/Contents/MacOS/${PRODUCT}"

# ── SPM resource bundle ───────────────────────────────────────────────────────
cp -r "${BUILD_DIR}/${PRODUCT}_${PRODUCT}.bundle" \
      "${APP_PATH}/Contents/Resources/"

# ── App icon ──────────────────────────────────────────────────────────────────
ICON_SRC="${BUILD_DIR}/${PRODUCT}_${PRODUCT}.bundle/AppIcon.icns"
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
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
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
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 Infinity Terminal. All rights reserved.</string>
</dict>
</plist>
PLIST

# ── Strip xattrs + fix permissions ───────────────────────────────────────────
chflags -R nouchg "${APP_PATH}" 2>/dev/null || true
chmod -R u+w "${APP_PATH}"
xattr -cr "${APP_PATH}" 2>/dev/null || true

# ── Code sign (Hardened Runtime + Developer ID) ───────────────────────────────
echo "→ Signing…"
codesign --force --deep --options runtime \
    --entitlements "${ENTITLEMENTS_FILE}" \
    --sign "${SIGN_ID}" \
    "${APP_PATH}"

echo "→ Verifying signature…"
codesign --verify --deep --strict "${APP_PATH}" && echo "   Signature OK"
spctl --assess --type execute "${APP_PATH}" 2>&1 || echo "   (spctl: not yet notarized)"

# ── DMG ───────────────────────────────────────────────────────────────────────
if [[ "$1" == "--dmg" ]]; then
    echo "→ Creating DMG…"
    rm -f "${DMG_PATH}"
    hdiutil create -volname "Infinity Terminal" \
        -srcfolder "${APP_PATH}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    xattr -cr "${DMG_PATH}"

    # ── Notarize ──────────────────────────────────────────────────────────────
    if [[ -n "${APPLE_ID}" && -n "${APPLE_PASSWORD}" ]]; then
        echo "→ Notarizing (this takes a few minutes)…"
        xcrun notarytool submit "${DMG_PATH}" \
            --apple-id "${APPLE_ID}" \
            --password "${APPLE_PASSWORD}" \
            --team-id "${TEAM_ID}" \
            --wait
        echo "→ Stapling…"
        xcrun stapler staple "${DMG_PATH}"
        echo "✓  Notarized and stapled: ${DMG_PATH}"
    else
        echo ""
        echo "⚠  DMG created but NOT notarized."
        echo "   Set APPLE_ID, APPLE_PASSWORD (app-specific), then run:"
        echo "   APPLE_ID=you@email.com APPLE_PASSWORD=xxxx-xxxx ./build-app.sh --dmg"
    fi

    echo ""
    echo "✓  ${DMG_PATH}"
else
    echo ""
    echo "✓  ${APP_PATH}"
    echo ""
    echo "For a notarized DMG run:"
    echo "   APPLE_ID=you@email.com APPLE_PASSWORD=xxxx-xxxx ./build-app.sh --dmg"
fi
