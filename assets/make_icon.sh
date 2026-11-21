#!/bin/zsh
# Régénère l'icône : mFRAMES_1024.png et mFRAMES.icns (build_app.sh se sert de mFRAMES.icns).
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
swift make_icon.swift mFRAMES_1024.png
mkdir "$T/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s mFRAMES_1024.png --out "$T/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) mFRAMES_1024.png --out "$T/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/icon.iconset" -o mFRAMES.icns
rm -rf "$T"
echo "OK : assets/mFRAMES_1024.png, assets/mFRAMES.icns"
