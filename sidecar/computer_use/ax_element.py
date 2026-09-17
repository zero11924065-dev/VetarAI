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
"""0.4.32（CU 二期 P0，REQ-FUT-005 路径①）AX 元素定位：ctypes 直调 ApplicationServices。

设计（2026-09-18 技术选型实测结论，E1「命中测试优先、局部枚举兜底」）：
- **命中测试**：AXUIElementCreateSystemWide + AXUIElementCopyElementAtPosition，
  给屏幕坐标直接取该点元素及精确 frame，实测 18~51ms/次；元素 AXPosition/AXSize
  即屏幕【绝对逻辑点】，与 executor.mouse_click 的坐标系**完全一致、零换算**。
  最佳用法＝视觉模型给近似坐标 → hit_test 取精确 frame → 点 frame 中心。
- **局部枚举兜底**：app_elements(app, depth≤2) 只枚举目标 app 的窗口 + 一层/两层
  子元素（实测一层 147 节点 52.7ms）。
- 权限：AX 读树与 CGEventPost 共用同一个「辅助功能」TCC 授权，复用
  executor._ax_trusted 探测（不重复实现），零权限增量。

⚠️ 实测血泪教训（本模块的防御性封装全部由此而来，改动前必读）：
1. **ObjC NSException 直接致命**：对空 CFArray 调 CFArrayGetValueAtIndex 会触发
   NSRangeException → 进程 abort，Python try/except **接不住**。铁律：
   【先 CFArrayGetCount、索引前再 clamp】，任何路径不得越界。
2. **kAX*Attribute 常量取不到 dlsym 符号**（共享缓存里不导出）：属性名必须用
   CFStringCreateWithCString 自构造（"AXRole"/"AXTitle"/"AXPosition"/"AXSize"…）。
   本模块把属性名 CFString 缓存复用（固定小集合、进程级生命周期，**刻意不释放**）。
3. **禁止全树遍历**（浏览器/Electron 万级节点秒级卡死）：只允许命中测试 +
   目标 app 一层/两层局部枚举，且全程节点数硬上限（APP_ENUM_MAX_NODES）。
4. **所有 AX 调用先查 err 码**（kAXErrorSuccess=0；kAXErrorCannotComplete=-25204
   等全分支按"非 0 即失败"处理，绝不假设成功）；**凡 Copy 得来的 CF 对象必须
   CFRelease 配对**，防泄漏。
5. Electron 应用 AX 树贫乏（常需 AXEnhancedUserInterface），命中率 <100% 属预期
   ——调用方必须保留「未命中回落像素坐标」路径（executor 校正链既有设计）。
"""
from __future__ import annotations

import ctypes
import ctypes.util
import os
import subprocess
from ctypes import POINTER, Structure, byref, c_bool, c_double, c_float, c_int, c_long, c_uint32, c_void_p
from typing import Any

# ── 协议常量（非用户可配）────────────────────────────────────────────────
APP_ENUM_MAX_WINDOWS = 8      # 局部枚举：单个 app 最多取几个窗口（防多窗 app 爆量）
APP_ENUM_MAX_NODES = 300      # 局部枚举：节点总数硬上限（⚠️ 禁止全树遍历，教训3）
APP_ENUM_MAX_DEPTH = 2        # 局部枚举：深度硬上限（窗口=0，一层=1，两层=2）
STR_BUF_SIZE = 512            # CFString→C 字符串缓冲（title 等最长取 512 字节，防大树文本爆炸）
PS_TIMEOUT = 3.0              # ps/pgrep 子进程超时（秒）
PGREP_TIMEOUT = 3.0

_K_UTF8 = 0x08000100          # kCFStringEncodingUTF8
_K_AX_VALUE_POINT = 1         # kAXValueCGPointType
_K_AX_VALUE_SIZE = 2          # kAXValueCGSizeType

