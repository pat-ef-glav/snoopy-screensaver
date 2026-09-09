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
#   SNOOPY_SKIP_PROXY_BUILD=1  do not obtain derived media (HEVC-alpha proxies of the HEIC sequences)
#   SNOOPY_APP_OUTPUT    bundle path (default .build/SnoopyWallpaper.app)
#   SNOOPY_APP_VERSION   CFBundleShortVersionString/CFBundleVersion (default 1.0)
#   SNOOPY_ICON_SOURCE   image for the app icon (default Resources/ScreenSaverPreview.png)
#   SNOOPY_ICON_CROP     "centerX centerY side" square crop in source pixels
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIG="${SNOOPY_BUILD_CONFIG:-release}"
OUT="${SNOOPY_APP_OUTPUT:-$ROOT/.build/SnoopyWallpaper.app}"
ASSETS_MODE="${SNOOPY_ASSETS:-copy}"
VERSION="${SNOOPY_APP_VERSION:-1.0}"

if [ "${SNOOPY_SKIP_BUILD:-0}" != "1" ]; then
  swift build --package-path "$ROOT" -c "$CONFIG" --product SnoopyWallpaper
fi

# Derived media: HEVC-alpha proxies of every HEIC frame sequence (base-pose loops,
# pose/reaction transitions, idle scenes, wipe masks). Without them those loops are
# decoded from 4K HEIC files live, which stutters. Reuse an installed saver's copy
# when one exists, otherwise build them once (several minutes for the full package).
DERIVED="$ROOT/.derived-media"
if [ ! -f "$DERIVED/derived-media-index.json" ] && [ "${SNOOPY_SKIP_PROXY_BUILD:-0}" != "1" ]; then
  for saver in "$HOME/Library/Screen Savers"/*.saver "/Library/Screen Savers"/*.saver; do
    if [ -f "$saver/Contents/Resources/DerivedMedia/derived-media-index.json" ]; then
      echo "Reusing derived media from $saver"
      rm -rf "$DERIVED"
      ditto "$saver/Contents/Resources/DerivedMedia" "$DERIVED"
      break
    fi
  done
  if [ ! -f "$DERIVED/derived-media-index.json" ] && [ -d "$ROOT/Resources/SnoopyAssets" ]; then
    echo "Building derived media proxies (one-time; this takes a while)..."
    swift build --package-path "$ROOT" -c release --product SnoopySequenceProxyBuilder
    "$ROOT/.build/release/SnoopySequenceProxyBuilder" \
      --index "$ROOT/Resources/asset-index.json" --output "$DERIVED"
  fi
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
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${SNOOPY_BUNDLE_ID:-com.pat-ef-glav.snoopy.wallpaper}</string>
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
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Snoopy reacts when a calendar event starts (Settings › Reactions › Alarm).</string>
	<key>NSCalendarsUsageDescription</key>
	<string>Snoopy reacts when a calendar event starts (Settings › Reactions › Alarm).</string>
</dict>
</plist>
PLIST

# App icon from the shipped Snoopy artwork (override with SNOOPY_ICON_SOURCE=path,
# and SNOOPY_ICON_CROP="centerX centerY side" in source pixels).
ICON_SOURCE="${SNOOPY_ICON_SOURCE:-$ROOT/Resources/ScreenSaverPreview.png}"
if [ -f "$ICON_SOURCE" ] && command -v iconutil >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if swift "$ROOT/Tools/MakeAppIcon.swift" "$ICON_SOURCE" "$OUT/Contents/Resources/AppIcon.icns" ${SNOOPY_ICON_CROP:-}; then
    echo "Icon: $ICON_SOURCE"
  else
    echo "warning: app icon generation failed; the app keeps the generic icon" >&2
  fi
fi

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
    # Link to the physical folder, not to the checkout: an app launched by
    # LaunchServices needs Files & Folders consent for anything it opens under
    # Documents, Desktop or Downloads, and the consent prompt blocks the first
    # media open() until someone answers it. Keep the media (or an APFS clone
    # of it, `cp -Rc`) outside those folders, e.g. in
    # ~/Library/Application Support/Snoopy Wallpaper/SnoopyAssets.
    ASSETS_PHYSICAL="$(cd "$ROOT/Resources/SnoopyAssets" 2>/dev/null && pwd -P)"
    if [ -z "$ASSETS_PHYSICAL" ]; then
      echo "warning: $ROOT/Resources/SnoopyAssets not found — the app will have no media (see README)" >&2
    else
      case "$ASSETS_PHYSICAL" in
        "$HOME/Documents"/*|"$HOME/Desktop"/*|"$HOME/Downloads"/*)
          echo "warning: media at $ASSETS_PHYSICAL is inside a consent-protected folder; the wallpaper app will hang on its first video until you allow access (see docs/WALLPAPER.md)" >&2 ;;
      esac
      ln -s "$ASSETS_PHYSICAL" "$OUT/Contents/Resources/SnoopyAssets"
    fi
    ;;
  none) ;;
  *) echo "SNOOPY_ASSETS must be copy, link or none" >&2; exit 2 ;;
esac

# Signing. Ad-hoc by default (local dev: Launch at Login and TCC treat it
# consistently). Set SNOOPY_SIGN_IDENTITY to a "Developer ID Application: …"
# identity to produce a distributable, notarization-ready bundle (hardened
# runtime + secure timestamp); notarize and staple it afterwards.
SIGN_IDENTITY="${SNOOPY_SIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$OUT"
  else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT"
    codesign --verify --deep --strict "$OUT"
  fi
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
