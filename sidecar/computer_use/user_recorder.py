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
"""0.4.34（CU 四期 R4）用户手动操作录制：CGEventTap listen-only 系统级捕获。

技术选型（拍板结论，与 executor 一期同源）：**ctypes 直调 CoreGraphics/CoreFoundation，
零第三方依赖**。pyobjc（Quartz）不在 .venv，而项目已有 executor.py（CGEventPost）与
ax_element.py（AX 读树）两个 ctypes 先例——新增 pyobjc 会连带影响 PyInstaller 打包
spec，是不必要的打包面扩张。ctypes 跑通所需全部接口：CGEventTapCreate / CFRunLoop /
CGPreflight/RequestListenEventAccess / IsSecureEventInputEnabled / NSWorkspace(objc)。

架构（可单测是硬要求，CI 无 TCC 权限/无真机键鼠）：
- **系统探针全部依赖注入**：frontmost / hit-test / 安全输入 / 时钟都是可替换 callable，
  归并层 `_ingest(raw)` 消费规范化事件字典，测试直接喂事件流，绝不触碰真实 tap。
- **线程模型**：独立线程跑 CFRunLoop（tap 回调只做「CGEvent → raw dict → _ingest」），
  另有一条 0.25s ticker 线程做双击超时定案与硬上限自动停；stop 干净拆除
  （CGEventTapEnable False → CFRunLoopStop/WakeUp → join 超时兜底），atexit 钩子清理。
- **事件归并**（质量核心，见 _ingest_* 头注）：连续字符聚合成一个 type step
  （退格/回车/特殊键/切焦点/点击截断）；同点双击合并为 double_click；拖拽记为
  【起点单击】+ payload.drag_to（取舍见 _ingest_mouse_locked）；cmd/ctrl+键记 hotkey。
- **密码防护**：IsSecureEventInputEnabled 或焦点元素 AXSecureTextField → 整段按键
  不记（连长度都不记，只累计 secure_dropped 计数；不进宏——note step 会让回放撞
  unknown_action 中止，故不落任何标记步，见 _ingest_key_locked）。
- **自身过滤**：frontmost 是 VetarAI/Electron（或 bundle id com.vetarai*）→ 事件不录
  （否则用户点宏面板的操作全进宏）。
- **权限**：listen-only tap 走「输入监控」TCC（kCGSessionEventTap + ListenOnly），
  与「辅助功能」是两项独立授权——CU 执行已有的辅助功能授权不覆盖它。
  CGPreflightListenEventAccess / CGRequestListenEventAccess（10.15+，符号缺失视为
  无此 TCC 概念 → granted=True）。

产物与 agent 模式同构（action/x/y/app/element/payload），经 cu_macro.record_step
写入同一录制器，落盘/列表/回放链路零改动复用。
"""
from __future__ import annotations

import atexit
import ctypes
import ctypes.util
import os
import threading
import time
from ctypes import POINTER, Structure, c_bool, c_char_p, c_double, c_int64, c_long, c_uint16, c_uint32, c_uint64, c_ulong, c_void_p
from typing import Any, Callable

# ── 协议常量（非用户可配）────────────────────────────────────────────────
TITLE_MAX = 80                    # element.title 截断（与 cu_macro 落盘契约一致）
ROLE_MAX = 40
DOUBLE_CLICK_MAX_GAP = 0.5        # 双击间隔上限（秒；与系统默认双击速度同量级）
DOUBLE_CLICK_MAX_DIST = 5.0       # 双击位移上限（逻辑点；手抖容差）
DRAG_MIN_DIST = 8.0               # 按下→抬起位移超此值视为拖拽（逻辑点）
TICK_INTERVAL = 0.25              # ticker 周期（双击超时定案 + 硬上限检查）
TAP_START_TIMEOUT = 3.0           # tap 线程就绪等待上限（秒）
JOIN_TIMEOUT = 2.0                # stop 时 join tap 线程的兜底上限（秒）

# ── CGEvent 常量（CGEventTypes.h）────────────────────────────────────────
_K_CG_SESSION_EVENT_TAP = 1       # kCGSessionEventTap：会话级监听点
_K_CG_HEAD_INSERT = 0             # kCGHeadInsertEventTap
_K_CG_TAP_LISTEN_ONLY = 1         # kCGEventTapOptionListenOnly（只观察不拦截）
_K_CG_EVENT_LEFT_DOWN, _K_CG_EVENT_LEFT_UP = 1, 2
_K_CG_EVENT_RIGHT_DOWN, _K_CG_EVENT_RIGHT_UP = 3, 4
_K_CG_EVENT_KEY_DOWN = 10
_K_CG_EVENT_OTHER_DOWN, _K_CG_EVENT_OTHER_UP = 25, 26
_K_TAP_DISABLED_BY_TIMEOUT = 0xFFFFFFFE   # kCGEventTapDisabledByTimeout
_K_TAP_DISABLED_BY_USER = 0xFFFFFFFF      # kCGEventTapDisabledByUserInput
_K_FIELD_BUTTON_NUMBER = 3        # kCGMouseEventButtonNumber
_K_FIELD_KEYCODE = 9              # kCGKeyboardEventKeycode
_EVENT_MASK = ((1 << _K_CG_EVENT_LEFT_DOWN) | (1 << _K_CG_EVENT_LEFT_UP)
               | (1 << _K_CG_EVENT_RIGHT_DOWN) | (1 << _K_CG_EVENT_RIGHT_UP)
               | (1 << _K_CG_EVENT_OTHER_DOWN) | (1 << _K_CG_EVENT_OTHER_UP)
               | (1 << _K_CG_EVENT_KEY_DOWN))

