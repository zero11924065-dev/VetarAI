# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
#
# This file is part of VetarAI.
#
# VetarAI is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VetarAI is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
"""0.4.9（3.48.1）Computer Use 一期 MVP 执行层：截屏 + 坐标点击 + 键盘输入。

⚠️ 这是"Agent 直接操作用户真实电脑"的执行层，误操作后果真实可见（删文件、发消息、
点支付）。因此五道安全防线是设计前提，不是可选项：
  1) 辅助功能权限：无权限时明确报错并给出授权路径，不静默失败
  2) 显式总开关 + 默认关闭：computer_use_enabled=False（配置层）
  3) 每步动作确认：computer_use_confirm_each=True（loop 层经 authorizer 弹窗）
  4) 应用白名单：computer_use_app_whitelist（越界拒绝）
  5) 一键急停 + 全程日志：本模块每个动作都写日志到 <data_root>/computer_use/

技术选型（2026-09-06 实测验证，零第三方依赖）：
- 截屏：macOS 内置 /usr/sbin/screencapture（0.26s/次）
- 点击/键盘：**ctypes 直调 CoreGraphics**（CGEventCreateMouseEvent / CGEventPost /
  CGEventCreateKeyboardEvent / CGEventKeyboardSetUnicodeString）。

  ⭐ 事件是【真实的】，不是"模拟"：CGEventPost 投递到 kCGHIDEventTap（硬件事件通道），
  与物理鼠标键盘走同一条路径，目标应用无法区分，不存在"某些软件识别异常"的问题
  （cliclick 等工具内部也是这套 API）。

  ⛔ 为什么不用 JXA（曾实现过，实测有缺陷，已弃用）：JXA 无法构造
  `CGEventKeyboardSetUnicodeString` 需要的 `const UniChar *` 缓冲区——实测
  `$.Array` 与 `$.Ref` 均为 undefined，把 JS 字符串直接传进去会让中文输入
  静默失效或乱码。ctypes 可显式构造 UTF-16 码元数组，实测中文/英文/标点/
  制表符/换行/代理对（emoji）全部正确往返。
  ⛔ 也不用 AppleScript System Events：它只能操作 UI 元素，`click at {x,y}`
  报错 -25200，不支持任意坐标；且 keystroke 走的是另一条路径，兼容性差。
  ⛔ cliclick / pyobjc(Quartz) 均未安装，故 ctypes（stdlib）是唯一零依赖路径。

- ⛔ Retina 缩放：screencapture 输出【像素】（实测 3456x2234），而 CoreGraphics
  点击用的是【逻辑点】（实测 1728x1117，比例恰好 2.000）。视觉模型看的是图片，
  给出的是像素坐标——必须乘 coord_factor 换算后再点，否则点击位置偏移一倍。
  ⛔ coord_factor = 逻辑宽 / 发送宽（不是 降采样比 × Retina 比，那是它的倒数，
  实测会让中心点偏 153 点）。本模块自动算好并在截屏结果中返回。
- 截图 8.5MB 过大：喂视觉模型前先降采样（长边 ≤1568，兼顾识别精度与上下文开销）。
"""
from __future__ import annotations

import base64
import ctypes
import ctypes.util
import json
import os
import re
import subprocess
import sys
import time
from ctypes import POINTER, Structure, byref, c_bool, c_double, c_int64, c_uint16, c_uint32, c_void_p
from datetime import datetime
from pathlib import Path
from typing import Any

# 协议常量（非用户可配路径）
SCREENSHOT_LONG_EDGE = 1568     # 降采样后长边上限（视觉模型常用输入尺寸）
SCREENSHOT_JPEG_QUALITY = 78    # JPEG 质量（体积与可辨识度平衡）
OSASCRIPT_TIMEOUT = 12.0        # 单次 osascript 调用超时（秒；仅前台应用名探测仍用 AppleScript）
CAPTURE_TIMEOUT = 15.0          # 单次截屏超时（秒）
MAX_TYPE_CHARS = 2000           # 单次输入字符上限（防超长文本卡死）
TYPE_CHUNK_CHARS = 32           # 单个键盘事件承载的字符数（分块发送，避免超长事件被截断）
LOG_KEEP = 500                  # 动作日志保留条数（内存环形；落盘为 append）

# ── CoreGraphics 事件常量（CGEventTypes.h / CGEventSource.h）──────────────
_K_CG_HID_EVENT_TAP = 0          # kCGHIDEventTap：硬件通道，事件与物理键鼠同源
_K_CG_EVENT_MOUSE_MOVED = 5
_K_CG_EVENT_LEFT_MOUSE_DOWN = 1
_K_CG_EVENT_LEFT_MOUSE_UP = 2
_K_CG_EVENT_RIGHT_MOUSE_DOWN = 3
_K_CG_EVENT_RIGHT_MOUSE_UP = 4
_K_CG_MOUSE_EVENT_CLICK_STATE = 1
_K_CG_KEYBOARD_EVENT_KEYCODE = 9


