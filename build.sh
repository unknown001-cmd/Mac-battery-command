#!/bin/bash
# PowerWidget 构建脚本
# 用法：./build.sh          编译 + 签名 + 重启
#       ./build.sh --no-run 只编译
set -e
cd "$(dirname "$0")"

APP="PowerWidget.app"
BIN="$APP/Contents/MacOS/PowerWidget"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

echo "→ 编译 SMC 桥接…"
BUILT=()
for a in arm64 x86_64; do
    if clang -O2 -arch "$a" -mmacosx-version-min=11.0 -c smc.c -o "smc_$a.o" 2>/dev/null; then
        BUILT+=("$a")
    else
        echo "  跳过架构 $a（SDK 不支持）"
    fi
done
[ ${#BUILT[@]} -eq 0 ] && { echo "SMC 编译失败"; exit 1; }

echo "→ 编译 Swift（${BUILT[*]}）…"
Slices=()
for a in "${BUILT[@]}"; do
    # swiftc 用 -target 而不是 -arch；与 Info.plist 的 LSMinimumSystemVersion 保持一致
    TGT="$a-apple-macosx11.0"
    swiftc -O -target "$TGT" -import-objc-header smc_bridge.h \
        -o "pw_$a" main.swift history.swift "smc_$a.o" \
        -framework Cocoa -framework IOKit
    Slices+=("pw_$a")
done

echo "→ 合并二进制…"
if [ ${#Slices[@]} -gt 1 ]; then
    lipo -create "${Slices[@]}" -output "$BIN"
else
    cp "${Slices[0]}" "$BIN"
fi
chmod +x "$BIN"
rm -f pw_* smc_*.o 2>/dev/null || true

echo "→ 签名…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo -n "→ 架构："; lipo -archs "$BIN"

if [ "$1" != "--no-run" ]; then
    echo "→ 重启应用…"
    pkill -f "PowerWidget.app/Contents/MacOS/PowerWidget" 2>/dev/null || true
    sleep 1
    open "$APP"
fi
echo "✔ 完成"