# AXError 可读名（排障用；逻辑上"非 0 即失败"，不依赖具体码值）
_AX_ERR_NAMES = {
    0: "success", -25200: "failure", -25201: "illegalArgument",
    -25202: "invalidUIElement", -25203: "invalidUIElementObserver",
    -25204: "cannotComplete", -25205: "attributeUnsupported",
    -25206: "actionUnsupported", -25207: "notificationUnsupported",
    -25208: "notImplemented", -25211: "apiDisabled", -25212: "noValue",
}


class _CGPoint(Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


class _CGSize(Structure):
    _fields_ = [("w", c_double), ("h", c_double)]


_LIBS: tuple[Any, Any] | None = None    # 惰性加载的 (ApplicationServices, CoreFoundation)
_LIBS_ERR = ""                          # 加载失败原因（供可读报错）
LAST_ERROR = ""                         # 最近一次 hit_test/app_elements 的可读失败原因


def _err_name(err: int) -> str:
    """AXError 码 → 可读名（未知码原样返回数字）。"""
    return _AX_ERR_NAMES.get(int(err), str(int(err)))


def _libs() -> tuple[Any, Any] | None:
    """惰性加载 ApplicationServices + CoreFoundation 并声明全部函数签名。

    必须显式声明 argtypes/restype（与 executor._cg() 同款原因）：ctypes 默认按 int
    传参，64 位指针会被截断 → 崩溃或读到垃圾对象。
    """
    global _LIBS, _LIBS_ERR
    if _LIBS is not None:
        return _LIBS
    try:
        as_path = ctypes.util.find_library("ApplicationServices") or \
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        as_lib = ctypes.CDLL(as_path)
        cf_path = ctypes.util.find_library("CoreFoundation") or \
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        cf = ctypes.CDLL(cf_path)

        # ── CoreFoundation ──
        cf.CFRelease.argtypes = [c_void_p]
        cf.CFRelease.restype = None
        cf.CFArrayGetCount.argtypes = [c_void_p]
        cf.CFArrayGetCount.restype = c_long
        cf.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_long]
        cf.CFArrayGetValueAtIndex.restype = c_void_p
        cf.CFStringCreateWithCString.argtypes = [c_void_p, ctypes.c_char_p, c_uint32]
        cf.CFStringCreateWithCString.restype = c_void_p
        cf.CFStringGetCString.argtypes = [c_void_p, ctypes.c_char_p, c_long, c_uint32]
        cf.CFStringGetCString.restype = c_bool

        # ── ApplicationServices / AX ──
        as_lib.AXUIElementCreateSystemWide.argtypes = []
        as_lib.AXUIElementCreateSystemWide.restype = c_void_p
        # ⚠️ 坐标参数是 float（不是 double）：声明错会读到错位坐标（实测结论）
        as_lib.AXUIElementCopyElementAtPosition.argtypes = \
            [c_void_p, c_float, c_float, POINTER(c_void_p)]
        as_lib.AXUIElementCopyElementAtPosition.restype = c_int
        as_lib.AXUIElementCreateApplication.argtypes = [c_int]
        as_lib.AXUIElementCreateApplication.restype = c_void_p
        as_lib.AXUIElementCopyAttributeValue.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
        as_lib.AXUIElementCopyAttributeValue.restype = c_int
        as_lib.AXUIElementGetPid.argtypes = [c_void_p, POINTER(c_int)]
        as_lib.AXUIElementGetPid.restype = c_int
        as_lib.AXValueGetType.argtypes = [c_void_p]
        as_lib.AXValueGetType.restype = c_long
        as_lib.AXValueGetValue.argtypes = [c_void_p, c_long, c_void_p]
        as_lib.AXValueGetValue.restype = c_bool

        _LIBS = (as_lib, cf)
        _LIBS_ERR = ""
        return _LIBS
    except Exception as e:
        _LIBS_ERR = f"{type(e).__name__}: {e}"
        return None