class _CGPoint(Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


_CG = None          # 惰性加载的 CoreGraphics 句柄
_CG_ERR = ""        # 加载失败原因（供报错时给出可读指引）


def _cg():
    """惰性加载 CoreGraphics 并声明全部用到的函数签名。

    ⛔ 必须显式声明 argtypes/restype：ctypes 默认按 int 传参，CGPoint 结构与
    UniChar* 指针会被截断或错位，导致点击落到错误位置、输入乱码。
    """
    global _CG, _CG_ERR
    if _CG is not None:
        return _CG
    try:
        path = ctypes.util.find_library("CoreGraphics") or \
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        cg = ctypes.CDLL(path)
        cf_path = ctypes.util.find_library("CoreFoundation") or \
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        cf = ctypes.CDLL(cf_path)

        cf.CFRelease.argtypes = [c_void_p]
        cf.CFRelease.restype = None

        cg.CGEventCreateMouseEvent.restype = c_void_p
        cg.CGEventCreateMouseEvent.argtypes = [c_void_p, c_uint32, _CGPoint, c_uint32]
        cg.CGEventCreateKeyboardEvent.restype = c_void_p
        cg.CGEventCreateKeyboardEvent.argtypes = [c_void_p, c_uint16, c_bool]
        cg.CGEventPost.argtypes = [c_uint32, c_void_p]
        cg.CGEventPost.restype = None
        cg.CGEventSetFlags.argtypes = [c_void_p, c_uint64_flags()]
        cg.CGEventSetFlags.restype = None
        cg.CGEventSetIntegerValueField.argtypes = [c_void_p, c_uint32, c_int64]
        cg.CGEventSetIntegerValueField.restype = None
        cg.CGEventKeyboardSetUnicodeString.argtypes = [c_void_p, c_uint32, POINTER(c_uint16)]
        cg.CGEventKeyboardSetUnicodeString.restype = None
        cg.CGMainDisplayID.restype = c_uint32
        cg.CGMainDisplayID.argtypes = []
        cg.CGDisplayPixelsWide.restype = c_uint32   # 返回【逻辑点】宽（非像素）
        cg.CGDisplayPixelsWide.argtypes = [c_uint32]
        cg.CGDisplayPixelsHigh.restype = c_uint32
        cg.CGDisplayPixelsHigh.argtypes = [c_uint32]
        # 事件源：用 CGEventSourceCreate 拿到独立源，比 NULL 更贴近真实设备语义
        cg.CGEventSourceCreate.restype = c_void_p
        cg.CGEventSourceCreate.argtypes = [c_int64]

        cg._cf = cf          # 挂在句柄上便于统一 CFRelease
        _CG = cg
        _CG_ERR = ""
        return _CG
    except Exception as e:
        _CG_ERR = f"{type(e).__name__}: {e}"
        return None


def c_uint64_flags():
    """CGEventFlags 是 uint64（修饰键掩码可达 1<<23 以上，不能用 uint32）。"""
    return ctypes.c_uint64


def _cg_error(action: str) -> dict[str, Any]:
    """CoreGraphics 不可用时的统一可读报错（防线1：不静默失败）。"""
    return {"ok": False, "error": (
        f"{action}_unavailable: 无法调用 CoreGraphics（{_CG_ERR or '未知原因'}）。"
        "Computer Use 一期仅支持 macOS，且需要系统框架可用；"
        "请确认运行在 macOS 上，或到 设置 → Computer Use 点「检测权限」查看详情。")}


def _process_identity() -> dict[str, Any]:
    """返回本进程的可执行路径与代码签名状况。

    ⛔ 关键：macOS 的辅助功能授权（TCC）是**按二进制文件**授予的，不是按 .app 名字。
    Computer Use 的事件由【侧车二进制】发出（Contents/Resources/sidecar/vetarai-sidecar），
    而不是 Electron 主程序（Contents/MacOS/VetarAI）。用户若只给"VetarAI"授权，
    侧车进程依然不被信任 → AXIsProcessTrusted 仍为 False → 事件被静默丢弃。
    故必须把【实际发事件的那个二进制路径】告诉用户。

    另：本应用当前为 **ad-hoc 签名**（未做 Developer ID 签名），每次重新打包签名指纹都会变，
    TCC 授权会失效需重新授予——这是"明明授权过却又没了"的常见原因。
    """
    out: dict[str, Any] = {"exe": "", "adhoc": None}
    try:
        out["exe"] = str(Path(sys.executable).resolve())
    except Exception:
        try:
            out["exe"] = str(Path(os.__file__).resolve())
        except Exception:
            pass
    exe = out["exe"]
    if exe and Path(exe).exists():
        try:
            r = subprocess.run(["codesign", "-dv", exe], capture_output=True,
                               text=True, timeout=OSASCRIPT_TIMEOUT)
            info = (r.stderr or "") + (r.stdout or "")
            if "adhoc" in info:
                out["adhoc"] = True
            elif "Authority=" in info:
                out["adhoc"] = False
            m = re.search(r"Identifier=([^\n]+)", info)
            if m:
                out["identifier"] = m.group(1).strip()
        except Exception:
            pass
    return out


def _ax_trusted() -> bool | None:
    """辅助功能权限（AXIsProcessTrusted）。读不到时返回 None（不作判断依据）。

    无此权限时 CGEventPost 会被系统静默丢弃——事件"发出去了"但没有任何效果，
    这是最难排查的失败模式，故必须提前探测并明确告知用户授权路径。
    """
    try:
        path = ctypes.util.find_library("ApplicationServices") or \
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        app = ctypes.CDLL(path)
        app.AXIsProcessTrusted.restype = c_bool
        app.AXIsProcessTrusted.argtypes = []
        return bool(app.AXIsProcessTrusted())
    except Exception:
        return None


def _to_utf16_units(text: str) -> list[int]:
    """把 Python 字符串转成 UTF-16 码元序列（UniChar[]）。

    ⛔ 必须手动拆代理对：CGEventKeyboardSetUnicodeString 收的是 UniChar（UTF-16），
    而 Python 的 ord() 给的是完整码点。码点 >0xFFFF（emoji、数学符号等）若不拆成
    高低代理对，目标应用会收到非法字符。
    """
    units: list[int] = []
    for ch in text:
        cp = ord(ch)
        if cp > 0xFFFF:
            cp -= 0x10000
            units.append(0xD800 + (cp >> 10))       # 高代理
            units.append(0xDC00 + (cp & 0x3FF))     # 低代理
        else:
            units.append(cp)
    return units


def _data_root() -> Path:
    from sidecar.config import data_root
    return data_root()


def _log_dir() -> Path:
    d = _data_root() / "computer_use"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _audit(action: str, detail: dict) -> None:
    """全程日志（防线5）：每个动作落盘一行 JSON，可回溯"Agent 到底做了什么"。

    日志写失败绝不影响动作本身（审计是辅助，不是主流程）。
    """
    try:
        rec = {"ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
               "action": action, **detail}
        with open(_log_dir() / "actions.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


# ── 权限与能力探测（防线1）──────────────────────────────────────────────

def check_capabilities() -> dict[str, Any]:
    """探测本机是否具备 Computer Use 所需能力，返回可读结论。

    不做任何有副作用的操作（不点击、不输入），只读探测。
    """
    out: dict[str, Any] = {"ok": True, "problems": [], "facts": {}}

    if os.uname().sysname != "Darwin":
        out["ok"] = False
        out["problems"].append("本机不是 macOS，一期 MVP 仅支持 macOS（screencapture + CoreGraphics/ctypes）")
        return out

    for tool, path in (("screencapture", "/usr/sbin/screencapture"),
                       ("osascript", "/usr/bin/osascript")):
        if not Path(path).exists():
            out["ok"] = False
            out["problems"].append(f"缺少系统命令 {tool}（预期在 {path}）")

    # CoreGraphics 事件接口能否经 ctypes 调用（只读，不发送任何事件）
    cg = _cg()
    if cg is None:
        out["ok"] = False
        out["facts"]["coregraphics"] = f"不可用（{_CG_ERR}）"
        out["problems"].append(f"无法加载 CoreGraphics 事件接口：{_CG_ERR}")
    else:
        need = ("CGEventCreateMouseEvent", "CGEventPost", "CGEventCreateKeyboardEvent",
                "CGEventKeyboardSetUnicodeString")
        missing = [n for n in need if not hasattr(cg, n)]
        out["facts"]["coregraphics"] = "ok(ctypes 直调，4/4 接口可用)" if not missing \
            else f"缺接口: {missing}"
        if missing:
            out["ok"] = False
            out["problems"].append(f"CoreGraphics 缺少必需接口：{missing}")

    # 防线1：辅助功能权限。无此权限时 CGEventPost 会被系统【静默丢弃】——
    # 事件"发出去了"却毫无效果，是最难排查的失败模式，故必须提前探测。
    ax = _ax_trusted()
    out["facts"]["accessibility_trusted"] = ax
    ident = _process_identity()
    out["facts"]["process_exe"] = ident.get("exe") or ""
    out["facts"]["codesign_identifier"] = ident.get("identifier") or ""
    out["facts"]["adhoc_signed"] = ident.get("adhoc")
    if ax is False:
        out["ok"] = False
        _exe = ident.get("exe") or "侧车二进制"
        out["problems"].append(
            "辅助功能权限未授予——点击与输入会被系统静默丢弃（看似执行成功实则无效）。\n"
            "⚠️ macOS 按【二进制文件】授权，而发出事件的是侧车进程，不是 Electron 主程序；"
            "只在列表里勾选 VetarAI 往往不够。请把下面这个文件本身加入名单：\n"
            f"    {_exe}\n"
            "操作：系统设置 → 隐私与安全性 → 辅助功能 → 点「+」→ 按 Cmd+Shift+G 粘贴上述路径 "
            "→ 添加并勾选 → 完全退出 VetarAI（Cmd+Q）后重开。\n"
            "注意：添加后必须【重启应用】才生效（权限在进程启动时读取）。")
        if ident.get("adhoc") is True:
            out["problems"].append(
                "本应用为 ad-hoc 签名（未做 Developer ID 签名），每次重新打包签名指纹都会变化，"
                "系统会把它当成「另一个程序」而让已授予的权限失效。因此每次安装新版本后，"
                "需要到辅助功能列表里把旧条目删掉再重新添加。")
    elif ax is None:
        out["problems"].append(
            "无法探测辅助功能权限（AXIsProcessTrusted 不可用）；若点击/输入无效，"
            "请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 VetarAI。")

    # 屏幕录制权限：截一张图看是否非空（截图本身无副作用）
    shot = take_screenshot()
    if not shot.get("ok"):
        out["ok"] = False
        out["problems"].append(f"截屏失败：{shot.get('error')}")
    else:
        out["facts"]["screen_points"] = f"{shot['width_points']}x{shot['height_points']}"
        out["facts"]["screenshot_px"] = f"{shot['width_px']}x{shot['height_px']}"
        out["facts"]["retina_scale"] = shot["scale"]
        # 辅助功能权限：System Events 能枚举前台进程名即视为已授予（只读）
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get name of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=OSASCRIPT_TIMEOUT)
        front = (r.stdout or "").strip()
        if front and "execution error" not in (r.stderr or ""):
            out["facts"]["frontmost_app"] = front
            out["facts"]["accessibility"] = True
        else:
            out["facts"]["accessibility"] = False
            out["problems"].append(
                "辅助功能权限未授予（点击/输入会静默无效）。请到 "
                "系统设置 → 隐私与安全性 → 辅助功能，勾选 VetarAI 后重试。")
    except Exception as e:
        out["facts"]["accessibility"] = False
        out["problems"].append(f"辅助功能权限探测失败：{type(e).__name__}: {e}")

    return out


_GEOM_CACHE: tuple[int, int] | None = None


def _screen_geometry() -> tuple[int, int]:
    """返回主屏 (逻辑宽, 逻辑高)，单位是点（CoreGraphics 点击坐标系）。

    实测：CGDisplayPixelsWide/High 在当前缩放模式下返回【逻辑点】（1728x1117），
    与 CGEvent 坐标系一致；而 screencapture 输出【像素】（3456x2234）。
    屏幕尺寸在一次会话内不变，故缓存（省掉每次动作一次系统调用）。
    失败时返回 (0, 0)，由调用方兜底（如按 Retina 2x 反推）。
    """
    global _GEOM_CACHE
    if _GEOM_CACHE is not None:
        return _GEOM_CACHE
    logic_w = logic_h = 0
    try:
        cg = _cg()
        if cg is not None:
            did = cg.CGMainDisplayID()
            if did:
                logic_w = int(cg.CGDisplayPixelsWide(did) or 0)
                logic_h = int(cg.CGDisplayPixelsHigh(did) or 0)
    except Exception:
        logic_w = logic_h = 0
    _GEOM_CACHE = (logic_w, logic_h)
    return logic_w, logic_h


# ── 截屏（防线5 日志；无副作用）─────────────────────────────────────────

def take_screenshot(max_long_edge: int = SCREENSHOT_LONG_EDGE) -> dict[str, Any]:
    """截全屏 → 降采样 → JPEG → base64 data URI（供视觉模型看）。

    ⛔ Retina 处理：screencapture 输出像素图，同时用 CoreGraphics 读逻辑点尺寸，
    返回 scale（=像素/逻辑，实测 2.0）。调用方点击时必须把视觉模型给的
    像素坐标除以 scale，否则会偏移一倍。
    """
    tmp_png = Path(_log_dir()) / f"_shot_{os.getpid()}_{int(time.time()*1000)}.png"
    try:
        # -x 静默（不播快门声）；不用 -C（不抓光标，避免干扰视觉判断）
        r = subprocess.run(["/usr/sbin/screencapture", "-x", str(tmp_png)],
                           capture_output=True, text=True, timeout=CAPTURE_TIMEOUT)
        if r.returncode != 0 or not tmp_png.exists() or tmp_png.stat().st_size < 1000:
            err = (r.stderr or r.stdout or "").strip()[:200]
            return {"ok": False, "error": (
                f"截屏失败：{err or '无输出'}。若为空白/报错，请到 系统设置 → 隐私与安全性 → "
                "屏幕录制 勾选 VetarAI 后重试。")}

        from PIL import Image
        im = Image.open(tmp_png)
        w_px, h_px = im.size
        if im.mode not in ("RGB", "L"):
            im = im.convert("RGB")

        # 降采样（长边限制）：8.5MB 原图直接喂模型会撑爆上下文
        scale_down = 1.0
        if max(w_px, h_px) > max_long_edge:
            scale_down = max_long_edge / float(max(w_px, h_px))
            im = im.resize((max(1, int(w_px * scale_down)), max(1, int(h_px * scale_down))),
                           Image.LANCZOS)
        out_w, out_h = im.size

        # Retina 缩放比：像素 / 逻辑点（用于把模型给的坐标换算成点击坐标）
        logic_w, logic_h = _screen_geometry()
        if logic_w and logic_h:
            retina = round(w_px / float(logic_w), 3)
        else:
            retina = 2.0   # 兜底：Apple Silicon Mac 几乎都是 2x
            logic_w, logic_h = int(w_px / retina), int(h_px / retina)

        # 视觉模型看到的图是被降采样过的 → 它给的坐标是"降采样图坐标系"。
        # 点击需要"逻辑点坐标系"，换算系数 = 逻辑宽 / 发送宽（等价于 逻辑高/发送高，
        # 因为降采样是等比的）。
        # ⛔ 不要用 scale_down × retina —— 那是它的【倒数】，会导致点击位置系统性偏移
        #   （实测：发送图中心 784 应映射到逻辑 864，用倒数算出 711，偏了 153 点）。
        # 例：3456px 原图 →1568px 给模型，逻辑宽 1728 → factor = 1728/1568 = 1.102
        #     未降采样的小屏（sent_w == w_px）时 factor = 1728/3456 = 0.5 = 1/retina，同样成立。
        coord_factor = round((logic_w / float(out_w)) if out_w else 1.0, 6)

        import io
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=SCREENSHOT_JPEG_QUALITY)
        b64 = base64.b64encode(buf.getvalue()).decode("ascii")
        _audit("screenshot", {"px": f"{w_px}x{h_px}", "sent": f"{out_w}x{out_h}",
                              "retina": retina, "coord_factor": coord_factor,
                              "bytes": len(buf.getvalue())})
        return {"ok": True, "_kind": "image",
                "image_base64": b64,
                "mime": "image/jpeg",
                "width_px": w_px, "height_px": h_px,
                "width_sent": out_w, "height_sent": out_h,
                "width_points": logic_w, "height_points": logic_h,
                "scale": retina,
                # ⭐ 调用方必须用它换算坐标：逻辑点 = 模型给的坐标 × coord_factor
                "coord_factor": coord_factor,
                "size": len(buf.getvalue()),
                "content": (f"[已截屏：原图 {w_px}x{h_px}px，发送 {out_w}x{out_h}px，"
                            f"屏幕逻辑尺寸 {logic_w}x{logic_h}点。"
                            f"你看到的图是缩放过的：点击前必须把图上量到的像素坐标乘以 "
                            f"coord_factor={coord_factor} 换算成屏幕坐标，否则会点偏。")
                }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"截屏超时（>{CAPTURE_TIMEOUT}s）"}
    except Exception as e:
        return {"ok": False, "error": f"截屏异常：{type(e).__name__}: {e}"}
    finally:
        try:
            tmp_png.unlink(missing_ok=True)
        except Exception:
            pass


