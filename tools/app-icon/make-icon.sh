#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/AppIcon.iconset ../../Resources ../../docs
xcrun swiftc -O AppIcon.swift -o build/app-icon

render() { build/app-icon --size "$1" --out "build/AppIcon.iconset/$2.png"; }
render 16   icon_16x16
render 32   icon_16x16@2x
render 32   icon_32x32
render 64   icon_32x32@2x
render 128  icon_128x128
render 256  icon_128x128@2x
render 256  icon_256x256
render 512  icon_256x256@2x
render 512  icon_512x512
render 1024 icon_512x512@2x

iconutil -c icns build/AppIcon.iconset -o ../../Resources/AppIcon.icns
build/app-icon --size 1024 --out build/AppIcon-1024.png
build/app-icon --size 256 --out ../../docs/icon.png
echo "Icon: $PWD/../../Resources/AppIcon.icns"
