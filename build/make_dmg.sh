#!/bin/bash
# TS-121（0.3.1 起）：打安装盘——标准拖拽安装布局（VetarAI.app + Applications 快捷方式）
# 用法：bash build/make_dmg.sh
# 修复记录：0.3.0/0.3.1 初版直接从 .app 打包，漏掉 Applications 快捷方式，
# 用户打开安装包后没有"拖到应用程序"的目标文件夹。自本脚本起统一走暂存目录。
set -e

BASE="/Users/vetar/Desktop/beta/subagent"
VERSION="${VERSION:-0.3.1}"
STAGE="$BASE/build/dmg-stage"
OUT="$BASE/build/VetarAI-${VERSION}-arm64.dmg"

echo "[1/4] 准备暂存目录（app + Applications 快捷方式）..."
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BASE/build/VetarAI.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "[2/4] 生成安装盘..."
rm -f "$OUT"
hdiutil create -volname "VetarAI" -srcfolder "$STAGE" -ov -format UDZO -o "$OUT"

echo "[3/4] 清理暂存..."
rm -rf "$STAGE"

echo "[4/4] 完成："
ls -lh "$OUT"