# ── 事件执行器（点击 / 输入 / 按键）：ctypes 直调 CoreGraphics，真实 HID 事件 ──

def _safe_num(v: Any) -> float | None:
    """坐标安全转换：只接受有限数字，拒绝 NaN/inf/字符串（防非法事件参数）。"""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):   # NaN / inf
        return None
    return f


_CODE_TO_MOD = {55: "cmd", 56: "shift", 58: "option", 59: "ctrl", 63: "fn"}


def _mods_name(keycode: int) -> str:
    """修饰键 keycode → 名字（用于查 _MOD_FLAGS 取标志位）。"""
    return _CODE_TO_MOD.get(keycode, "")


def _event_source() -> Any:
    """CGEventSource：用"组合态 HID 系统"源，语义最贴近真实设备。
    创建失败时回落 None（CoreGraphics 允许，事件仍会被投递）。"""
    try:
        cg = _cg()
        if cg is None:
            return None
        src = cg.CGEventSourceCreate(1)   # kCGEventSourceStateCombinedSessionState
        return c_void_p(src) if src else None
    except Exception:
        return None


def _post(cg, ev) -> None:
    """投递事件到 HID 通道并释放事件对象（防泄漏：每个 CGEvent 都必须 CFRelease）。"""
    try:
        cg.CGEventPost(_K_CG_HID_EVENT_TAP, ev)
    finally:
        try:
            cg._cf.CFRelease(c_void_p(ev))
        except Exception:
            pass