def ax_available() -> bool:
    """辅助功能授权探测：AX 读树与 CGEventPost 共用同一 TCC 授权，复用 executor 实现。

    读不到（非 macOS / 框架异常）按 False 处理——调用方回落像素坐标，不阻断主流程。
    """
    try:
        from sidecar.computer_use import executor as _ex
        return _ex._ax_trusted() is True
    except Exception:
        return False


# ── 属性名 CFString 缓存（教训2：kAX*Attribute 常量取不到符号，必须自构造）────
_ATTR_CACHE: dict[str, Any] = {}


def _attr(libs, name: str) -> Any:
    """属性名 → CFString（缓存复用；固定小集合、进程级生命周期，刻意不释放）。"""
    as_lib, cf = libs
    v = _ATTR_CACHE.get(name)
    if not v:
        v = cf.CFStringCreateWithCString(None, name.encode("utf-8"), _K_UTF8)
        _ATTR_CACHE[name] = v
    return v


def _release(libs, ref) -> None:
    """CFRelease 防御封装：空引用跳过，释放异常绝不抛出（释放是清理，不是主流程）。"""
    if not ref:
        return
    try:
        libs[1].CFRelease(ref)
    except Exception:
        pass


def _copy_attr(libs, el, name: str) -> tuple[Any, int]:
    """拷贝元素属性值。返回 (value|None, err)；err 非 0 时 value 一律 None（教训4）。"""
    as_lib, _ = libs
    val = c_void_p()
    try:
        err = int(as_lib.AXUIElementCopyAttributeValue(el, _attr(libs, name), byref(val)))
    except Exception:
        return None, -1
    if err != 0 or not val.value:
        return None, err
    return val.value, 0


def _cfstr(libs, v) -> str | None:
    """CFString → Python str（定长缓冲截断，防大树文本爆炸）。"""
    _, cf = libs
    buf = ctypes.create_string_buffer(STR_BUF_SIZE)
    try:
        if cf.CFStringGetCString(v, buf, STR_BUF_SIZE, _K_UTF8):
            return buf.value.decode("utf-8", "replace")
    except Exception:
        pass
    return None


def _axv_tuple(libs, v) -> tuple[float, ...] | None:
    """AXValue → (x,y) 或 (w,h)。类型不符/解包失败 → None。"""
    as_lib, _ = libs
    try:
        t = as_lib.AXValueGetType(v)
        if t == _K_AX_VALUE_POINT:
            p = _CGPoint()
            if as_lib.AXValueGetValue(v, _K_AX_VALUE_POINT, byref(p)):
                return (float(p.x), float(p.y))
        elif t == _K_AX_VALUE_SIZE:
            s = _CGSize()
            if as_lib.AXValueGetValue(v, _K_AX_VALUE_SIZE, byref(s)):
                return (float(s.w), float(s.h))
    except Exception:
        pass
    return None


def _describe(libs, el) -> dict[str, Any]:
    """读取一个元素的 role/title/frame。每个 Copy 来的值都就地 CFRelease 配对。"""
    out: dict[str, Any] = {"role": None, "title": None, "frame": None}
    rv, err = _copy_attr(libs, el, "AXRole")
    if rv:
        out["role"] = _cfstr(libs, rv)
        _release(libs, rv)
    tv, err = _copy_attr(libs, el, "AXTitle")
    if tv:
        out["title"] = _cfstr(libs, tv)
        _release(libs, tv)
    pv, err = _copy_attr(libs, el, "AXPosition")
    pos = _axv_tuple(libs, pv) if pv else None
    if pv:
        _release(libs, pv)
    sv, err = _copy_attr(libs, el, "AXSize")
    size = _axv_tuple(libs, sv) if sv else None
    if sv:
        _release(libs, sv)
    if pos and size:
        out["frame"] = (pos[0], pos[1], size[0], size[1])
    return out