# CGEventFlags 修饰键位（与 executor._MOD_FLAGS 同源）
_F_SHIFT, _F_CTRL, _F_OPT, _F_CMD = 1 << 17, 1 << 18, 1 << 19, 1 << 20

# 自身应用识别（frontmost 命中 → 事件不录）：Electron 主程序名 / 开发态 Electron / bundle 前缀
_SELF_NAMES = frozenset({"vetarai", "electron"})
_SELF_BID_PREFIX = "com.vetarai"

# ── 键码表（ANSI layout；与 executor._KEYCODES 互补：那里是 名→码 发事件，
#    这里是 码→字符/名 录事件）─────────────────────────────────────────────
_CHAR_MAP: dict[int, tuple[str, str]] = {   # keycode → (无 shift, 有 shift)
    0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
    5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
    11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
    16: ("y", "Y"), 17: ("t", "T"),
    18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"),
    23: ("5", "%"), 24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"),
    28: ("8", "*"), 29: ("0", ")"), 30: ("]", "}"), 33: ("[", "{"),
    31: ("o", "O"), 32: ("u", "U"), 34: ("i", "I"), 35: ("p", "P"),
    37: ("l", "L"), 38: ("j", "J"), 39: ("'", '"'), 40: ("k", "K"), 41: (";", ":"),
    42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"),
    47: (".", ">"), 49: (" ", " "), 50: ("`", "~"),
}
_SPECIAL_KEYS: dict[int, str] = {           # keycode → executor.keyboard_hotkey 认得的键名
    36: "return", 48: "tab", 51: "delete", 53: "escape",
    115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
    100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
}
_MODIFIER_KEYCODES = frozenset({54, 55, 56, 57, 58, 59, 60, 61, 62, 63})  # cmd/shift/caps/opt/ctrl/fn 左右