def mouse_click(x: float, y: float, button: str = "left", clicks: int = 1) -> dict[str, Any]:
    """在【逻辑点】坐标 (x,y) 真实点击。

    ⭐ 事件真实性：经 CGEventPost 投递到 kCGHIDEventTap（硬件事件通道），与物理鼠标
    走同一条路径，目标应用无法区分——不存在"模拟点击被软件识别为异常"的问题。

    ⚠️ 调用方必须先把视觉模型给的【图片像素坐标】乘 coord_factor 换算成逻辑点
    （见 take_screenshot），否则会点偏（Retina 下偏一倍）。
    button: left / right；clicks: 1（单击）或 2（双击）。
    """
    px, py = _safe_num(x), _safe_num(y)
    if px is None or py is None:
        return {"ok": False, "error": f"bad_arg: 坐标必须是数字（收到 x={x!r}, y={y!r}）"}
    # 逻辑点合理范围：屏幕尺寸 + 容差（拒绝明显越界坐标，防误操作到别处）
    lw, lh = _screen_geometry()
    if lw and lh and (px < -20 or py < -20 or px > lw + 20 or py > lh + 20):
        return {"ok": False, "error": (
            f"coord_out_of_range: 坐标 ({px:.0f},{py:.0f}) 超出屏幕逻辑范围 "
            f"{lw}x{lh}。你给的可能是【图片像素坐标】未换算——请乘以 coord_factor 再试。")}
    btn = str(button or "left").lower()
    if btn not in ("left", "right"):
        return {"ok": False, "error": f"bad_arg: button 只能是 left 或 right（收到 {button!r}）"}
    try:
        n = int(clicks)
    except (TypeError, ValueError):
        n = 1
    n = 2 if n >= 2 else 1

    cg = _cg()
    if cg is None:
        return _cg_error("click")
    # 防线1：无辅助功能权限时 CGEventPost 会被系统静默丢弃（看似成功实则无效），
    # 提前拦截并给出授权路径，避免用户白等还查不出原因。
    if _ax_trusted() is False:
        return {"ok": False, "error": (
            "accessibility_denied: 辅助功能权限未授予，点击会被系统静默丢弃。"
            "请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 VetarAI 后重试。")}

    down_t = _K_CG_EVENT_LEFT_MOUSE_DOWN if btn == "left" else _K_CG_EVENT_RIGHT_MOUSE_DOWN
    up_t = _K_CG_EVENT_LEFT_MOUSE_UP if btn == "left" else _K_CG_EVENT_RIGHT_MOUSE_UP
    btn_num = 0 if btn == "left" else 1
    src = _event_source()
    pt = _CGPoint(px, py)
    try:
        # 先移动光标到目标点：部分应用要求光标已就位才响应点击（如悬停态菜单）
        mv = cg.CGEventCreateMouseEvent(src, _K_CG_EVENT_MOUSE_MOVED, pt, 0)
        if mv:
            _post(cg, mv)
        time.sleep(0.03)
        for i in range(1, n + 1):
            for evt_type in (down_t, up_t):
                ev = cg.CGEventCreateMouseEvent(src, evt_type, pt, btn_num)
                if not ev:
                    _audit("click", {"x": px, "y": py, "button": btn, "clicks": n,
                                     "ok": False, "err": "CGEventCreateMouseEvent 返回空"})
                    return {"ok": False, "error": (
                        "click_failed: 系统拒绝创建鼠标事件（CGEventCreateMouseEvent 返回空）。"
                        "请确认已授予辅助功能权限。")}
                if i > 1:
                    # 双击：第二次 down/up 必须带 clickState，否则系统当两次单击处理
                    cg.CGEventSetIntegerValueField(ev, _K_CG_MOUSE_EVENT_CLICK_STATE, i)
                _post(cg, ev)
                time.sleep(0.02)
            if i < n:
                time.sleep(0.06)
    except Exception as e:
        _audit("click", {"x": px, "y": py, "button": btn, "clicks": n,
                         "ok": False, "err": f"{type(e).__name__}: {e}"})
        return {"ok": False, "error": f"click_failed: {type(e).__name__}: {e}"}
    finally:
        if src:
            try:
                cg._cf.CFRelease(src)
            except Exception:
                pass

    _audit("click", {"x": round(px, 1), "y": round(py, 1), "button": btn,
                     "clicks": n, "ok": True,
                     "screen_points": f"{lw}x{lh}"})
    return {"ok": True, "action": "click", "x": px, "y": py, "button": btn, "clicks": n,
            "content": f"已在逻辑点 ({px:.0f},{py:.0f}) {btn}键点击{n}次",
            "hint": "操作后界面可能已变化，继续下一步前请先 screen_view 重新截屏核对结果。"}


