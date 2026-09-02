#!/bin/bash
#
# 亚克力记录板 —— 一键构建 .app
# 用法:
#   ./build_app.sh          # 编译并组装 AcrylicBoard.app（不启动）
#   ./build_app.sh --run    # 编译、组装并启动
#   ./build_app.sh --install# 编译、组装并复制到 /Applications
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="AcrylicBoard"
PRODUCT="AcrylicBoard"
PKG_DIR="$SCRIPT_DIR/AcrylicBoard"
BUNDLE_DIR="$SCRIPT_DIR/$APP_NAME.app"

echo "==> swift build -c release ..."
swift build --package-path "$PKG_DIR" -c release

BIN="$PKG_DIR/.build/release/$PRODUCT"
if [ ! -x "$BIN" ]; then
  echo "错误：找不到编译产物 $BIN" >&2
  exit 1
fi

echo "==> 组装 $APP_NAME.app ..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"
cp "$BIN" "$BUNDLE_DIR/Contents/MacOS/$PRODUCT"
cp "$PKG_DIR/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

echo "==> ad-hoc codesign ..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "完成：$BUNDLE_DIR"

if [ "${1:-}" = "--run" ]; then
  open "$BUNDLE_DIR"
  echo "已启动 $APP_NAME.app"
elif [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE_DIR" /Applications/
  echo "已安装到 /Applications/$APP_NAME.app"
fi
