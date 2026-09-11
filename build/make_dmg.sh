#!/bin/bash
# TS-121（0.3.1 起）：打安装盘——标准拖拽安装布局（VetarAI.app + Applications 快捷方式）
# 用法：VERSION=0.4.20 bash build/make_dmg.sh
# 修复记录：0.3.0/0.3.1 初版直接从 .app 打包，漏掉 Applications 快捷方式，
# 用户打开安装包后没有"拖到应用程序"的目标文件夹。自本脚本起统一走暂存目录。
#
# 0.4.20 修复两个缺陷：
# ① ⛔ VERSION 默认值曾是 `0.3.1`（TS-121 时代留下，十几次发版无人回改）。
#    忘记传 VERSION 就会打出 `VetarAI-0.3.1-arm64.dmg` —— **名字与内容版本号不符的畸形包**，
#    且不会报错。改为**必填**：缺 VERSION 直接报错退出。
# ② ⛔ DMG 本身从未签名（实测 `codesign -dv` 报 `code object is not signed at all`）。
#    后果：用户从浏览器/网盘下载 DMG 时，macOS 给 DMG 打上 quarantine 标记，
#    Gatekeeper 对**未签名的 DMG** 直接拦（即使里面的 .app 已签名+公证）。
#    → 本脚本在 hdiutil 之后补 codesign，并支持 SIGN_DMG=1 时公证+staple DMG。
set -e

BASE="/Users/vetar/Desktop/beta/subagent"
if [ -z "${VERSION:-}" ]; then
  echo "⛔ 必须显式传 VERSION（例：VERSION=0.4.20 bash build/make_dmg.sh）"
  echo "   原默认值 0.3.1 已移除——它会静默产出名字与内容不符的畸形包。"
  exit 1
fi
STAGE="$BASE/build/dmg-stage"
OUT="$BASE/build/VetarAI-${VERSION}-arm64.dmg"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-VetarAI}"
SIGN_DMG="${SIGN_DMG:-1}"       # 默认签（有证书才真签；无证书自动降级并如实告知）

echo "[1/5] 准备暂存目录（app + Applications 快捷方式）..."
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BASE/build/VetarAI.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "[2/5] 生成安装盘..."
rm -f "$OUT"
hdiutil create -volname "VetarAI" -srcfolder "$STAGE" -ov -format UDZO -o "$OUT"

echo "[3/5] 清理暂存..."
rm -rf "$STAGE"

echo "[4/5] 签名 DMG（0.4.20 新增）..."
if [ "$SIGN_DMG" != "1" ]; then
  echo "   已跳过（SIGN_DMG=0）"
else
  # ⛔ 与 sign_app.sh 同一套身份解析：优先 Developer ID Application，无证书则降级 ad-hoc。
  #   ad-hoc 签名的 DMG 无法通过 Gatekeeper 在线校验，但至少封印完整（优于完全不签）。
  DMG_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
  if [ -n "$DMG_ID" ]; then
    codesign --force --sign "$DMG_ID" --timestamp "$OUT"
    echo "   ✅ 已用 Developer ID 签名：$DMG_ID"
    codesign --verify --strict --verbose=2 "$OUT" 2>&1 | tail -2

    if [ "${NOTARIZE_DMG:-0}" = "1" ]; then
      echo "[4b] 公证 DMG（Apple 服务端排队，可能数分钟~1 小时）..."
      # ⛔ 用 ditto 打包提交？DMG 本身已是单文件，直接提交即可（无需再压缩）。
      if xcrun notarytool submit "$OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1 | tail -12; then
        xcrun stapler staple "$OUT" && echo "   ✅ DMG staple 完成"
      else
        echo "   ⛔ DMG 公证失败——.app 本身已公证并 staple，DMG 仍可分发（用户可能见到一次提示）"
        echo "   查明原因：xcrun notarytool log <id> --keychain-profile $KEYCHAIN_PROFILE"
      fi
    fi
  else
    echo "   ⚠️ 钥匙串无 Developer ID Application 证书 → DMG 降级 ad-hoc 签名"
    codesign --force --sign - "$OUT" 2>&1 | tail -2 || true
  fi
fi

echo "[5/5] 完成："
ls -lh "$OUT"
echo ""
echo "产物：$OUT"
echo "  大小: $(stat -f '%z' "$OUT") 字节"
echo "  md5:  $(md5 -q "$OUT")"