def keyboard_type(text: str) -> dict[str, Any]:
    """真实键盘输入文本（支持中文、标点、emoji、制表符与换行）。

    ⭐ 实现：CGEventCreateKeyboardEvent + CGEventKeyboardSetUnicodeString，经
    CGEventPost 投递到 HID 通道——与物理键盘同一路径，目标应用按真实按键处理。

    ⛔ 为什么不用 keycode 映射：那样只能敲 ASCII 键位，无法输入中文/emoji/特殊符号。
    ⛔ 为什么不用 JXA：JXA 无法构造 CGEventKeyboardSetUnicodeString 需要的
    `const UniChar *` 缓冲区（实测 $.Array / $.Ref 均为 undefined），中文会静默失效。
    ctypes 可显式构造 UTF-16 码元数组，实测中文/英文/标点/制表符/代理对全部正确。
    """
    if not isinstance(text, str) or not text:
        return {"ok": False, "error": "bad_arg: text 必须是非空字符串"}
    if len(text) > MAX_TYPE_CHARS:
        return {"ok": False, "error": (
            f"too_long: 单次输入上限 {MAX_TYPE_CHARS} 字符（收到 {len(text)}），请分段输入")}

    cg = _cg()
    if cg is None:
        return _cg_error("type")
    if _ax_trusted() is False:
        return {"ok": False, "error": (
            "accessibility_denied: 辅助功能权限未授予，输入会被系统静默丢弃。"
            "请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 VetarAI 后重试。")}

    # ⛔ 必须手动拆 UTF-16 代理对：Python ord() 给完整码点，而 UniChar 是 UTF-16。
    # 码点 >0xFFFF（emoji、数学符号）不拆则目标应用收到非法字符。
    units = _to_utf16_units(text)
    src = _event_source()
    typed_units = 0
    try:
        # 分块发送：单个事件承载过多字符时部分应用会截断，故按 TYPE_CHUNK_CHARS 分块
        for start in range(0, len(units), TYPE_CHUNK_CHARS):
            chunk = units[start:start + TYPE_CHUNK_CHARS]
            buf = (c_uint16 * len(chunk))(*chunk)
            for is_down in (True, False):
                ev = cg.CGEventCreateKeyboardEvent(src, 0, is_down)
                if not ev:
                    return {"ok": False, "error": (
                        "type_failed: 系统拒绝创建键盘事件（CGEventCreateKeyboardEvent 返回空）。"
                        "请确认已授予辅助功能权限。")}
                try:
                    # 同一份 Unicode 载荷必须同时挂在 down 与 up 上（只挂 down 会丢字符）
                    cg.CGEventKeyboardSetUnicodeString(ev, len(chunk), buf)
                    _post(cg, ev)
                except Exception:
                    try:
                        cg._cf.CFRelease(c_void_p(ev))
                    except Exception:
                        pass
                    raise
                time.sleep(0.004)
            typed_units += len(chunk)
    except Exception as e:
        _audit("type", {"chars": len(text), "units": typed_units, "preview": text[:40],
                        "ok": False, "err": f"{type(e).__name__}: {e}"})
        return {"ok": False, "error": (
            f"type_failed: {type(e).__name__}: {e}。"
            "请确认已授予辅助功能权限，且目标输入框已获得焦点（先用 mouse_click 点它）。")}
    finally:
        if src:
            try:
                cg._cf.CFRelease(src)
            except Exception:
                pass

    _audit("type", {"chars": len(text), "units": typed_units,
                    "preview": text[:40], "ok": True})
    return {"ok": True, "action": "type", "chars": len(text), "units": typed_units,
            "content": f"已输入 {len(text)} 个字符（{typed_units} 个 UTF-16 码元）",
            "hint": "操作后界面可能已变化，继续下一步前请先 screen_view 重新截屏核对结果。"}



