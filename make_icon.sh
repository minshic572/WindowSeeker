#!/bin/bash
# 生成并安装「窗口总览」的应用图标
# 用法：./make_icon.sh
# 想改图标外观，改 draw_icon.swift 里的几何与配色，再跑本脚本。
set -e
cd "$(dirname "$0")"

APP="/Applications/WindowSeeker.app"
ICNS="WindowSeeker.icns"

if [ ! -d "$APP" ]; then
    echo "✗ 找不到 $APP —— 请先跑 ./build.sh 把应用装上"
    exit 1
fi

echo "==> 1/4 绘制 1024 主图"
xcrun swift draw_icon.swift icon_1024.png

echo "==> 2/4 生成各尺寸图标集"
rm -rf WindowSeeker.iconset "$ICNS"
mkdir WindowSeeker.iconset
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512"; do
  size="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$size" "$size" icon_1024.png --out "WindowSeeker.iconset/$name.png" >/dev/null
done
cp icon_1024.png WindowSeeker.iconset/icon_512x512@2x.png

echo "==> 3/4 打包 icns 并放进应用包"
iconutil -c icns WindowSeeker.iconset -o "$ICNS"
cp "$ICNS" "$APP/Contents/Resources/$ICNS"

echo "==> 4/4 重新签名 + 刷新图标缓存"
pkill -x WindowSeeker 2>/dev/null || true
sleep 1
codesign --force --sign - "$APP"
touch "$APP"
killall Dock 2>/dev/null || true

echo ""
echo "完成。重新打开 $APP 即可看到新图标。"
echo "注意：重新签名会改变 cdhash，若之前已授予辅助功能权限，需要重新勾选一次。"
