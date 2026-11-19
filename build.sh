#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Glowdrop
APP=build/$APP_NAME.app
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
mkdir -p "$APP/Contents/MacOS" build

xcrun swiftc -swift-version 6 Sources/PlaybackPolicy.swift Sources/LibraryNaming.swift Sources/LibraryModels.swift \
    Sources/LibraryScanner.swift Tests/main.swift -o build/selftest && ./build/selftest

if [[ $MODE == release ]]; then
    if [[ ! -f LICENSE ]]; then
        echo "error: LICENSE is missing; a release must ship the MIT notice" >&2
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
    done
    lipo -create build/arm64/$APP_NAME build/x86_64/$APP_NAME -output "$APP/Contents/MacOS/$APP_NAME"
else
    xcrun swiftc -swift-version 6 -O -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/$APP_NAME"
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
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
codesign --force --options runtime --sign - "$APP"

if [[ $MODE == install ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/$APP_NAME.app
    cp -R "$APP" ~/Applications/
    echo "Installed: $HOME/Applications/$APP_NAME.app"
elif [[ $MODE == release ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
    ZIP="dist/$APP_NAME-$VERSION.zip"
    mkdir -p dist
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "Release: $PWD/$ZIP"
    shasum -a 256 "$ZIP"
else
    echo "Built: $PWD/$APP"
fi