# 常用按键的虚拟键码（ANSI layout，macOS 标准）
_KEYCODES = {
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
    "backspace": 51, "escape": 53, "esc": 53, "left": 123, "right": 124,
    "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116,
    "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
    "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
    "f12": 111,
    # 修饰键
    "cmd": 55, "command": 55, "meta": 55, "shift": 56, "capslock": 57,
    "option": 58, "alt": 58, "ctrl": 59, "control": 59, "fn": 63,
    # 常用字母/数字（组合键需要）
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
    "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
    "m": 46,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "7": 26,
    "8": 28, "9": 25,
}

# 修饰键标志位
_MOD_FLAGS = {"cmd": 1048576, "command": 1048576, "meta": 1048576,
              "shift": 131072, "option": 524288, "alt": 524288,
              "ctrl": 262144, "control": 262144, "fn": 8388608}


def keyboard_hotkey(keys: str) -> dict[str, Any]:
    """按键或组合键，如 "return" / "cmd+c" / "cmd+shift+4" / "esc"。"""
    if not isinstance(keys, str) or not keys.strip():
        return {"ok": False, "error": "bad_arg: keys 必须是非空字符串（如 'cmd+c'）"}
    parts = [p.strip().lower() for p in keys.split("+") if p.strip()]
    if not parts:
        return {"ok": False, "error": "bad_arg: keys 解析后为空"}
    if len(parts) > 4:
        return {"ok": False, "error": f"bad_arg: 组合键最多 4 个键（收到 {len(parts)} 个）"}

    mods, main = [], None
    for p in parts:
        if p in _MOD_FLAGS and p not in ("cmd", "command", "meta"):
            mods.append(p)
        elif p in _MOD_FLAGS:
            mods.append("cmd")
        else:
            if main is not None:
                return {"ok": False, "error": (
                    f"bad_arg: 组合键只能有一个主键（收到 {main!r} 与 {p!r}）")}
            main = p
    if main is None:
        # 纯修饰键（如只按 shift）：单独按下抬起
        main = mods.pop() if mods else parts[0]
    if main not in _KEYCODES:
        return {"ok": False, "error": (
            f"unknown_key: 不认识按键 {main!r}。支持的键："
            f"{', '.join(sorted({k for k in _KEYCODES if k not in _MOD_FLAGS}))[:400]}")}

    flag = 0
    for m in mods:
        flag |= _MOD_FLAGS.get(m, 0)
    code = _KEYCODES[main]

    cg = _cg()
    if cg is None:
        return _cg_error("hotkey")
    if _ax_trusted() is False:
        return {"ok": False, "error": (
            "accessibility_denied: 辅助功能权限未授予，按键会被系统静默丢弃。"
            "请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 VetarAI 后重试。")}

    # ⭐ 真实硬件按键序列：修饰键也要【真的按下再抬起】，不能只设 flags 位。
    # 只设 flags 而不发修饰键的 keyDown 时，部分应用的内部修饰键状态与事件不同步，
    # 会出现"快捷键时灵时不灵"或"修饰键粘滞"（下次点击仍被当成 cmd+点击）——
    # 这正是用户担心的"模拟输入导致软件识别异常"的典型成因。
    # 正确顺序：修饰键依次 down（flags 累加）→ 主键 down/up → 修饰键逆序 up（flags 递减）。
    src = _event_source()
    mod_codes = [_KEYCODES[m] for m in mods if m in _KEYCODES]
    posted: list[int] = []     # 已按下的修饰键，异常时用于兜底抬起（防粘滞）

    def _key(keycode: int, is_down: bool, flags: int) -> bool:
        ev = cg.CGEventCreateKeyboardEvent(src, keycode, is_down)
        if not ev:
            return False
        try:
            if flags:
                cg.CGEventSetFlags(ev, flags)
            _post(cg, ev)
            return True
        except Exception:
            try:
                cg._cf.CFRelease(c_void_p(ev))
            except Exception:
                pass
            raise

    try:
        acc = 0
        for mc in mod_codes:                    # 修饰键依次按下，flags 累加
            acc |= _MOD_FLAGS.get(_mods_name(mc), 0)
            if not _key(mc, True, acc):
                return {"ok": False, "error": (
                    "hotkey_failed: 系统拒绝创建修饰键事件。请确认已授予辅助功能权限。")}
            posted.append(mc)
            time.sleep(0.012)
        if not _key(code, True, acc):           # 主键按下
            return {"ok": False, "error": (
                "hotkey_failed: 系统拒绝创建按键事件。请确认已授予辅助功能权限。")}
        time.sleep(0.02)
        _key(code, False, acc)                  # 主键抬起
        time.sleep(0.012)
        for mc in reversed(posted):             # 修饰键逆序抬起，flags 递减
            acc &= ~_MOD_FLAGS.get(_mods_name(mc), 0)
            _key(mc, False, acc)
            time.sleep(0.012)
        posted = []
    except Exception as e:
        # 兜底：把还按着的修饰键全部抬起，避免用户键盘"卡在 cmd 状态"
        for mc in reversed(posted):
            try:
                _key(mc, False, 0)
            except Exception:
                pass
        _audit("hotkey", {"keys": keys, "code": code, "flag": flag,
                          "ok": False, "err": f"{type(e).__name__}: {e}"})
        return {"ok": False, "error": f"hotkey_failed: {type(e).__name__}: {e}"}
    finally:
        if src:
            try:
                cg._cf.CFRelease(src)
            except Exception:
                pass

    _audit("hotkey", {"keys": keys, "code": code, "flag": flag, "mods": mods,
                      "ok": True})
    return {"ok": True, "action": "hotkey", "keys": keys,
            "content": f"已按下组合键 {keys}",
            "hint": "操作后界面可能已变化，继续下一步前请先 screen_view 重新截屏核对结果。"}


