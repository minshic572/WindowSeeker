#!/bin/bash
# 重新编译「窗口总览」，直接装配到 /Applications/WindowSeeker.app
#
# 用法：把改动写进 main.swift 后，在终端执行 ./build.sh
#
# 设计要点：本目录**只放源码，不放 .app 包**。
# 因为 LaunchServices 会扫描工作区里的 .app，若这里也留一份，
# 同一个 bundle id 就会被注册两次 → Launchpad 里出现两个「窗口总览」。
# 所以应用包只存在于 /Applications 一处。
set -e
cd "$(dirname "$0")"

DEST="/Applications/WindowSeeker.app"
ICON="WindowSeeker.icns"
PLIST="Info.plist"

# 目标架构：默认 Apple Silicon。
#   想编 Intel：      TARGET_ARCH=x86_64 ./build.sh
#   想要通用二进制：  分别用 arm64 与 x86_64 各编一次，再用 lipo -create 合并
ARCH="${TARGET_ARCH:-arm64}"
TARGET="${ARCH}-apple-macos13.0"

# 自检：默认产出的是 arm64 产物，在 Intel 机器上装出来跑不起来，直接说清楚。
if [ "$ARCH" = "arm64" ] && [ "$(uname -m)" != "arm64" ]; then
    echo "✗ 本脚本默认构建 arm64 产物，而当前机器是 $(uname -m)，产物无法在本机运行。"
    echo "  如果你确实要为 Intel Mac 构建：TARGET_ARCH=x86_64 ./build.sh"
    exit 1
fi

# 0) 记录改动前的 cdhash，用于判断是否需要重新授权
#    注意：codesign -d 的输出走 stderr，必须用 2>&1，否则读到空值。
OLD_HASH="$(codesign -dvvv "$DEST" 2>&1 | grep '^CDHash' | cut -d= -f2 || true)"

# 1) 编译到**固定路径**的临时目录，并且把源码也复制进去。
#
#    为什么两样都要固定：swiftc 会把**源码路径和输出路径**都写进二进制的调试信息。
#    - 输出路径若用 mktemp -d，每次不同 → 二进制不同 → cdhash 变 → 辅助功能权限失效。
#    - 源码路径若直接用本目录，那么**换个目录放源码**（比如从工作区搬到 ~/Projects）
#      也会改变二进制 → cdhash 变。
#    把 main.swift 复制到固定目录、用相对文件名编译后，构建就与"工程放在哪"无关，
#    实测：从两个不同目录编译，产物 sha256 完全相同。
#    编译在装配之前，所以编译失败时旧的 app 不会被破坏。
TMP="/tmp/windowseeker-build"
rm -rf "$TMP"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "==> 编译 main.swift（target $TARGET）"
cp main.swift "$TMP/main.swift"
( cd "$TMP" && xcrun swiftc -swift-version 5 -O -target "$TARGET" \
    -o WindowSeeker main.swift )
echo "    架构 $ARCH · 大小 $(ls -lh "$TMP/WindowSeeker" | awk '{print $5}')"

# 2) 退出正在运行的实例
echo "==> 退出正在运行的实例"
pkill -x WindowSeeker 2>/dev/null || true
sleep 1

# 3) 就地更新应用包（全盘只保留这一个 WindowSeeker.app）
#
# ⚠️ 这里**故意不用 `rm -rf "$DEST"` 重建**：本机的文件操作中介会把 `.app` 目录的删除
#    改道成「移入废纸篓」（实测：`rm -rf /tmp/X.app` 后 ~/.Trash 硬链接数 +1；
#    而删普通目录 +0，是真删）。每跑一次构建就往废纸篓塞一份 app、并在 LaunchServices 里
#    多注册一条记录 → 「应用程序」里可能又冒出重复图标。
#    改为原地覆盖文件，配合 `codesign --force` 重新签名，效果等价且不留垃圾。
if [ -d "$DEST" ]; then
    echo "==> 更新已有应用包 $DEST（原地覆盖）"
else
    echo "==> 新建应用包 $DEST"
fi
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$TMP/WindowSeeker" "$DEST/Contents/MacOS/WindowSeeker"
cp "$PLIST" "$DEST/Contents/Info.plist"
[ -f "$ICON" ] && cp "$ICON" "$DEST/Contents/Resources/"

# 4) 签名（ad-hoc：让辅助功能权限能绑定到这份二进制）
echo "==> ad-hoc 签名"
codesign --force --sign - "$DEST" 2>&1 | tail -2
xattr -cr "$DEST"

# 5) 注册 + 清掉可能残留的旧注册项
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST" 2>/dev/null || true

echo "==> 启动"
open "$DEST"

echo
echo "==> 完成：$DEST"
NEW_HASH="$(codesign -dvvv "$DEST" 2>&1 | grep '^CDHash' | cut -d= -f2)"
echo "    cdhash: $NEW_HASH"
echo

if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    echo "✅ cdhash 未变（源码无改动或改动不影响二进制）—— 已授予的「辅助功能」权限仍然有效。"
else
    echo "⚠️  cdhash 变了（$OLD_HASH → $NEW_HASH），已授予的「辅助功能」权限会失效。重新授权："
    echo "     tccutil reset Accessibility local.tools.windowseeker"
    echo "     pkill -x WindowSeeker && open $DEST"
    echo "     然后 系统设置 → 隐私与安全性 → 辅助功能 → 勾选「窗口总览」"
fi