def _app_name_for_pid(pid: int) -> str:
    """pid → 进程名（best-effort；读不到返回空串，不影响主流程）。"""
    try:
        r = subprocess.run(["ps", "-p", str(int(pid)), "-o", "comm="],
                           capture_output=True, text=True, timeout=PS_TIMEOUT)
        comm = (r.stdout or "").strip()
        return os.path.basename(comm) if comm else ""
    except Exception:
        return ""


def _safe_xy(x: Any, y: Any) -> tuple[float, float] | None:
    """坐标安全转换：拒绝 NaN/inf/非数字（与 executor._safe_num 同款防御）。"""
    try:
        fx, fy = float(x), float(y)
    except (TypeError, ValueError):
        return None
    for f in (fx, fy):
        if f != f or f in (float("inf"), float("-inf")):
            return None
    return fx, fy


def hit_test(x: float, y: float) -> dict[str, Any] | None:
    """命中测试：屏幕【逻辑点】(x,y) 处的 AX 元素。返回
    {"role","title","frame":(px,py,w,h)|None,"app":进程名,"pid":int}。

    无权限 / 无元素 / 任何 err / 任何异常 → 一律 None（失败原因写入模块级
    LAST_ERROR 供排障）。⛔ 绝不向调用方抛裸 ObjC/ctypes 异常——本函数是
    点击校正链的一环，它失败必须能静默回落到像素坐标。
    """
    global LAST_ERROR
    LAST_ERROR = ""
    xy = _safe_xy(x, y)
    if xy is None:
        LAST_ERROR = f"bad_arg: 坐标非法（{x!r},{y!r}）"
        return None
    if not ax_available():
        LAST_ERROR = "accessibility_denied: 辅助功能未授权，AX 读树不可用"
        return None
    libs = _libs()
    if libs is None:
        LAST_ERROR = f"libs_unavailable: {_LIBS_ERR or '未知原因'}"
        return None
    as_lib, _ = libs
    sw = None
    el = c_void_p()
    try:
        sw = as_lib.AXUIElementCreateSystemWide()
        if not sw:
            LAST_ERROR = "AXUIElementCreateSystemWide 返回空"
            return None
        fx, fy = xy
        try:
            err = int(as_lib.AXUIElementCopyElementAtPosition(
                sw, c_float(fx), c_float(fy), byref(el)))
        except Exception as e:
            LAST_ERROR = f"AXUIElementCopyElementAtPosition 异常：{type(e).__name__}: {e}"
            return None
        if err != 0:
            LAST_ERROR = f"AXUIElementCopyElementAtPosition err={err}({_err_name(err)})"
            return None
        if not el.value:
            LAST_ERROR = "命中测试返回空元素"
            return None
        out = _describe(libs, el.value)
        pid = c_int(0)
        try:
            if int(as_lib.AXUIElementGetPid(el.value, byref(pid))) == 0 and pid.value:
                out["pid"] = int(pid.value)
                out["app"] = _app_name_for_pid(pid.value)
        except Exception:
            pass
        out.setdefault("pid", 0)
        out.setdefault("app", "")
        return out
    except Exception as e:
        LAST_ERROR = f"{type(e).__name__}: {e}"
        return None
    finally:
        _release(libs, el.value)
        _release(libs, sw)


def _enum_children(libs, parent, depth: int, budget: list[int],
                   out: list[dict[str, Any]], level: int = 1) -> None:
    """局部枚举 parent 的子元素（depth 层，节点预算 budget 倒数控制总量）。

    ⚠️ 教训1：CFArray 必须先 CFArrayGetCount、索引前再 clamp——空数组/越界索引
    会触发 ObjC NSRangeException 直接 abort 进程，Python 接不住。
    """
    if depth <= 0 or budget[0] <= 0:
        return
    _, cf = libs
    arr, err = _copy_attr(libs, parent, "AXChildren")
    if err != 0 or not arr:
        return
    try:
        cnt = int(cf.CFArrayGetCount(arr))
        if cnt <= 0:
            return
        take = cnt if cnt < budget[0] else budget[0]     # ⛔ MUTATE锚点：索引必须 ≤ count-1
        for i in range(take):
            child = cf.CFArrayGetValueAtIndex(arr, i)    # i < take ≤ cnt，绝不越界
            if not child:
                continue
            budget[0] -= 1
            d = _describe(libs, child)
            d["depth"] = level
            out.append(d)
            if depth > 1 and budget[0] > 0:
                _enum_children(libs, child, depth - 1, budget, out, level + 1)
            if budget[0] <= 0:
                break
    finally:
        _release(libs, arr)


