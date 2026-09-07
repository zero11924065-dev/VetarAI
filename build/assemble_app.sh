#!/bin/bash
# checkpoint-063 封装：组装 VetarAI.app（无签名版）
# 用本地 Electron 外壳 + 应用资源 + 侧车二进制组装标准 .app 包
set -e

BASE="/Users/vetar/Desktop/beta/subagent"
OUT="$BASE/build/VetarAI.app"
ELECTRON="$BASE/node_modules/electron/Electron.app"
VERSION="0.4.11"

echo "[1/6] 清理旧产物..."
rm -rf "$OUT"

echo "[2/6] 复制 Electron 外壳..."
cp -R "$ELECTRON" "$OUT"

echo "[3/6] 重命名可执行文件..."
mv "$OUT/Contents/MacOS/Electron" "$OUT/Contents/MacOS/VetarAI"

echo "[4/6] 替换图标..."
cp "$BASE/build/VetarAI.icns" "$OUT/Contents/Resources/VetarAI.icns"
rm -f "$OUT/Contents/Resources/electron.icns"

echo "[5/6] 写入应用资源..."
APPDIR="$OUT/Contents/Resources/app"
mkdir -p "$APPDIR"
# 主进程、预加载、启动加载页
cp "$BASE/main.js" "$APPDIR/"
cp "$BASE/preload.js" "$APPDIR/"
cp "$BASE/package.json" "$APPDIR/"
cp "$BASE/splash.html" "$APPDIR/"
# 前端静态产物（打包模式加载）
mkdir -p "$APPDIR/renderer"
cp -R "$BASE/renderer/dist" "$APPDIR/renderer/dist"
# Logo（关于窗口用）+ 标准比例 Dock 图标（checkpoint-065）
mkdir -p "$APPDIR/renderer/src/assets"
cp "$BASE/renderer/src/assets/logo.png" "$APPDIR/renderer/src/assets/"
cp "$BASE/renderer/src/assets/dock_icon.png" "$APPDIR/renderer/src/assets/"
# 侧车二进制（process.resourcesPath/sidecar/）
cp -R "$BASE/build/dist/vetarai-sidecar" "$OUT/Contents/Resources/sidecar"
chmod +x "$OUT/Contents/Resources/sidecar/vetarai-sidecar"

# TS-120 阶段二：bge-m3 ONNX INT8 语义模型（544MB，随安装包一键部署，用户 2026-09-04 拍板）。
# 侧车运行时按"用户数据目录优先（可自行替换升级）→ 环境变量 → 安装包内置"三级解析。
# 源目录：~/.subagent/models/bge-m3-onnx-int8/（下载核实产物）
MODEL_SRC="$HOME/.subagent/models/bge-m3-onnx-int8"
if [ -d "$MODEL_SRC" ]; then
  mkdir -p "$OUT/Contents/Resources/models"
  cp -R "$MODEL_SRC" "$OUT/Contents/Resources/models/bge-m3-onnx-int8"
  echo "    + 语义模型已装入（$(du -sh "$OUT/Contents/Resources/models" | cut -f1)）"
else
  echo "    ⚠ 未找到模型目录 $MODEL_SRC，本次安装包不含语义模型（检索降级为关键词）"
fi

echo "[6/6] 修改 Info.plist..."
PLIST="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName VetarAI" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName VetarAI" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string VetarAI" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.vetarai.app" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile VetarAI" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string VetarAI" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable VetarAI" "$PLIST"

echo ""
echo "✓ 组装完成: $OUT"
du -sh "$OUT"
