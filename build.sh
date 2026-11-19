#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Glowdrop
APP=build/$APP_NAME.app
EXT_NAME=GlowdropWallpaper
APPEX=$APP/Contents/Extensions/$EXT_NAME.appex
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
MODE=dev

case "${1:-}" in
    "") ;;
    --install) MODE=install ;;
    --release) MODE=release ;;
    *) MODE=bad ;;
esac
if [[ $# -gt 1 ]]; then MODE=bad; fi
if [[ $MODE == bad ]]; then
    echo "usage: build.sh [--install | --release]" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS" build

xcrun swiftc -swift-version 6 Sources/PlaybackPolicy.swift Sources/LibraryNaming.swift Sources/LibraryModels.swift \
    Sources/LibraryScanner.swift Sources/LockScreenFiles.swift Extension/LockScreenPlayback.swift Tests/main.swift \
    -o build/selftest
./build/selftest

# The Lock Screen wallpaper extension (macOS 26+): an ExtensionKit appex whose entry point is
# Foundation's _NSExtensionMain, as Xcode links the extensionkit-extension product type.
build_extension() {
    xcrun swiftc -swift-version 6 -parse-as-library -O -target "$1-apple-macos26.0" -module-name "$EXT_NAME" \
        -import-objc-header Extension/Bridging.h \
        -framework ExtensionFoundation -framework AVFoundation -framework CoreMedia -framework QuartzCore \
        -framework IOSurface -framework ImageIO -framework Security -Xlinker -e -Xlinker _NSExtensionMain \
        Extension/*.swift Sources/LockScreenFiles.swift -o "$2"
}

if [[ $MODE == release ]]; then
    if [[ ! -f LICENSE ]]; then
        echo "error: LICENSE is missing; a release must ship the MIT notice" >&2
        exit 1
    fi
    if [[ ! -d THIRD_PARTY_LICENSES ]]; then
        echo "error: THIRD_PARTY_LICENSES is missing; a release must ship the Phosphene MIT notice" >&2
        exit 1
    fi
    if [[ ! -f Resources/AppIcon.icns ]]; then
        echo "error: Resources/AppIcon.icns is missing; run bash tools/app-icon/make-icon.sh" >&2
        exit 1
    fi
    if [[ ! -f Resources/Wallpapers/Glowdrop/wallpapers.json ]]; then
        if [[ ! -f tools/glitch-render/render-bundled.sh ]]; then
            echo "error: Resources/Wallpapers/Glowdrop/wallpapers.json is missing and tools/glitch-render/render-bundled.sh is missing" >&2
            exit 1
        fi
        bash tools/glitch-render/render-bundled.sh Resources/Wallpapers
    fi
    for arch in arm64 x86_64; do
        mkdir -p "build/$arch"
        xcrun swiftc -swift-version 6 -O -target "$arch-apple-macos13.0" Sources/*.swift -o "build/$arch/$APP_NAME"
        build_extension "$arch" "build/$arch/$EXT_NAME"
    done
    lipo -create build/arm64/$APP_NAME build/x86_64/$APP_NAME -output "$APP/Contents/MacOS/$APP_NAME"
    lipo -create build/arm64/$EXT_NAME build/x86_64/$EXT_NAME -output "$APPEX/Contents/MacOS/$EXT_NAME"
else
    xcrun swiftc -swift-version 6 -O -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/$APP_NAME"
    build_extension "$(uname -m)" "$APPEX/Contents/MacOS/$EXT_NAME"
fi

cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [[ -d Resources/Wallpapers ]]; then
    cp -R Resources/Wallpapers "$APP/Contents/Resources/"
fi
if [[ -f LICENSE ]]; then
    cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
fi
if [[ -d THIRD_PARTY_LICENSES ]]; then
    cp -R THIRD_PARTY_LICENSES "$APP/Contents/Resources/THIRD_PARTY_LICENSES"
fi
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
cp Extension/Info.plist "$APPEX/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" Info.plist)" "$APPEX/Contents/Info.plist"
done
# The appex first: signing the app seals the nested code as it is.
codesign --force --options runtime --entitlements Extension/GlowdropWallpaper.entitlements --sign - "$APPEX"
codesign --force --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"

if [[ $MODE == install ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/$APP_NAME.app
    cp -R "$APP" ~/Applications/
    # -trusted, as Xcode registers: without it an ad-hoc app that never ran is registered launch-disabled
    # and its wallpaper extension is not offered.
    "$LSREGISTER" -f -trusted ~/Applications/$APP_NAME.app
    echo "Installed: $HOME/Applications/$APP_NAME.app"
elif [[ $MODE == release ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
    ZIP="dist/$APP_NAME-$VERSION.zip"
    mkdir -p dist
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "Release: $PWD/$ZIP"
    shasum -a 256 "$ZIP"

    DMG="dist/$APP_NAME-$VERSION.dmg"
    rm -rf build/dmg
    mkdir -p build/dmg
    ditto "$APP" "build/dmg/$APP_NAME.app"
    ln -s /Applications build/dmg/Applications
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder build/dmg -fs HFS+ -format UDZO -ov -quiet "$DMG" >/dev/null
    hdiutil verify -quiet "$DMG"
    echo "Release: $PWD/$DMG"
    shasum -a 256 "$DMG"
else
    echo "Built: $PWD/$APP"
fi
