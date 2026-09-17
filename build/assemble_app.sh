#!/bin/bash
# checkpoint-063 封装：组装 VetarAI.app；0.4.20 起末尾追加签名步骤（[7/7]）
# 用本地 Electron 外壳 + 应用资源 + 侧车二进制组装标准 .app 包，并签名
set -e

BASE="/Users/vetar/Desktop/beta/subagent"
# OUT/VERSION 支持环境变量覆盖：便于在临时路径上验证组装+签名链路，
# 而不必覆盖正式产物（正式产物是已备份 DMG 的来源，覆盖后两者会分叉）。
OUT="${OUT:-$BASE/build/VetarAI.app}"
ELECTRON="$BASE/node_modules/electron/Electron.app"
VERSION="${VERSION:-0.4.32}"

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

# llama-server 运行时（0.4.29 模型包对话功能依赖）→ Contents/Resources/drivers/
# 源目录解析：env VETARAI_DRIVERS_DIR > ~/.subagent/drivers/。
# 只拷最小集：llama-server 本体 + otool 解析出的真实被引用 dylib（递归闭包，
# /usr/lib、/System 系统项除外），与二进制同目录扁平布局（LC_RPATH=@loader_path）。
# 源目录里 dylib 多为「版本实体 + 符号链接」三层命名，cp -L 解引用后按被引用名落盘。
DRIVERS_SRC="${VETARAI_DRIVERS_DIR:-$HOME/.subagent/drivers}"
if [ ! -x "$DRIVERS_SRC/llama-server" ]; then
  echo "    ⛔ 未找到 llama-server：$DRIVERS_SRC/llama-server" >&2
  echo "       0.4.29 的模型包对话功能依赖它，组装中止。" >&2
  echo "       请先放置 llama.cpp 预编译运行时，或用 VETARAI_DRIVERS_DIR 指定所在目录。" >&2
  exit 1
fi
DRIVERS_DST="$OUT/Contents/Resources/drivers"
mkdir -p "$DRIVERS_DST"
cp "$DRIVERS_SRC/llama-server" "$DRIVERS_DST/llama-server"
chmod +x "$DRIVERS_DST/llama-server"
queue=("llama-server")
handled=()
copied=0
while ((${#queue[@]})); do
  item="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r dep; do
    # 跳过自身 install name 与已入队/已拷贝项
    [ "$dep" = "$item" ] && continue
    already=0
    for c in "${handled[@]}"; do [ "$c" = "$dep" ] && already=1 && break; done
    [ "$already" = "1" ] && continue
    for c in "${queue[@]}"; do [ "$c" = "$dep" ] && already=1 && break; done
    [ "$already" = "1" ] && continue
    src_dep="$DRIVERS_SRC/$dep"
    if [ ! -e "$src_dep" ]; then
      echo "    ⛔ llama-server 依赖链断裂：$dep 被 $item 引用，但 $src_dep 不存在" >&2
      exit 1
    fi
    cp -L "$src_dep" "$DRIVERS_DST/$dep"
    copied=$((copied+1))
    queue+=("$dep")
  done < <(otool -L "$DRIVERS_SRC/$item" 2>/dev/null \
             | awk 'NR>1 {print $1}' \
             | grep -E '^@(rpath|executable_path|loader_path)/' \
             | sed 's|@[a-z_]*/||')
  handled+=("$item")
done
echo "    + drivers 已装入（llama-server + ${copied} 个被引用 dylib，$(du -sh "$DRIVERS_DST" | cut -f1)）"

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

# NSMicrophoneUsageDescription（0.4.30 新增，0.4.29 实测修复批）：
# macOS TCC 要求——缺该键时系统**静默拒绝**麦克风访问，且应用永不出现於
# 「系统设置→隐私与安全性→麦克风」列表（用户无任何授权入口），
# 这是 0.4.29 实测录音无声的第二处根因（另一处见 entitlements-main.plist）。
# Electron 外壳 plist 无此键，先 Add；已存在（重跑场景）则退回 Set，二者都不报错中断。
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 需要麦克风权限以录制语音并转写为文字。" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription string 需要麦克风权限以录制语音并转写为文字。" "$PLIST"

# ── [7/7] 签名（0.4.20 新增）──────────────────────────────────────
# ⛔⛔ 为什么必须在**改完 Info.plist、写完所有资源之后**才签名：
#   codesign 是对整个 bundle 内容做哈希封印的。此前 assemble_app.sh 复制 Electron
#   外壳后改了 Info.plist、换了图标、写入侧车与 565M 模型，却**从未重新签名**
#   → 2026-09-11 实测 `codesign -v` 报
#     `code has no resources but signature indicates they must be present`
#   即代码封印已损坏（8 处），且主程序 identifier 仍是通用的 `Electron`。
#   后果：① 公证必被拒 ② TCC 权限匹配不到稳定身份 → Computer Use 每次更新都失效。
echo ""
echo "[7/7] 签名（从内到外，固定 identifier）..."
# ⛔ 用 `|| rc=$?` 捕获退出码而非让它触发 set -e 中断：
#   sign_app.sh 在**无证书**时返回 3（ad-hoc 降级，签名有效但 TCC 目标未达成），
#   这是开发期的正常状态，不该让组装流程失败。只有 1（真实失败）才中断。
SIGN_RC=0
APP_PATH="$OUT" bash "$BASE/build/sign_app.sh" || SIGN_RC=$?
case "$SIGN_RC" in
  0) echo "✅ 签名完成（Developer ID，权限可跨版本保留）" ;;
  3) echo "⚠️  签名完成但为 ad-hoc 降级（无 Developer ID 证书）"
     echo "   → 封印完整、identifier 已固定，但 TCC 权限仍会每次更新失效、且无法公证。"
     echo "   → 拿到证书后重跑：SIGN_IDENTITY=\"Developer ID Application: ... (TEAMID)\" bash build/sign_app.sh" ;;
  *) echo "⛔ 签名失败（退出码 $SIGN_RC）—— 产物不可分发，中止组装"
     exit "$SIGN_RC" ;;
esac

echo ""
echo "✓ 组装完成: $OUT"
du -sh "$OUT"
