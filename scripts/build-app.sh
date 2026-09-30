#!/usr/bin/env bash
# Builds dist/Droidshelf.app: release binary + bundled libmtp/libusb (dynamically linked, keeps LGPL relinkable) + icon.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/dist/Droidshelf.app"
VERSION="${VERSION:-1.0.0}"

# The macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode; the 26.5 SDK in the Command Line
# Tools still works. With Xcode installed (xcode-select -p pointing at Xcode.app) the default SDK is fine.
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]] && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Droidshelf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Droidshelf"
cp Resources/AppIcon.icns Resources/AppIcon-Dark.icns "$APP/Contents/Resources/"

LIBMTP=$(brew --prefix libmtp)/lib/libmtp.9.dylib
LIBUSB=$(brew --prefix libusb)/lib/libusb-1.0.0.dylib
cp -L "$LIBMTP" "$LIBUSB" "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/"*.dylib

# Point every reference at the bundled copies.
install_name_tool -id @rpath/libmtp.9.dylib "$APP/Contents/Frameworks/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
for ref in $(otool -L "$APP/Contents/Frameworks/libmtp.9.dylib" | awk '/libusb/ {print $1}'); do
  install_name_tool -change "$ref" @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libmtp.9.dylib"
done
install_name_tool -add_rpath @loader_path "$APP/Contents/Frameworks/libmtp.9.dylib" 2>/dev/null || true
for ref in $(otool -L "$APP/Contents/MacOS/Droidshelf" | awk '/libmtp/ {print $1}'); do
  install_name_tool -change "$ref" @rpath/libmtp.9.dylib "$APP/Contents/MacOS/Droidshelf"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Droidshelf</string>
  <key>CFBundleDisplayName</key><string>Droidshelf</string>
  <key>CFBundleIdentifier</key><string>io.github.alaahedhly.droidshelf</string>
  <key>CFBundleExecutable</key><string>Droidshelf</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© Hortensia Agency. libmtp and libusb are LGPL-2.1.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: runs on this Mac. Distributing to others needs a Developer ID signature + notarization.
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/libmtp.9.dylib"
codesign --force --sign - "$APP"

echo "Built $APP"
