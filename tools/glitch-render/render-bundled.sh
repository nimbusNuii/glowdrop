#!/bin/bash
# Renders the bundled Glowdrop wallpapers (4K + 2K loop and a thumbnail per palette) into <outdir>/Glowdrop/.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: bash render-bundled.sh <outdir>" >&2
    exit 1
fi

root="$(cd "$(dirname "$0")" && pwd)"
bin="$root/build/glitch-render"
final="$1/Glowdrop"
out="$root/build/bundled-staging/Glowdrop"
read -r -a palettes <<< "${PALETTES-green purple rgb}"
if [[ ${#palettes[@]} -eq 0 ]]; then
    echo "error: PALETTES is empty" >&2
    exit 1
fi

bash "$root/build.sh"
# Render into staging; the previous $final is only replaced once everything succeeded.
rm -rf "$root/build/bundled-staging"
mkdir -p "$out"

title_for() {
    case "$1" in
        green) echo "Neon Green" ;;
        purple) echo "Neon Purple" ;;
        rgb) echo "RGB Glitch" ;;
        *) echo "$(tr '[:lower:]' '[:upper:]' <<< "${1:0:1}")${1:1}" ;;
    esac
}

order=""
items=""
for palette in "${palettes[@]}"; do
    common=(--palette "$palette" --fps 60 --seconds 12)

    file="$out/glowdrop-$palette-4k.mp4"
    "$bin" "${common[@]}" --width 3840 --height 2400 --bitrate 24000000 --out "$file" > /dev/null
    echo "${file/$out/$final}"

    file="$out/glowdrop-$palette-2k.mp4"
    "$bin" "${common[@]}" --width 2560 --height 1600 --bitrate 12000000 --out "$file" > /dev/null
    echo "${file/$out/$final}"

    file="$out/glowdrop-$palette-thumb.png"
    "$bin" "${common[@]}" --width 640 --height 400 --still 0 --png "$file" > /dev/null
    echo "${file/$out/$final}"

    sep=""
    default=""
    if [[ -n "$order" ]]; then sep=","; else default=', "default": true'; fi
    order+="$sep\"glowdrop-$palette\""
    items+="$sep\"glowdrop-$palette\": {\"title\": \"$(title_for "$palette")\"$default}"
done

printf '{\n  "order": [%s],\n  "items": {%s}\n}\n' "$order" "$items" > "$out/wallpapers.json"

mkdir -p "$1"
rm -rf "$final"
mv "$out" "$final"
echo "$final/wallpapers.json"
