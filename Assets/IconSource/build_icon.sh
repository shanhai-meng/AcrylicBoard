#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PNG="$SCRIPT_DIR/AppIcon_1024.png"
ICONSET="$SCRIPT_DIR/AppIcon.iconset"
ICNS="$SCRIPT_DIR/AppIcon.icns"
DEST_DIR="$SCRIPT_DIR/../../AcrylicBoard/Resources"

# 先生成 1024 主图
swift "$SCRIPT_DIR/MakeIcon.swift" "$PNG"

# 创建 iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16   "$PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

rm -f "$ICNS"
iconutil -c icns "$ICONSET"

mkdir -p "$DEST_DIR"
cp "$ICNS" "$DEST_DIR/AppIcon.icns"

echo "已生成 AppIcon.icns -> $DEST_DIR/AppIcon.icns"
