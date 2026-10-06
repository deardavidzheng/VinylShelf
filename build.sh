#!/bin/bash
# VinylShelf 构建脚本：编译 → .app → 签名 → DMG
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

APP_NAME="VinylShelf"
BUNDLE_ID="com.david.vinylshelf"
EXECUTABLE="VinylShelf"
VERSION="1.0.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DIST="$ROOT/dist"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

echo "==> [1/5] 编译"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -name "*.swift")
echo "    源文件 ${#SOURCES[@]} 个"

SDK="$(xcrun --show-sdk-path)"
xcrun swiftc -O -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/$EXECUTABLE" \
  "${SOURCES[@]}"

chmod +x "$APP/Contents/MacOS/$EXECUTABLE"
echo "    可执行文件: $(du -h "$APP/Contents/MacOS/$EXECUTABLE" | cut -f1)"

echo "==> [2/5] Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>黑胶仓库</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHumanReadableCopyright</key><string>本地黑胶收藏管理</string>
</dict>
</plist>
PLIST

echo "==> [3/5] 图标"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
  echo "    AppIcon.icns $(du -h "$ROOT/Resources/AppIcon.icns" | cut -f1)"
else
  echo "    ⚠ 缺少图标，运行 tools/make_icon.py 生成"
fi

echo "==> [4/5] 签名"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing" || true
codesign -v "$APP" && echo "    签名有效"

echo "==> [5/5] DMG"
DMG="$DIST/VinylShelf-${VERSION}.dmg"
rm -f "$DMG"

TMP_MOUNT=$(mktemp -d)
STAGE="$TMP_MOUNT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG_RW="$BUILD/rw.dmg"
rm -f "$DMG_RW"

hdiutil create -srcfolder "$STAGE" -volname "VinylShelf" -fs HFS+ -format UDRW "$DMG_RW" -quiet
if hdiutil convert "$DMG_RW" -format UDZO -o "$DMG" -quiet 2>/dev/null; then
  echo "    压缩镜像"
else
  hdiutil convert "$DMG_RW" -format UDRW -o "$DMG" -quiet
  echo "    未压缩镜像"
fi
hdiutil detach "$TMP_MOUNT" -quiet 2>/dev/null || true
rm -rf "$TMP_MOUNT"
rm -f "$DMG_RW"

echo ""
echo "✓ 构建完成"
echo "  App : $APP"
echo "  DMG : $DMG  ($(du -h "$DMG" | cut -f1))"
echo ""
echo "首次使用："
echo "  1. 打开 App → 设置"
echo "  2. 粘贴 Discogs Personal Access Token"
echo "     获取：登录 discogs.com → Settings → Developers → Generate new token"
echo "  3. 点「立即同步」导入收藏"
