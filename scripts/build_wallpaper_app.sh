#!/bin/sh
# Build the Snoopy Wallpaper menu-bar app (Sources/SnoopyWallpaper) and wrap it
# in a proper .app bundle with the same resource layout as SNOOPY.saver.
#
#   sh scripts/build_wallpaper_app.sh              # build + bundle, copies Resources/SnoopyAssets
#   SNOOPY_ASSETS=link sh scripts/build_wallpaper_app.sh   # symlink the 7 GB asset folder instead
#   SNOOPY_INSTALL=1 sh scripts/build_wallpaper_app.sh     # also copy to /Applications and launch
#
# Environment:
#   SNOOPY_BUILD_CONFIG  release (default) | debug
#   SNOOPY_ASSETS        copy (default) | link | none
#   SNOOPY_SKIP_BUILD=1  reuse an existing `swift build` product
#   SNOOPY_APP_OUTPUT    bundle path (default .build/SnoopyWallpaper.app)
#   SNOOPY_APP_VERSION   CFBundleShortVersionString/CFBundleVersion (default 1.0)
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIG="${SNOOPY_BUILD_CONFIG:-release}"
OUT="${SNOOPY_APP_OUTPUT:-$ROOT/.build/SnoopyWallpaper.app}"
ASSETS_MODE="${SNOOPY_ASSETS:-copy}"
VERSION="${SNOOPY_APP_VERSION:-1.0}"

if [ "${SNOOPY_SKIP_BUILD:-0}" != "1" ]; then
  swift build --package-path "$ROOT" -c "$CONFIG" --product SnoopyWallpaper
fi
BIN="$ROOT/.build/$CONFIG/SnoopyWallpaper"
if [ ! -x "$BIN" ]; then
  echo "Build product not found: $BIN" >&2
  exit 3
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/SnoopyWallpaper"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Snoopy Wallpaper</string>
	<key>CFBundleExecutable</key>
	<string>SnoopyWallpaper</string>
	<key>CFBundleIdentifier</key>
	<string>com.dingdangnao.snoopy.wallpaper</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Snoopy Wallpaper</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>叮噹鬧 | DINGDANGNAO</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

# Same resource layout as the .saver: index + halftone next to the media folder.
cp "$ROOT/Resources/asset-index.json" "$ROOT/Resources/halftone_pattern.png" "$OUT/Contents/Resources/"
if [ -d "$ROOT/.derived-media" ]; then
  ditto "$ROOT/.derived-media" "$OUT/Contents/Resources/DerivedMedia"
fi
case "$ASSETS_MODE" in
  copy)
    if [ -d "$ROOT/Resources/SnoopyAssets" ]; then
      ditto "$ROOT/Resources/SnoopyAssets" "$OUT/Contents/Resources/SnoopyAssets"
    else
      echo "warning: $ROOT/Resources/SnoopyAssets not found — the app will have no media (see README)" >&2
    fi
    ;;
  link)
    ln -s "$ROOT/Resources/SnoopyAssets" "$OUT/Contents/Resources/SnoopyAssets"
    ;;
  none) ;;
  *) echo "SNOOPY_ASSETS must be copy, link or none" >&2; exit 2 ;;
esac

# Local app: seal ad-hoc so Launch at Login (SMAppService) and TCC treat it consistently.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$OUT"
fi
echo "Built: $OUT"

if [ "${SNOOPY_INSTALL:-0}" = "1" ]; then
  DEST="/Applications/Snoopy Wallpaper.app"
  pkill -x SnoopyWallpaper 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$OUT" "$DEST"
  open "$DEST"
  echo "Installed and launched: $DEST"
fi