class _CGPoint(Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


def _char_for(keycode: int, shift: bool) -> str | None:
    """keycode → 可打印字符（无 IME text 时的 ANSI 布局映射；capslock 不处理）。"""
    pair = _CHAR_MAP.get(int(keycode))
    if pair is None:
        return None
    return pair[1] if shift else pair[0]


def _main_key_name(keycode: int) -> str | None:
    """hotkey 主键名：可打印键取无 shift 形态（cmd+shift+4 → "4"），特殊键取键名。"""
    pair = _CHAR_MAP.get(int(keycode))
    if pair is not None:
        return pair[0]
    return _SPECIAL_KEYS.get(int(keycode))


# ══════════ 系统探针（全部惰性加载、可注入替换、失败安全）══════════════════

_TAP_LIBS: tuple[Any, Any] | None = None   # (CoreGraphics, CoreFoundation)
_TAP_ERR = ""


def _tap_libs() -> tuple[Any, Any] | None:
    """惰性加载 CG/CF 并声明 tap/权限相关函数签名（argtypes 必须显式，同 executor._cg）。"""
    global _TAP_LIBS, _TAP_ERR
    if _TAP_LIBS is not None:
        return _TAP_LIBS
    try:
        cg_path = ctypes.util.find_library("CoreGraphics") or \
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        cg = ctypes.CDLL(cg_path)
        cf_path = ctypes.util.find_library("CoreFoundation") or \
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        cf = ctypes.CDLL(cf_path)

        cf.CFRelease.argtypes = [c_void_p]
        cf.CFRelease.restype = None
        cg.CGEventTapCreate.restype = c_void_p
        cg.CGEventTapCreate.argtypes = [c_uint32, c_uint32, c_uint32, c_uint64, c_void_p, c_void_p]
        cg.CGEventTapEnable.argtypes = [c_void_p, c_bool]
        cg.CGEventTapEnable.restype = None
        cg.CGEventGetIntegerValueField.restype = c_int64
        cg.CGEventGetIntegerValueField.argtypes = [c_void_p, c_uint32]
        cg.CGEventGetLocation.restype = _CGPoint
        cg.CGEventGetLocation.argtypes = [c_void_p]
        cg.CGEventGetFlags.restype = c_uint64
        cg.CGEventGetFlags.argtypes = [c_void_p]
        cg.CGEventKeyboardGetUnicodeString.argtypes = \
            [c_void_p, c_ulong, POINTER(c_ulong), POINTER(c_uint16)]
        cg.CGEventKeyboardGetUnicodeString.restype = None
        # 输入监控 TCC（10.15+）：符号缺失 = 系统无此授权概念，按已授权处理
        if hasattr(cg, "CGPreflightListenEventAccess"):
            cg.CGPreflightListenEventAccess.restype = c_bool
            cg.CGPreflightListenEventAccess.argtypes = []
        if hasattr(cg, "CGRequestListenEventAccess"):
            cg.CGRequestListenEventAccess.restype = c_bool
            cg.CGRequestListenEventAccess.argtypes = []

        cf.CFRunLoopGetCurrent.restype = c_void_p
        cf.CFRunLoopGetCurrent.argtypes = []
        cf.CFMachPortCreateRunLoopSource.restype = c_void_p
        cf.CFMachPortCreateRunLoopSource.argtypes = [c_void_p, c_void_p, c_long]
        cf.CFRunLoopAddSource.argtypes = [c_void_p, c_void_p, c_void_p]
        cf.CFRunLoopAddSource.restype = None
        cf.CFRunLoopRun.argtypes = []
        cf.CFRunLoopRun.restype = None
        cf.CFRunLoopStop.argtypes = [c_void_p]
        cf.CFRunLoopStop.restype = None
        cf.CFRunLoopWakeUp.argtypes = [c_void_p]
        cf.CFRunLoopWakeUp.restype = None
        cf.CFMachPortInvalidate.argtypes = [c_void_p]
        cf.CFMachPortInvalidate.restype = None

        _TAP_LIBS = (cg, cf)
        _TAP_ERR = ""
        return _TAP_LIBS
    except Exception as e:
        _TAP_ERR = f"{type(e).__name__}: {e}"
        return None


def _common_modes(cf) -> Any:
    """kCFRunLoopCommonModes 常量（CFStringRef；该符号真实导出，与 kAX* 不同）。"""
    return c_void_p.in_dll(cf, "kCFRunLoopCommonModes")


def listen_access_granted() -> bool | None:
    """「输入监控」TCC 状态（CGPreflightListenEventAccess，只读状态位、无隐私副作用）。

    True/False = 明确状态；None = 探测不到（非 macOS / 框架异常）。
    10.15 之前的系统无此符号 = 无此授权概念 → True（tap 可直接创建）。
    """
    if os.uname().sysname != "Darwin":
        return None
    try:
        libs = _tap_libs()
        if libs is None:
            return None
        cg, _ = libs
        if not hasattr(cg, "CGPreflightListenEventAccess"):
            return True                       # 10.15 前：listen-only tap 无需授权
        return bool(cg.CGPreflightListenEventAccess())
    except Exception:
        return None


def request_listen_access() -> bool:
    """触发系统「输入监控」授权弹窗并返回弹窗后的授权状态。

    ⚠️ CGRequestListenEventAccess 语义：首次调用弹窗并【立即返回当前状态】
    （用户在弹窗里点「允许」后本进程仍被拒，需重启进程才生效——TCC 按进程启动时
    读取）；系统只弹一次，此后调用直接返回状态不再弹。返回值为如实状态。
    """
    try:
        libs = _tap_libs()
        if libs is None:
            return False
        cg, _ = libs
        if not hasattr(cg, "CGRequestListenEventAccess"):
            return bool(listen_access_granted())
        granted = bool(cg.CGRequestListenEventAccess())
        # 以 preflight 复核为准（request 的返回值在不同系统版本语义有出入）
        pre = listen_access_granted()
        return bool(pre) if pre is not None else granted
    except Exception:
        return False


# ── 安全输入探测（密码防护两道闸）────────────────────────────────────────
_CARBON: Any = None
_CARBON_TRIED = False


def _secure_input_enabled() -> bool | None:
    """IsSecureEventInputEnabled（HIToolbox，经 Carbon umbrella 解析）：系统级
    安全输入标志——任何 app 开启安全输入（密码框聚焦）时为 True。读不到 → None。"""
    global _CARBON, _CARBON_TRIED
    try:
        if not _CARBON_TRIED:
            _CARBON_TRIED = True
            for path in (ctypes.util.find_library("Carbon"),
                         "/System/Library/Frameworks/Carbon.framework/Carbon",
                         "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"):
                if not path:
                    continue
                try:
                    lib = ctypes.CDLL(path)
                    if hasattr(lib, "IsSecureEventInputEnabled"):
                        lib.IsSecureEventInputEnabled.restype = c_bool
                        lib.IsSecureEventInputEnabled.argtypes = []
                        _CARBON = lib
                        break
                except Exception:
                    continue
        if _CARBON is None:
            return None
        return bool(_CARBON.IsSecureEventInputEnabled())
    except Exception:
        return None


def _focused_is_secure() -> bool:
    """焦点元素是否 AXSecureTextField（复用 ax_element 既有 ctypes 封装，不重复造轮子）。
    任何失败 → False（该闸是增强，主闸是 IsSecureEventInputEnabled）。"""
    try:
        from sidecar.computer_use import ax_element as _axe
        if not _axe.ax_available():
            return False
        libs = _axe._libs()
        if libs is None:
            return False
        as_lib, _ = libs
        sw = None
        foc = None
        try:
            sw = as_lib.AXUIElementCreateSystemWide()
            if not sw:
                return False
            foc, err = _axe._copy_attr(libs, sw, "AXFocusedUIElement")
            if not foc:
                return False
            rv, err = _axe._copy_attr(libs, foc, "AXRole")
            if rv:
                role = _axe._cfstr(libs, rv)
                _axe._release(libs, rv)
                return role == "AXSecureTextField"
            return False
        finally:
            _axe._release(libs, foc)
            _axe._release(libs, sw)
    except Exception:
        return False


# ── frontmost 应用（自身过滤 + step.app）：NSWorkspace 经 libobjc ctypes ──
_OBJC: dict[str, Any] | None = None
_OBJC_TRIED = False


def _objc_bridge() -> dict[str, Any] | None:
    """libobjc 桥：NSWorkspace.frontmostApplication 的 localizedName/bundleIdentifier/
    processIdentifier。⛔ 每个签名都要独立的 _FuncPtr（CDLL.__getattr__ 会缓存并共享
    restype），故一律走 __getitem__（不缓存、每次新建）。"""
    global _OBJC, _OBJC_TRIED
    if _OBJC_TRIED:
        return _OBJC
    _OBJC_TRIED = True
    try:
        # ⛔ 必须先 dlopen AppKit：NSWorkspace 的类定义在 AppKit 里，而侧车是无头进程
        # 不链接 AppKit——objc_getClass 只能查到【已加载镜像】里的类，不先 dlopen
        # 永远返回 None（2026-09-20 真机调试实测）。dlopen 只注册类、不建 NSApplication，
        # 对无头进程无副作用。
        ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")
        objc = ctypes.CDLL("/usr/lib/libobjc.dylib")
        get_class = objc["objc_getClass"]
        get_class.restype = c_void_p
        get_class.argtypes = [c_char_p]
        sel_reg = objc["sel_registerName"]
        sel_reg.restype = c_void_p
        sel_reg.argtypes = [c_char_p]
        msg_ptr = objc["objc_msgSend"]          # id (id, SEL) —— 返回对象指针
        msg_ptr.restype = c_void_p
        msg_ptr.argtypes = [c_void_p, c_void_p]
        msg_str = objc["objc_msgSend"]          # const char* (id, SEL) —— UTF8String
        msg_str.restype = c_char_p
        msg_str.argtypes = [c_void_p, c_void_p]
        msg_int = objc["objc_msgSend"]          # int (id, SEL) —— processIdentifier
        msg_int.restype = ctypes.c_int
        msg_int.argtypes = [c_void_p, c_void_p]
        sels = {n: sel_reg(n.encode("ascii")) for n in
                ("sharedWorkspace", "frontmostApplication", "localizedName",
                 "bundleIdentifier", "UTF8String", "processIdentifier")}
        cls = get_class(b"NSWorkspace")
        if not cls:
            return None
        _OBJC = {"msg_ptr": msg_ptr, "msg_str": msg_str, "msg_int": msg_int,
                 "sel": sels, "cls": cls}
        return _OBJC
    except Exception:
        _OBJC = None
        return None


def _objc_frontmost() -> tuple[str, str, int]:
    """→ (localizedName, bundleIdentifier, pid)；任何失败 → ("", "", 0)。"""
    try:
        b = _objc_bridge()
        if b is None:
            return ("", "", 0)
        sel = b["sel"]
        ws = b["msg_ptr"](b["cls"], sel["sharedWorkspace"])
        if not ws:
            return ("", "", 0)
        app = b["msg_ptr"](ws, sel["frontmostApplication"])
        if not app:
            return ("", "", 0)

        def _str(ref) -> str:
            if not ref:
                return ""
            raw = b["msg_str"](ref, sel["UTF8String"])
            return raw.decode("utf-8", "replace") if raw else ""

        name = _str(b["msg_ptr"](app, sel["localizedName"]))
        bid = _str(b["msg_ptr"](app, sel["bundleIdentifier"]))
        pid = int(b["msg_int"](app, sel["processIdentifier"]) or 0)
        return (name, bid, pid)
    except Exception:
        return ("", "", 0)


_FRONT_TTL = 1.0                     # 回落路径（osascript）结果缓存秒数
_FRONT_CACHE: tuple[float, tuple[str, str, int]] = (0.0, ("", "", 0))


def _system_frontmost() -> tuple[str, str, int]:
    """真实 frontmost 探针：objc 桥优先；失败回落 executor.frontmost_app（osascript，
    每次 ~30-80ms，故 1s TTL 缓存——只在该回落路径上启用）。"""
    name, bid, pid = _objc_frontmost()
    if name or bid or pid:
        return (name, bid, pid)
    global _FRONT_CACHE
    now = time.monotonic()
    ts, cached = _FRONT_CACHE
    if now - ts < _FRONT_TTL:
        return cached
    try:
        from sidecar.computer_use import executor as _ex
        cached = (str(_ex.frontmost_app() or ""), "", 0)
    except Exception:
        cached = ("", "", 0)
    _FRONT_CACHE = (now, cached)
    return cached


# ══════════ 录制器（归并层全注入可测；tap 生命周期干净拆除）═════════════════

class UserRecorder:
    """系统级用户操作录制器。

    参数全部可注入（测试喂假探针 + 直接调 _ingest，绝不需要真实 TCC/键鼠）：
      on_step:      step dict 出口（接 cu_macro.record_step）
      on_timeout:   硬上限到点回调（接 cu_macro.stop_recording；ticker 线程触发）
      max_seconds:  硬上限（config cu_user_record_max_seconds）
      front_fn:     → (name, bundle_id, pid)
      hit_fn:       AX 命中测试（x,y）→ {role,title,frame,app}|None
      secure_fn:    安全输入标志 → bool|None
      focused_secure_fn: 焦点元素是否密码框 → bool
      now_fn:       时钟（单调秒）
    """

    def __init__(self, on_step: Callable[[dict], Any],
                 on_timeout: Callable[[], Any] | None = None,
                 max_seconds: float = 600.0,
                 front_fn: Callable[[], tuple[str, str, int]] | None = None,
                 hit_fn: Callable[[float, float], dict | None] | None = None,
                 secure_fn: Callable[[], bool | None] | None = None,
                 focused_secure_fn: Callable[[], bool] | None = None,
                 now_fn: Callable[[], float] | None = None):
        self._on_step = on_step
        self._on_timeout = on_timeout
        self._max_seconds = float(max_seconds or 600.0)
        self._front = front_fn or _system_frontmost
        self._hit = hit_fn or self._default_hit
        self._secure = secure_fn or _secure_input_enabled
        self._focused_secure = focused_secure_fn or _focused_is_secure
        self._now = now_fn or time.monotonic

        self._lock = threading.RLock()          # 归并状态锁（tap 回调/ticker/stop 三方）
        self._pending_text: list[str] = []
        self._pending_app = ""
        self._pending_click: dict | None = None  # 待单击定案的 down 信息（双击合并窗口内）
        self._dbl_armed = False                  # 第二次 down 已落入双击窗口
        self._down: dict[str, dict] = {}         # button → down 信息（拖拽判定）
        self.secure_dropped = 0                  # 密码防护丢弃的按键数（诊断用，不进宏）

        self._t0 = self._now()
        self._timeout_fired = False
        self._stopped = False
        self._life_lock = threading.Lock()
        self._stop_evt = threading.Event()
        self._thread: threading.Thread | None = None
        self._ticker: threading.Thread | None = None
        self._tap = None
        self._rl = None
        self._cb = None                          # CFUNCTYPE 实例必须持有引用（防 GC）
        self.start_error = ""                    # start 失败的可读原因（供 403/422 文案）
        self.tap_reenabled = 0                   # tap 被系统禁用后重建次数（诊断）

    # ── 探针默认实现 ─────────────────────────────────────────────────────
    @staticmethod
    def _default_hit(x: float, y: float) -> dict | None:
        try:
            from sidecar.computer_use import ax_element as _axe
            return _axe.hit_test(x, y)
        except Exception:
            return None

    # ── 归并层（⛔ 质量核心；raw 事件 → 宏 step）──────────────────────────
    def _ingest(self, raw: dict) -> None:
        """规范化事件入口（tap 回调与测试共用）。⛔ 绝不抛异常——录制是旁路。"""
        try:
            ts = float(raw.get("ts") or self._now())
            name, bid, pid = self._front()
            kind = raw.get("kind")
            with self._lock:
                if self._is_self(name, bid, pid):
                    # ⛔ MUTATE锚点：本应用（VetarAI/Electron）前台时事件不录
                    self._flush_text_locked()    # 切回自己窗口 = 焦点切换，截断打字聚合
                    return
                if kind == "key":
                    self._ingest_key_locked(raw, ts, str(name or ""))
                elif kind in ("mouse_down", "mouse_up"):
                    self._ingest_mouse_locked(raw, ts, str(name or ""))
        except Exception:
            pass

    @staticmethod
    def _is_self(name: str, bid: str, pid: int) -> bool:
        if pid and pid == os.getpid():
            return True
        if str(bid or "").lower().startswith(_SELF_BID_PREFIX):
            return True
        return str(name or "").strip().lower() in _SELF_NAMES

    def _ingest_key_locked(self, raw: dict, ts: float, app: str) -> None:
        keycode = int(raw.get("keycode") or 0)
        flags = int(raw.get("flags") or 0)
        text = raw.get("text") or ""
        if keycode in _MODIFIER_KEYCODES:
            return                             # 纯修饰键 down 不记（组合键以主键为准）
        cmd = bool(flags & _F_CMD)
        shift = bool(flags & _F_SHIFT)
        opt = bool(flags & _F_OPT)
        ctrl = bool(flags & _F_CTRL)

        # ⛔ MUTATE锚点：安全输入段按键整段不记（连长度都不记；不落 note 步——
        #    note 会让回放撞 unknown_action 中止，丢弃本身即是防护语义）
        if self._secure() is True or self._focused_secure():
            self.secure_dropped += 1
            self._flush_text_locked()          # 进入密码段前的明文先落（它不属于密码）
            return

        if cmd or ctrl:
            # 修饰键 + 主键 → hotkey step（回放走 executor.keyboard_hotkey）
            self._flush_text_locked()
            main = _main_key_name(keycode)
            if main is None:
                return                         # 主键无法映射：录了回放必失败，跳过
            mods = (["cmd"] if cmd else []) + (["shift"] if shift else []) \
                + (["option"] if opt else []) + (["ctrl"] if ctrl else [])
            self._emit({"action": "key", "x": None, "y": None, "app": app,
                        "element": None,
                        "payload": {"keys": "+".join(mods + [main])}})
            return

        if opt and not text:
            # option+键产出特殊字符（π、œ…），无 IME text 时 ANSI 表查不出 → 跳过
            # （录错字符比漏录更糟；option+方向键等走下方特殊键路径）
            if keycode in _CHAR_MAP:
                return
        ch = text or _char_for(keycode, shift)
        if ch is not None:
            if self._pending_text and self._pending_app != app:
                # ⛔ 切换焦点截断：不同 app 的击键绝不聚进同一段 type
                self._flush_text_locked()
            self._pending_text.append(ch)
            self._pending_app = app
            return

        name2 = _SPECIAL_KEYS.get(keycode)
        if name2 is None:
            return                             # 不认识的键（如 117 前进删除）跳过
        # ⛔ MUTATE锚点：退格/回车等特殊键必须截断打字聚合
        self._flush_text_locked()
        mods = (["shift"] if shift else []) + (["option"] if opt else [])
        self._emit({"action": "key", "x": None, "y": None, "app": app,
                    "element": None,
                    "payload": {"keys": "+".join(mods + [name2]) if mods else name2}})

    def _ingest_mouse_locked(self, raw: dict, ts: float, app: str) -> None:
        x, y = float(raw.get("x") or 0.0), float(raw.get("y") or 0.0)
        button = str(raw.get("button") or "left")
        kind = raw["kind"]
        if kind == "mouse_down":
            self._flush_text_locked()          # 点击 = 焦点可能切换，截断打字聚合
            self._check_click_expired_locked(ts)
            hit = None
            try:
                hit = self._hit(x, y)          # 元素语义富化（18-51ms，点击速度可承受）
            except Exception:
                hit = None                     # 命中失败只记坐标（回放自然回落像素）
            d = {"x": x, "y": y, "ts": ts, "hit": hit, "app": app, "button": button}
            self._down[button] = d
            pend = self._pending_click
            if button == "left" and pend is not None \
                    and ts - float(pend["ts"]) <= DOUBLE_CLICK_MAX_GAP \
                    and abs(x - pend["x"]) <= DOUBLE_CLICK_MAX_DIST \
                    and abs(y - pend["y"]) <= DOUBLE_CLICK_MAX_DIST:
                self._dbl_armed = True         # 第二次 down 落入双击窗口，暂缓定案
            else:
                self._flush_click_locked()     # 上一次点击定案为单击
                self._dbl_armed = False
            return
        # mouse_up
        d = self._down.pop(button, None)
        if d is None:
            return
        moved2 = (x - d["x"]) ** 2 + (y - d["y"]) ** 2
        if moved2 > DRAG_MIN_DIST * DRAG_MIN_DIST:
            # 拖拽取舍（拍板）：记为【起点单击】+ payload.drag_to 落盘佐证。
            # 不记轨迹——轨迹回放（press-move-release）是另一量级需求；
            # 多数「拖拽」场景（拖窗口/拖选）在宏语义下等价于起点的一次定位点击。
            self._flush_click_locked()
            self._dbl_armed = False
            self._emit_click_locked(d, clicks=1, drag_to=(x, y))
            return
        if button == "left" and self._dbl_armed and self._pending_click is not None:
            # ⛔ MUTATE锚点：同点双击必须合并为 double_click（而不是两个 click）
            first = self._pending_click
            self._pending_click = None
            self._dbl_armed = False
            self._emit_click_locked(first, clicks=2)
            return
        self._flush_click_locked()
        self._pending_click = d                # 暂缓定案：等双击窗口/ticker/stop

    def _emit_click_locked(self, d: dict, clicks: int,
                           drag_to: tuple[float, float] | None = None) -> None:
        hit = d.get("hit") or None
        el = None
        if isinstance(hit, dict) and hit:
            el = {"role": str(hit.get("role") or "")[:ROLE_MAX],
                  "title": str(hit.get("title") or "")[:TITLE_MAX],
                  "frame": hit.get("frame")}
        app = str((hit or {}).get("app") or d.get("app") or "")
        button = str(d.get("button") or "left")
        if button == "left":
            action = "click" if clicks <= 1 else "double_click"
        elif button == "right":
            action = "right_click"
        else:
            action = "click"                   # 中键等：按 click 记，payload 如实写 button
        payload: dict[str, Any] = {"button": button, "clicks": int(clicks)}
        if drag_to is not None:
            payload["drag_to"] = [round(drag_to[0], 1), round(drag_to[1], 1)]
        self._emit({"action": action, "x": round(float(d["x"]), 1),
                    "y": round(float(d["y"]), 1), "app": app, "element": el,
                    "payload": payload})

    def _check_click_expired_locked(self, now: float) -> None:
        pend = self._pending_click
        if pend is not None and now - float(pend["ts"]) > DOUBLE_CLICK_MAX_GAP:
            self._flush_click_locked()         # 双击窗口已过，定案为单击
            self._dbl_armed = False

    def _flush_text_locked(self) -> None:
        if self._pending_text:
            s = "".join(self._pending_text)
            self._pending_text = []
            self._emit({"action": "type", "x": None, "y": None,
                        "app": self._pending_app, "element": None,
                        "payload": {"text": s}})

    def _flush_click_locked(self) -> None:
        if self._pending_click is not None:
            d = self._pending_click
            self._pending_click = None
            self._emit_click_locked(d, clicks=1)

    def _flush_all_locked(self) -> None:
        self._flush_text_locked()
        self._flush_click_locked()
        self._dbl_armed = False
        self._down.clear()

    def _emit(self, step: dict) -> None:
        """step 出口。⛔ 绝不抛异常（on_step 是录制旁路，搞挂 tap 回调是事故）。"""
        try:
            self._on_step(step)
        except Exception:
            pass

    # ── ticker：双击超时定案 + 硬上限自动停 ───────────────────────────────
    def _tick(self, now: float) -> None:
        due = False
        with self._lock:
            self._check_click_expired_locked(now)
            if not self._timeout_fired and (now - self._t0) >= self._max_seconds:
                # ⛔ MUTATE锚点：硬上限到点必须自动停（视作正常 stop，有步落盘）
                self._timeout_fired = True
                due = True
        if due and self._on_timeout is not None:
            try:
                self._on_timeout()
            except Exception:
                pass

    def _tick_loop(self) -> None:
        while not self._stop_evt.wait(TICK_INTERVAL):
            try:
                self._tick(self._now())
            except Exception:
                pass

    # ── 生命周期：独立线程 CFRunLoop + 干净拆除 ──────────────────────────
    def start(self) -> bool:
        """创建 listen-only tap 并起跑。失败 → False + self.start_error（可读原因）。"""
        libs = _tap_libs()
        if libs is None:
            self.start_error = f"tap_libs_unavailable: {_TAP_ERR or '未知原因'}"
            return False
        self._ready = threading.Event()
        self._t0 = self._now()
        self._thread = threading.Thread(target=self._run, args=(libs,),
                                        name="cu-user-record-tap", daemon=True)
        self._thread.start()
        if not self._ready.wait(TAP_START_TIMEOUT):
            self.start_error = "tap_start_timeout: tap 线程 3s 未就绪"
            return False
        if self.start_error:
            return False
        self._ticker = threading.Thread(target=self._tick_loop,
                                        name="cu-user-record-tick", daemon=True)
        self._ticker.start()
        return True

    def _run(self, libs) -> None:
        """tap 线程体：建 tap → 挂 runloop source → CFRunLoopRun（stop 后返回）。"""
        cg, cf = libs
        try:
            cb_t = ctypes.CFUNCTYPE(c_void_p, c_void_p, c_uint32, c_void_p, c_void_p)
            self._cb = cb_t(self._on_tap)      # ⛔ 必须持有引用：GC 回收回调=崩溃
            tap = cg.CGEventTapCreate(_K_CG_SESSION_EVENT_TAP, _K_CG_HEAD_INSERT,
                                      _K_CG_TAP_LISTEN_ONLY, _EVENT_MASK,
                                      self._cb, None)
            if not tap:
                self.start_error = (
                    "tap_create_failed: CGEventTapCreate 返回空——「输入监控」未授权时"
                    "系统直接拒绝建 tap（请检查 系统设置→隐私与安全性→输入监控）")
                return
            self._tap = tap
            self._rl = cf.CFRunLoopGetCurrent()
            src = cf.CFMachPortCreateRunLoopSource(None, tap, 0)
            cf.CFRunLoopAddSource(self._rl, src, _common_modes(cf))
            cg.CGEventTapEnable(tap, True)
            self._run_src = src
            self._ready.set()
            cf.CFRunLoopRun()
        except Exception as e:
            self.start_error = f"tap_run_failed: {type(e).__name__}: {e}"
        finally:
            try:
                self._ready.set()
            except Exception:
                pass
            # 干净拆除：source/tap 释放（CFRunLoopRun 已返回后）
            try:
                if self._tap:
                    cf.CFMachPortInvalidate(self._tap)
                    cf.CFRelease(self._tap)
            except Exception:
                pass
            try:
                if getattr(self, "_run_src", None):
                    cf.CFRelease(self._run_src)
            except Exception:
                pass
            self._tap = None
            self._rl = None

    def _on_tap(self, proxy, type_, event, user_info):
        """CGEventTap 回调（tap 线程）：只做 CGEvent → raw dict → _ingest。
        ⛔ 绝不抛异常（抛进 CFRunLoop 是未定义行为）；listen-only 返回值被系统忽略。"""
        try:
            t = int(type_)
            if t in (_K_TAP_DISABLED_BY_TIMEOUT, _K_TAP_DISABLED_BY_USER):
                # tap 被系统禁用（超时/用户输入风暴）→ 重建（重新启用即可）
                self.tap_reenabled += 1
                try:
                    libs = _tap_libs()
                    if libs is not None and self._tap:
                        libs[0].CGEventTapEnable(self._tap, True)
                except Exception:
                    pass
                return event
            ts = self._now()
            libs = _tap_libs()
            if libs is None:
                return event
            cg, _ = libs
            if t == _K_CG_EVENT_KEY_DOWN:
                keycode = int(cg.CGEventGetIntegerValueField(event, _K_FIELD_KEYCODE))
                flags = int(cg.CGEventGetFlags(event))
                text = ""
                try:
                    buf = (c_uint16 * 16)()
                    actual = c_ulong(0)
                    cg.CGEventKeyboardGetUnicodeString(event, 16, ctypes.byref(actual), buf)
                    if actual.value:
                        text = bytes(bytearray(
                            b for u in buf[:min(actual.value, 16)]
                            for b in (u & 0xFF, (u >> 8) & 0xFF))).decode("utf-16-le", "replace")
                except Exception:
                    text = ""
                self._ingest({"kind": "key", "keycode": keycode, "flags": flags,
                              "text": text, "ts": ts})
            elif t in (_K_CG_EVENT_LEFT_DOWN, _K_CG_EVENT_LEFT_UP,
                       _K_CG_EVENT_RIGHT_DOWN, _K_CG_EVENT_RIGHT_UP,
                       _K_CG_EVENT_OTHER_DOWN, _K_CG_EVENT_OTHER_UP):
                pt = cg.CGEventGetLocation(event)
                btn_num = int(cg.CGEventGetIntegerValueField(event, _K_FIELD_BUTTON_NUMBER))
                button = "left" if btn_num == 0 else ("right" if btn_num == 1 else "other")
                kind = "mouse_down" if t in (_K_CG_EVENT_LEFT_DOWN,
                                             _K_CG_EVENT_RIGHT_DOWN,
                                             _K_CG_EVENT_OTHER_DOWN) else "mouse_up"
                self._ingest({"kind": kind, "x": float(pt.x), "y": float(pt.y),
                              "button": button, "ts": ts})
        except Exception:
            pass
        return event

    def stop(self) -> None:
        """干净拆除：tap 停用 → runloop 停止 → join 兜底 → flush 残余聚合（幂等）。"""
        with self._life_lock:
            if self._stopped:
                return
            self._stopped = True
        self._stop_evt.set()
        libs = _tap_libs()
        cur = threading.current_thread()
        try:
            if libs is not None and self._tap:
                cg, cf = libs
                try:
                    cg.CGEventTapEnable(self._tap, False)
                except Exception:
                    pass
                if self._rl:
                    try:
                        cf.CFRunLoopStop(self._rl)   # 可跨线程调用
                        cf.CFRunLoopWakeUp(self._rl)
                    except Exception:
                        pass
        except Exception:
            pass
        try:
            if self._thread is not None and self._thread is not cur:
                self._thread.join(JOIN_TIMEOUT)
        except Exception:
            pass
        try:
            if self._ticker is not None and self._ticker is not cur:
                self._ticker.join(JOIN_TIMEOUT)
        except Exception:
            pass
        with self._lock:
            try:
                self._flush_all_locked()       # 收尾：打字段/待定案点击全部落宏
            except Exception:
                pass
        try:
            global _ACTIVE
            with _ACTIVE_LOCK:
                if _ACTIVE is self:
                    _ACTIVE = None
        except Exception:
            pass


# ══════════ 模块级单例（cu_macro 双保险之外的第二道单例闸 + 进程退出清理）══
_ACTIVE: UserRecorder | None = None
_ACTIVE_LOCK = threading.RLock()
_ATEXIT_REGISTERED = False


def start_capture(on_step: Callable[[dict], Any],
                  on_timeout: Callable[[], Any] | None = None,
                  max_seconds: float = 600.0) -> UserRecorder | None:
    """创建并起跑系统级捕获。已在捕获 → None（双保险；cu_macro 单例已先挡）。
    tap 创建失败 → None（原因在返回前写入日志级 start_error——此处返回 None 时
    调用方只能给通用报错，故排障入口是 listen_access_granted + check 端点）。"""
    global _ACTIVE, _ATEXIT_REGISTERED
    with _ACTIVE_LOCK:
        if _ACTIVE is not None:
            return None
        rec = UserRecorder(on_step=on_step, on_timeout=on_timeout,
                           max_seconds=max_seconds)
        if not rec.start():
            return None
        _ACTIVE = rec
        if not _ATEXIT_REGISTERED:
            _ATEXIT_REGISTERED = True
            atexit.register(_cleanup_at_exit)
        return rec


def _cleanup_at_exit() -> None:
    """进程退出钩子：录制中进程被杀也要干净拆 tap（防残留监听）。"""
    try:
        with _ACTIVE_LOCK:
            rec = _ACTIVE
        if rec is not None:
            rec.stop()
    except Exception:
        pass