# ── 前台应用（白名单校验用，防线4）──────────────────────────────────────

def frontmost_app() -> str:
    """当前前台应用名（读不到返回空串）。白名单校验与日志都用它。"""
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get name of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=OSASCRIPT_TIMEOUT)
        if r.returncode == 0:
            return (r.stdout or "").strip()
    except Exception:
        pass
    return ""


def check_whitelist(whitelist: list[str]) -> dict[str, Any]:
    """防线4：白名单非空时，校验当前前台应用是否在其中。

    返回 {ok: bool, app: str, reason: str}。白名单为空 = 不限制（仍受每步确认约束）。
    """
    # 保留用户原始输入（含大小写）用于报错展示——此前统一小写化，导致用户填
    # "Safari" 却在报错里看到 "safari"，会怀疑自己填错了。仅比较时小写化。
    raw = [str(x).strip() for x in (whitelist or []) if str(x).strip()]
    app = frontmost_app()
    if not raw:
        return {"ok": True, "app": app, "reason": ""}
    if not app:
        return {"ok": False, "app": "", "reason": (
            "无法读取当前前台应用名（可能辅助功能权限未授予），"
            "在配置了应用白名单的情况下无法确认是否越界，已拒绝操作。")}
    low = app.lower()
    for w in raw:
        lw = w.lower()
        if low == lw or low.startswith(lw) or lw in low:
            return {"ok": True, "app": app, "reason": ""}
    return {"ok": False, "app": app, "reason": (
        f"当前前台应用「{app}」不在允许操作的白名单内（白名单：{'、'.join(raw)}），已拒绝操作。"
        "如需操作该应用，请到 设置 → Computer Use 把它加入白名单。")}