def app_elements(app_name: str, depth: int = 1) -> list[dict[str, Any]]:
    """目标 app 的窗口 + depth≤2 层局部枚举（命中测试的兜底路径）。

    返回 [{"role","title","frame","depth"}...]（depth: 0=窗口，1/2=子元素层）。
    app 找不到 / 无窗口 / 无权限 / 任何 err → 空列表（不抛异常，调用方按
    「未命中」回落处理）。⛔ 全程节点硬上限 APP_ENUM_MAX_NODES，禁止全树遍历。
    """
    global LAST_ERROR
    LAST_ERROR = ""
    name = str(app_name or "").strip()
    if not name:
        LAST_ERROR = "bad_arg: app_name 为空"
        return []
    if not ax_available():
        LAST_ERROR = "accessibility_denied: 辅助功能未授权，AX 读树不可用"
        return []
    libs = _libs()
    if libs is None:
        LAST_ERROR = f"libs_unavailable: {_LIBS_ERR or '未知原因'}"
        return []
    as_lib, cf = libs

    # app 名 → pid：精确 → 大小写不敏感精确 → 子串，逐级放宽
    pid = 0
    for args in (["pgrep", "-x", name], ["pgrep", "-ix", name], ["pgrep", "-i", name]):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=PGREP_TIMEOUT)
            lines = (r.stdout or "").strip().splitlines()
            if r.returncode == 0 and lines and lines[0].strip().isdigit():
                pid = int(lines[0].strip())
                break
        except Exception:
            continue
    if not pid:
        LAST_ERROR = f"app_not_found: 找不到运行中的应用「{name}」"
        return []

    try:
        depth = int(depth)
    except (TypeError, ValueError):
        depth = 1
    depth = 0 if depth < 0 else (APP_ENUM_MAX_DEPTH if depth > APP_ENUM_MAX_DEPTH else depth)

    out: list[dict[str, Any]] = []
    app_el = None
    wins = None
    try:
        app_el = as_lib.AXUIElementCreateApplication(pid)
        if not app_el:
            LAST_ERROR = "AXUIElementCreateApplication 返回空"
            return []
        wins, err = _copy_attr(libs, app_el, "AXWindows")
        if err != 0 or not wins:
            LAST_ERROR = f"AXWindows err={err}({_err_name(err)})" if err else "目标 app 无窗口"
            return []
        wcnt = int(cf.CFArrayGetCount(wins))
        if wcnt <= 0:
            LAST_ERROR = "目标 app 无窗口（AXWindows 为空数组）"
            return []                                     # ⛔ 空数组绝不索引（教训1）
        budget = [APP_ENUM_MAX_NODES]
        for i in range(wcnt if wcnt < APP_ENUM_MAX_WINDOWS else APP_ENUM_MAX_WINDOWS):
            win = cf.CFArrayGetValueAtIndex(wins, i)
            if not win:
                continue
            d = _describe(libs, win)
            d["depth"] = 0
            out.append(d)
            if depth > 0 and budget[0] > 0:
                _enum_children(libs, win, depth, budget, out)
            if budget[0] <= 0:
                break
        return out
    except Exception as e:
        LAST_ERROR = f"{type(e).__name__}: {e}"
        return out
    finally:
        _release(libs, wins)
        _release(libs, app_el)
