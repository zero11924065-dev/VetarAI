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
"""0.4.32（CU 二期 P0+P1，REQ-FUT-005 路径①）专项回归：AX 元素定位 + 点击校正链。

⛔ 测试铁律（同 test_computer_use.py）：**绝不允许真实点击/输入用户屏幕**。
- ax_element 的 AX 读取经【假 CF/AS 层】注入（_LIBS 注入桩），只验证调用契约：
  err 分支、先 count 后索引、CFRelease 配对、深度/节点上限；
- ⛔ 假 CF 层对【越界索引】直接抛 AssertionError —— 真实环境里那是对空 CFArray
  索引触发的 ObjC NSRangeException → 进程 abort（Python 接不住）。被测代码一旦
  失去 count-before-index 防护，本套件立即全灭（变异 1 守护）；
- mouse_click 校正链集成用【假 CoreGraphics】，事件构造/投递全部记录在案、零真实输出；
- 唯一真实调用的是 H 组真值用例（AX 只读查询，无副作用），skip 条件照
  test_computer_use.py C 组同款：环境不满足时打印 SKIP 返回，不判失败。

变异测试机制（MUTATE=1|2|3|4|5 .venv/bin/python -m sidecar.computer_use.test_ax_element）：
  1 = ax_element 索引 clamp 失效（越界防护失守 → B 组灭）
  2 = executor 零尺寸 frame 防护失效（C4 灭）
  3 = executor frame 中心算成左上角（C1 灭）
  4 = element_locate title 截断失效（E4 灭）
  5 = 校正开关默认值被改（C1/F1 灭）
"""
import importlib
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS = 0
FAIL = 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


# ══════════ 变异机制（照 test_driver_llamacpp.py 范式：内存备份 + finally 还原 + reload）══
MUTATE = int(os.environ.get("MUTATE", "0"))
_BACKUP: dict[str, tuple[Path, str]] = {}


def _mutate_file(path: Path, old: str, new: str, tag: str) -> None:
    s = path.read_text(encoding="utf-8")
    _BACKUP[tag] = (path, s)
    patched = s.replace(old, new)
    assert patched != s, f"变异 {MUTATE} 未命中 {path.name} 源码锚点，测试无效"
    path.write_text(patched, encoding="utf-8")


def _apply_mutation() -> None:
    if not MUTATE:
        return
    import sidecar.computer_use.ax_element as axe
    import sidecar.computer_use.executor as ex
    if MUTATE == 1:
        # 越界防护失守：不再按 count clamp 索引数（真实环境=空数组索引→进程 abort）
        _mutate_file(Path(axe.__file__),
                     "        take = cnt if cnt < budget[0] else budget[0]"
                     "     # ⛔ MUTATE锚点：索引必须 ≤ count-1",
                     "        take = budget[0]  # 变异1：索引不再 clamp，越界直达假 CF 层",
                     "axe")
        importlib.reload(axe)
    elif MUTATE == 2:
        _mutate_file(Path(ex.__file__),
                     "        if not (fw > 0 and fh > 0):          # ⛔ MUTATE锚点：零尺寸 frame 无中心可点",
                     "        if False:  # 变异2：零尺寸 frame 防护失效",
                     "executor")
        importlib.reload(ex)
    elif MUTATE == 3:
        _mutate_file(Path(ex.__file__),
                     "        cx, cy = fx + fw / 2.0, fy + fh / 2.0",
                     "        cx, cy = fx, fy  # 变异3：点左上角而非 frame 中心",
                     "executor")
        importlib.reload(ex)
    elif MUTATE == 4:
        _mutate_file(Path(ex.__file__),
                     '    title = str(hit.get("title") or "")[:80]           # ⛔ MUTATE锚点：title 必须截断防爆',
                     '    title = str(hit.get("title") or "")  # 变异4：title 截断失效',
                     "executor")
        importlib.reload(ex)
    elif MUTATE == 5:
        _mutate_file(Path(ex.__file__),
                     '        if not bool((_gc() or {}).get("cu_element_locate_enabled", True)):',
                     '        if True:  # 变异5：校正开关强制视为关闭',
                     "executor")
        importlib.reload(ex)
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3|4|5）")


def _restore() -> None:
    """还原被变异的源文件（必须在 finally：用例失败/中断也要还原）。"""
    if not MUTATE or not _BACKUP:
        return
    try:
        for path, s in _BACKUP.values():
            path.write_text(s, encoding="utf-8")
    finally:
        tags = set(_BACKUP.keys())
        _BACKUP.clear()
        if "axe" in tags:
            import sidecar.computer_use.ax_element as axe
            importlib.reload(axe)
        if "executor" in tags:
            import sidecar.computer_use.executor as ex
            importlib.reload(ex)


def isolate_all(prefix: str) -> Path:
    """config / store / warehouse / skills 全部重定向到临时目录（照 test_computer_use.py 同款）。"""
    tmp = Path(tempfile.mkdtemp(prefix=prefix))
    os.environ["VETARAI_DATA_ROOT"] = str(tmp)
    import sidecar.config.store as cs
    cs.get_config_path = lambda: tmp / "config.json"
    cs._MEM = dict(cs.DEFAULT_CONFIG)
    cs._MEM["data_root"] = str(tmp)
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp / "projects"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    store._GDB = store.PROJECTS_ROOT / "_global.db"
    from sidecar.knowledge import warehouse as wh
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "knowledge" / "index.db"
    (tmp / "knowledge").mkdir(parents=True, exist_ok=True)
    import sidecar.skills_mgr.manager as skm
    sk_dir = tmp / "skills"
    sk_dir.mkdir(parents=True, exist_ok=True)
    skm.skills_root = lambda: sk_dir
    return tmp


# ══════════ 假 CF/AS 层（注入 ax_element._LIBS）══════════════════════════
# ⛔ c_void_p.value 只能存 int/bytes——假层对象（_Arr/_Str/_Pt/元素名）经 _box
# 换成稳定 int 句柄写入 out 参，进假层方法时再 _unbox 还原（注册表持引用，id 稳定）。
_BOX: dict[int, object] = {}


def _box(v):
    if v is None or isinstance(v, int):
        return v
    _BOX[id(v)] = v
    return id(v)


def _unbox(v):
    return _BOX.get(v, v) if isinstance(v, int) else v


class _Str:
    def __init__(self, s): self.s = s


class _Arr:
    def __init__(self, items): self.items = list(items)


class _Pt:
    def __init__(self, x, y): self.x, self.y = x, y


class _Sz:
    def __init__(self, w, h): self.w, self.h = w, h


class _ErrVal:
    """属性值占位：让 CopyAttributeValue 返回指定 err 码。"""

    def __init__(self, code): self.code = code


class FakeCF:
    """CoreFoundation 假层。⛔ 越界索引直接 AssertionError——真实环境此处是
    ObjC NSRangeException 进程 abort（Python 接不住），假层用硬失败等价守护。"""

    def __init__(self):
        self.released = []

    def CFRelease(self, ref):
        self.released.append(_unbox(ref))

    def CFArrayGetCount(self, arr):
        return len(_unbox(arr).items)

    def CFArrayGetValueAtIndex(self, arr, i):
        arr = _unbox(arr)
        if i < 0 or i >= len(arr.items):
            raise AssertionError(
                f"越界索引 i={i} count={len(arr.items)}（真实环境=NSException 进程 abort）")
        return _box(arr.items[i])

    def CFStringCreateWithCString(self, alloc, b, enc):
        return _Str(b.decode("utf-8"))

    def CFStringGetCString(self, v, buf, size, enc):
        data = _unbox(v).s.encode("utf-8")[: size - 1]
        buf.value = data
        return True


class FakeAS:
    """ApplicationServices/AX 假层。attrs: {element: {属性名: 值}}。"""

    def __init__(self, attrs=None, hit_err=0, hit_elem="el0", pid=4242,
                 getpid_err=0, sw_raises=False, copy_raises=False):
        self.attrs = attrs or {}
        self.hit_err = hit_err
        self.hit_elem = hit_elem
        self.pid = pid
        self.getpid_err = getpid_err
        self.sw_raises = sw_raises
        self.copy_raises = copy_raises
        self.hit_calls = []          # 记录命中测试坐标（验证调用次数与参数）

    def AXUIElementCreateSystemWide(self):
        if self.sw_raises:
            raise RuntimeError("fake sw boom")
        return "sw"

    def AXUIElementCopyElementAtPosition(self, sw, x, y, out):
        self.hit_calls.append((float(getattr(x, "value", x)), float(getattr(y, "value", y))))
        if self.copy_raises:
            raise RuntimeError("fake copy boom")
        if self.hit_err:
            return self.hit_err
        out._obj.value = _box(self.hit_elem)
        return 0

    def AXUIElementCreateApplication(self, pid):
        return "app_el"

    def AXUIElementCopyAttributeValue(self, el, attr, out):
        el = _unbox(el)
        name = attr.s
        v = self.attrs.get(el, {}).get(name, None)
        if v is None:
            return -25205          # kAXErrorAttributeUnsupported
        if isinstance(v, _ErrVal):
            return v.code
        out._obj.value = _box(v)
        return 0

    def AXUIElementGetPid(self, el, out):
        if self.getpid_err:
            return self.getpid_err
        out._obj.value = self.pid
        return 0

    def AXValueGetType(self, v):
        v = _unbox(v)
        if isinstance(v, _Pt):
            return 1
        if isinstance(v, _Sz):
            return 2
        return 0

    def AXValueGetValue(self, v, t, out):
        v = _unbox(v)
        if isinstance(v, _Pt):
            out._obj.x, out._obj.y = v.x, v.y
            return True
        if isinstance(v, _Sz):
            out._obj.w, out._obj.h = v.w, v.h
            return True
        return False


def _full_elem(frame=(100.0, 200.0, 40.0, 20.0), role="AXButton", title="存储"):
    """完整元素的 attrs（role/title/position/size 齐全）。"""
    fx, fy, fw, fh = frame
    return {"AXRole": _Str(role), "AXTitle": _Str(title),
            "AXPosition": _Pt(fx, fy), "AXSize": _Sz(fw, fh)}


def _inject(fake_as, fake_cf, ax=True):
    """把假层装进 ax_element，并钉住权限探测。返回还原函数。"""
    import sidecar.computer_use.ax_element as axe
    import sidecar.computer_use.executor as ex
    saved = (axe._LIBS, ex._ax_trusted, axe._ATTR_CACHE.copy())
    axe._LIBS = (fake_as, fake_cf)
    ex._ax_trusted = (lambda: True) if ax else (lambda: False)

    def undo():
        axe._LIBS = saved[0]
        ex._ax_trusted = saved[1]
        axe._ATTR_CACHE.clear()
        axe._ATTR_CACHE.update(saved[2])

    return undo


# ── A 组：hit_test 的 err 分支与容错（绝不向调用方抛裸异常）────────────────
def test_a_hit_test_branches():
    import sidecar.computer_use.ax_element as axe
    import sidecar.computer_use.executor as ex
    isolate_all("ax_a_")

    # A1/A2：无权限 / 权限读不到 → None（校正链据此回落像素，不阻断）
    undo = _inject(FakeAS(), FakeCF(), ax=False)
    try:
        check("A1 无 AX 权限→None 且原因为权限", axe.hit_test(10, 10) is None
              and "accessibility" in axe.LAST_ERROR, axe.LAST_ERROR)
    finally:
        undo()
    orig_trusted = ex._ax_trusted
    ex._ax_trusted = lambda: None
    undo = _inject(FakeAS(), FakeCF(), ax=True)
    ex._ax_trusted = lambda: None          # _inject 后又钉回 None（读不到按不可用）
    try:
        check("A2 权限读不到（None）→按不可用回落", axe.hit_test(10, 10) is None, "")
    finally:
        undo()
        ex._ax_trusted = orig_trusted

    # A3：非法坐标 → None + bad_arg（防把垃圾坐标交给系统 API）
    undo = _inject(FakeAS(), FakeCF())
    try:
        for bad in ((float("nan"), 1), (1, float("inf")), ("x", 1), (None, None)):
            check(f"A3 非法坐标 {bad!r}→None", axe.hit_test(*bad) is None
                  and "bad_arg" in axe.LAST_ERROR, axe.LAST_ERROR)
    finally:
        undo()

    # A4/A5：AX err 码分支（cannotComplete / apiDisabled）→ None + 可读原因
    for err, tag in ((-25204, "cannotComplete"), (-25211, "apiDisabled")):
        fas = FakeAS(hit_err=err)
        undo = _inject(fas, FakeCF())
        try:
            r = axe.hit_test(10, 10)
            check(f"A4 err={err}({tag})→None 且原因可读", r is None
                  and str(err) in axe.LAST_ERROR and tag in axe.LAST_ERROR, axe.LAST_ERROR)
        finally:
            undo()

    # A6：命中但元素无 frame（缺 AXPosition/AXSize）→ 仍返回 dict、frame=None
    fas = FakeAS(attrs={"el0": {"AXRole": _Str("AXGroup")}})
    undo = _inject(fas, FakeCF())
    try:
        r = axe.hit_test(10, 10)
        check("A6 命中无 frame→dict 且 frame=None", isinstance(r, dict)
              and r.get("role") == "AXGroup" and r.get("frame") is None, str(r))
    finally:
        undo()

    # A7：完整命中 → role/title/frame/pid 结构
    fas = FakeAS(attrs={"el0": _full_elem()})
    undo = _inject(fas, FakeCF())
    try:
        r = axe.hit_test(10, 20)
        check("A7 命中返回 role/title/frame/pid",
              r and r["role"] == "AXButton" and r["title"] == "存储"
              and r["frame"] == (100.0, 200.0, 40.0, 20.0) and r["pid"] == 4242, str(r))
        check("A7b 命中坐标已传给系统 API", fas.hit_calls == [(10.0, 20.0)], str(fas.hit_calls))
    finally:
        undo()

    # A8：⛔CFRelease 配对——Copy 来的每个对象都必须释放（sw/el/role/title/pos/size）
    fcf = FakeCF()
    fas = FakeAS(attrs={"el0": _full_elem()})
    undo = _inject(fas, fcf)
    try:
        axe.hit_test(10, 10)
        rel = fcf.released
        check("A8 CFRelease 配对（sw+元素+4 属性值全释放）",
              "sw" in rel and "el0" in rel
              and sum(1 for x in rel if isinstance(x, _Str) and x.s in ("AXButton", "存储")) == 2
              and sum(1 for x in rel if isinstance(x, _Pt)) == 1
              and sum(1 for x in rel if isinstance(x, _Sz)) == 1,
              str(rel))
    finally:
        undo()

    # A9：单个属性读取 err（AXTitle unsupported）→ 该字段 None，整体仍返回
    attrs = _full_elem()
    attrs["AXTitle"] = _ErrVal(-25205)
    undo = _inject(FakeAS(attrs={"el0": attrs}), FakeCF())
    try:
        r = axe.hit_test(10, 10)
        check("A9 单属性 err→该字段 None 但整体容错返回",
              r and r.get("title") is None and r.get("role") == "AXButton", str(r))
    finally:
        undo()

    # A10：底层抛异常（ObjC 层崩溃以外的 Python 可见异常）→ None，绝不抛给调用方
    undo = _inject(FakeAS(sw_raises=True), FakeCF())
    try:
        check("A10 底层异常→None（不抛裸异常）", axe.hit_test(10, 10) is None, axe.LAST_ERROR)
    finally:
        undo()


# ── B 组：app_elements 深度/节点上限与 count-before-index 防护 ─────────────
def _finder_tree(n_children=3, grand=2):
    """构造 1 窗口 + n 子元素 + 每子 grand 孙元素的假 AX 树。"""
    attrs = {"app_el": {"AXWindows": _Arr(["win0"])}}
    attrs["win0"] = _full_elem(frame=(50.0, 60.0, 800.0, 600.0), role="AXWindow", title="文档")
    kids = []
    for i in range(n_children):
        k = f"k{i}"
        kids.append(k)
        attrs[k] = _full_elem(frame=(60.0 + i, 70.0, 30.0, 10.0),
                              role="AXButton", title=f"按钮{i}")
        gks = []
        for j in range(grand):
            g = f"k{i}g{j}"
            gks.append(g)
            attrs[g] = _full_elem(frame=(61.0, 71.0 + j, 10.0, 5.0),
                                  role="AXStaticText", title=f"文{i}-{j}")
        attrs[k]["AXChildren"] = _Arr(gks)
    attrs["win0"]["AXChildren"] = _Arr(kids)
    return attrs


def _stub_pgrep(pid="4242"):
    """钉住 pgrep/ps：app 名 → pid；pid → 进程名。"""
    import sidecar.computer_use.ax_element as axe
    import subprocess as _sp
    orig_run = _sp.run

    def fake_run(args, **kw):
        class R:
            returncode = 0
            stdout = ""
            stderr = ""
        r = R()
        cmd = list(args)
        if cmd and cmd[0] == "pgrep":
            if "不存在app" in cmd[-1]:
                r.returncode = 1
            else:
                r.stdout = f"{pid}\n"
        elif cmd and cmd[0] == "ps":
            r.stdout = "/Applications/Fake.app/Contents/MacOS/FakeApp\n"
        return r

    axe.subprocess.run = fake_run
    return lambda: setattr(axe.subprocess, "run", orig_run)


def test_b_app_elements():
    import sidecar.computer_use.ax_element as axe
    isolate_all("ax_b_")

    # B1：app 找不到 → 空列表（不抛异常）
    undo_p = _stub_pgrep()
    undo = _inject(FakeAS(attrs={"app_el": {"AXWindows": _Arr(["win0"])}}), FakeCF())
    try:
        check("B1 app 找不到→空列表", axe.app_elements("不存在appXYZ") == []
              and "app_not_found" in axe.LAST_ERROR, axe.LAST_ERROR)
    finally:
        undo()
        undo_p()

    # B2：无权限 → 空列表
    undo_p = _stub_pgrep()
    undo = _inject(FakeAS(), FakeCF(), ax=False)
    try:
        check("B2 无 AX 权限→空列表", axe.app_elements("Finder") == [], "")
    finally:
        undo()
        undo_p()

    # B3：深度限制——0=仅窗口 / 1=加一层 / 2=加两层 / 9 钳到 2；
    #     ⛔LAST_ERROR 必须干净（变异 1 会静默截断：数量层级看似对、底层已越界）
    for depth, expect_levels, expect_n in ((0, {0}, 1), (1, {0, 1}, 4),
                                           (2, {0, 1, 2}, 10), (9, {0, 1, 2}, 10)):
        fas = FakeAS(attrs=_finder_tree())
        undo_p = _stub_pgrep()
        undo = _inject(fas, fcf := FakeCF())
        try:
            els = axe.app_elements("Finder", depth=depth)
            levels = {e["depth"] for e in els}
            check(f"B3 depth={depth}→层级 {sorted(expect_levels)} 且枚举无异常残留",
                  levels == expect_levels and len(els) == expect_n
                  and els and els[0]["role"] == "AXWindow" and axe.LAST_ERROR == "",
                  f"levels={sorted(levels)} n={len(els)} err={axe.LAST_ERROR[:80]}")
        finally:
            undo()
            undo_p()

    # B4：⛔count-before-index——children count=3 恰好全部取到且不越界
    #     （假 CF 层越界即 AssertionError；本组任何越界都会让用例直接崩掉）
    fas = FakeAS(attrs=_finder_tree(n_children=3, grand=2))
    undo_p = _stub_pgrep()
    undo = _inject(fas, FakeCF())
    try:
        els = axe.app_elements("Finder", depth=2)
        check("B4 3 子 2 孙全取到（1 窗+3 子+6 孙）",
              len(els) == 10, f"n={len(els)}")
    finally:
        undo()
        undo_p()

    # B5：⛔空数组防护——AXWindows 为空列表，任何索引都会越界（真实环境=进程 abort）
    fas = FakeAS(attrs={"app_el": {"AXWindows": _Arr([])}})
    undo_p = _stub_pgrep()
    undo = _inject(fas, FakeCF())
    try:
        check("B5 AXWindows 空数组→空列表且绝不索引", axe.app_elements("Finder") == [],
              axe.LAST_ERROR)
    finally:
        undo()
        undo_p()

    # B6：节点预算——巨量子元素被硬上限截断（禁止全树遍历，教训3）
    big = _finder_tree(n_children=3, grand=0)
    big["win0"]["AXChildren"] = _Arr([f"c{i}" for i in range(5000)])
    for i in range(5000):
        big[f"c{i}"] = {"AXRole": _Str("AXButton")}
    fas = FakeAS(attrs=big)
    undo_p = _stub_pgrep()
    undo = _inject(fas, FakeCF())
    try:
        els = axe.app_elements("Finder", depth=1)
        check("B6 5000 子元素被节点硬上限截断",
              0 < len(els) <= axe.APP_ENUM_MAX_NODES + 8, f"n={len(els)}")
    finally:
        undo()
        undo_p()

    # B7：AXWindows 属性 err → 空列表 + 可读原因
    fas = FakeAS(attrs={"app_el": {"AXWindows": _ErrVal(-25204)}})
    undo_p = _stub_pgrep()
    undo = _inject(fas, FakeCF())
    try:
        check("B7 AXWindows err=-25204→空列表", axe.app_elements("Finder") == []
              and "cannotComplete" in axe.LAST_ERROR, axe.LAST_ERROR)
    finally:
        undo()
        undo_p()

    # B8：frame/role/title 结构正确（窗口层）
    fas = FakeAS(attrs=_finder_tree())
    undo_p = _stub_pgrep()
    undo = _inject(fas, FakeCF())
    try:
        els = axe.app_elements("Finder", depth=0)
        w = els[0]
        check("B8 窗口元素结构（role/title/frame）",
              w["role"] == "AXWindow" and w["title"] == "文档"
              and w["frame"] == (50.0, 60.0, 800.0, 600.0), str(w))
    finally:
        undo()
        undo_p()

    # B9：CFRelease 配对——app_el 与 windows 数组都释放
    fcf = FakeCF()
    fas = FakeAS(attrs=_finder_tree())
    undo_p = _stub_pgrep()
    undo = _inject(fas, fcf)
    try:
        axe.app_elements("Finder", depth=1)
        rel = fcf.released
        check("B9 CFRelease 配对（app_el+AXWindows+子元素数组）",
              "app_el" in rel and any(isinstance(x, _Arr) for x in rel), str(rel)[:200])
    finally:
        undo()
        undo_p()


# ── C 组：executor 点击校正链（命中→frame 中心 / 未命中→像素回落）───────────
def test_c_correction_chain():
    import sidecar.computer_use.ax_element as axe
    import sidecar.computer_use.executor as ex
    import sidecar.config as cfg
    isolate_all("ax_c_")

    # C1：命中 → 改点 frame 中心，method=element，附 role/title
    fas = FakeAS(attrs={"el0": _full_elem(frame=(100.0, 200.0, 40.0, 20.0))})
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C1 命中→点 frame 中心", (x, y) == (120.0, 210.0), f"({x},{y})")
        check("C1b method=element 且带 role/title",
              loc.get("method") == "element" and loc.get("role") == "AXButton"
              and loc.get("title") == "存储", str(loc))
    finally:
        undo()

    # C2：未命中（err）→ 原坐标 + pixel_fallback
    fas = FakeAS(hit_err=-25212)          # kAXErrorNoValue
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C2 未命中→像素回落原坐标", (x, y) == (110, 210)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
    finally:
        undo()

    # C3：开关关 → 原坐标，且命中测试根本没被调用（零开销）
    cfg.reload_config({"cu_element_locate_enabled": False})
    fas = FakeAS(attrs={"el0": _full_elem()})
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C3 开关关→原坐标（一期纯像素行为）", (x, y) == (110, 210)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
        check("C3b 开关关→命中测试零调用", fas.hit_calls == [], str(fas.hit_calls))
    finally:
        undo()
        cfg.reload_config({"cu_element_locate_enabled": True})

    # C4：⛔零尺寸 frame → pixel_fallback（零尺寸无中心可点；变异 2 守护）
    fas = FakeAS(attrs={"el0": _full_elem(frame=(100.0, 200.0, 0.0, 20.0))})
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C4 零宽 frame→像素回落", (x, y) == (110, 210)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
    finally:
        undo()

    # C5：frame 中心越屏 → pixel_fallback（frame 异常时宁可信像素坐标）
    fas = FakeAS(attrs={"el0": _full_elem(frame=(0.0, 0.0, 100.0, 99999.0))})
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(50, 50, 1728, 1117)
        check("C5 frame 中心越屏→像素回落", (x, y) == (50, 50)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
    finally:
        undo()

    # C6：无 AX 权限 → 原坐标
    undo = _inject(FakeAS(attrs={"el0": _full_elem()}), FakeCF(), ax=False)
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C6 无权限→原坐标", (x, y) == (110, 210)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
    finally:
        undo()

    # C7：命中但 frame 缺失 → pixel_fallback
    fas = FakeAS(attrs={"el0": {"AXRole": _Str("AXGroup")}})
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C7 命中无 frame→像素回落", (x, y) == (110, 210)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
    finally:
        undo()

    # C8：⛔校正异常绝不阻断点击——hit_test 抛异常也回落原坐标
    fas = FakeAS(copy_raises=True)
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C8 校正层异常→像素回落（不阻断）", (x, y) == (110, 210)
              and loc.get("method") == "pixel_fallback", f"({x},{y}) {loc}")
    finally:
        undo()

    # C9：审计用 role/title 截断（长 title 防日志膨胀）
    fas = FakeAS(attrs={"el0": _full_elem(title="长" * 500)})
    undo = _inject(fas, FakeCF())
    try:
        x, y, loc = ex._correct_xy_by_element(110, 210, 1728, 1117)
        check("C9 命中 title 截断 ≤80 字符", len(loc.get("title", "")) <= 80
              and loc.get("method") == "element", str(len(loc.get("title", ""))))
    finally:
        undo()


# ── D 组：mouse_click 集成校正（假 CG 零真实事件）+ 审计字段 ────────────────
class FakeCG:
    """CoreGraphics 假层：事件创建/投递全部记录，⛔绝不产生真实点击。"""

    def __init__(self):
        self.events = []               # (type, x, y, btn)
        self._cf = FakeCF()

    def CGEventCreateMouseEvent(self, src, evt_type, pt, btn):
        self.events.append((evt_type, pt.x, pt.y, btn))
        return ("ev", evt_type, pt.x, pt.y)

    def CGEventCreateKeyboardEvent(self, src, code, down):
        return ("kev", code, down)

    def CGEventPost(self, tap, ev):
        pass

    def CGEventSetFlags(self, ev, flags):
        pass

    def CGEventSetIntegerValueField(self, ev, field, val):
        pass

    def CGEventKeyboardSetUnicodeString(self, ev, n, buf):
        pass

    def CGMainDisplayID(self):
        return 1

    def CGDisplayPixelsWide(self, did):
        return 1728

    def CGDisplayPixelsHigh(self, did):
        return 1117

    def CGEventSourceCreate(self, st):
        return "src"


def _install_fake_cg():
    import sidecar.computer_use.executor as ex
    fcg = FakeCG()
    saved = (ex._CG, ex._GEOM_CACHE)
    ex._CG = fcg
    ex._GEOM_CACHE = None
    return fcg, lambda: setattr(ex, "_CG", saved[0]) or setattr(ex, "_GEOM_CACHE", saved[1])


def test_d_click_integration_audit():
    import sidecar.computer_use.executor as ex
    tmp = isolate_all("ax_d_")
    log = tmp / "computer_use" / "actions.jsonl"

    def read_audit():
        if not log.exists():
            return []
        return [json.loads(x) for x in log.read_text(encoding="utf-8").splitlines() if x.strip()]

    # D1：命中 → 假 CG 收到的点击坐标 = frame 中心；审计 method=element + role/title
    fas = FakeAS(attrs={"el0": _full_elem(frame=(100.0, 200.0, 40.0, 20.0),
                                          role="AXButton", title="存储")})
    undo = _inject(fas, FakeCF())
    fcg, undo_cg = _install_fake_cg()
    try:
        r = ex.mouse_click(110, 210)
        clicks = [e for e in fcg.events if e[0] in (1, 2)]   # down/up
        check("D1 点击成功且事件真实构造（假层）", r.get("ok") is True and len(clicks) == 2,
              f"r={str(r)[:120]} events={fcg.events}")
        check("D1b ⛔点击落点=frame 中心（不是模型给的近似坐标）",
              all(abs(e[1] - 120.0) < 1e-6 and abs(e[2] - 210.0) < 1e-6 for e in clicks),
              str(clicks))
        check("D1c 返回 locate=element", (r.get("locate") or {}).get("method") == "element",
              str(r.get("locate")))
        rec = [a for a in read_audit() if a.get("action") == "click" and a.get("ok")]
        check("D1d 审计记录命中方式 element + role/title",
              rec and rec[-1].get("method") == "element"
              and rec[-1].get("role") == "AXButton" and rec[-1].get("title") == "存储",
              str(rec[-1] if rec else None))
    finally:
        undo_cg()
        undo()

    # D2：未命中 → 点击原坐标；审计 method=pixel_fallback
    fas = FakeAS(hit_err=-25212)
    undo = _inject(fas, FakeCF())
    fcg, undo_cg = _install_fake_cg()
    try:
        r = ex.mouse_click(110, 210)
        clicks = [e for e in fcg.events if e[0] in (1, 2)]
        check("D2 未命中→点击原坐标（像素回落）",
              r.get("ok") is True and clicks
              and all(abs(e[1] - 110.0) < 1e-6 and abs(e[2] - 210.0) < 1e-6 for e in clicks),
              str(clicks))
        rec = [a for a in read_audit() if a.get("action") == "click" and a.get("ok")]
        check("D2b 审计记录 pixel_fallback", rec and rec[-1].get("method") == "pixel_fallback",
              str(rec[-1] if rec else None))
    finally:
        undo_cg()
        undo()

    # D3：开关关 → 点击原坐标且命中测试零调用
    import sidecar.config as cfg
    cfg.reload_config({"cu_element_locate_enabled": False})
    fas = FakeAS(attrs={"el0": _full_elem()})
    undo = _inject(fas, FakeCF())
    fcg, undo_cg = _install_fake_cg()
    try:
        r = ex.mouse_click(110, 210)
        clicks = [e for e in fcg.events if e[0] in (1, 2)]
        check("D3 开关关→原坐标且命中测试零调用",
              r.get("ok") is True and fas.hit_calls == [] and clicks
              and all(abs(e[1] - 110.0) < 1e-6 for e in clicks),
              f"calls={fas.hit_calls} clicks={clicks}")
    finally:
        undo_cg()
        undo()
        cfg.reload_config({"cu_element_locate_enabled": True})

    # D4：⛔校正层抛异常 → 点击仍按原坐标成功（校正绝不阻断真实点击）
    fas = FakeAS(copy_raises=True)
    undo = _inject(fas, FakeCF())
    fcg, undo_cg = _install_fake_cg()
    try:
        r = ex.mouse_click(110, 210)
        clicks = [e for e in fcg.events if e[0] in (1, 2)]
        check("D4 校正异常→原坐标点击仍成功", r.get("ok") is True and clicks
              and all(abs(e[1] - 110.0) < 1e-6 for e in clicks), str(clicks))
    finally:
        undo_cg()
        undo()


# ── E 组：element_locate 只读工具（executor 层）─────────────────────────────
def test_e_element_locate():
    import sidecar.computer_use.executor as ex
    tmp = isolate_all("ax_e_")
    log = tmp / "computer_use" / "actions.jsonl"

    # E1：非法坐标 → bad_arg
    r = ex.element_locate("x", 1)
    check("E1 非法坐标→bad_arg", r.get("ok") is False and "bad_arg" in str(r.get("error")),
          str(r)[:150])

    # E2：无权限 → accessibility_denied（复用防线1 指引）
    import sidecar.computer_use.executor as exm
    orig = exm._ax_trusted
    exm._ax_trusted = lambda: False
    try:
        r = ex.element_locate(10, 10)
        check("E2 无权限→accessibility_denied 含授权指引",
              r.get("ok") is False and "accessibility_denied" in str(r.get("error"))
              and "辅助功能" in str(r.get("error")), str(r)[:200])
    finally:
        exm._ax_trusted = orig

    # E3：未命中 → ok + hit=False + 提示用原坐标（R2：Electron 树贫乏属预期）
    fas = FakeAS(hit_err=-25212)
    undo = _inject(fas, FakeCF())
    try:
        r = ex.element_locate(10, 10)
        check("E3 未命中→ok+hit=False（正常答案，非错误）",
              r.get("ok") is True and r.get("hit") is False
              and "原坐标" in str(r.get("content")), str(r)[:200])
    finally:
        undo()

    # E4：命中 → 精简字段（role/title/frame/center/app），⛔title 截断 80（变异 4 守护）
    fas = FakeAS(attrs={"el0": _full_elem(frame=(100.0, 200.0, 40.0, 20.0),
                                          role="AXButton", title="题" * 200)})
    undo = _inject(fas, FakeCF())
    try:
        r = ex.element_locate(110, 210)
        check("E4 命中→role/frame/center 字段齐全",
              r.get("ok") is True and r.get("hit") is True
              and r.get("role") == "AXButton"
              and r.get("frame") == [100.0, 200.0, 40.0, 20.0]
              and r.get("center") == [120.0, 210.0], str(r)[:250])
        check("E4b ⛔title 截断 80 字符（防大树文本爆炸）", len(r.get("title", "")) == 80,
              str(len(r.get("title", ""))))
    finally:
        undo()

    # E5：查询落审计（只读也可回溯）
    fas = FakeAS(attrs={"el0": _full_elem()})
    undo = _inject(fas, FakeCF())
    try:
        ex.element_locate(110, 210)
        lines = ([json.loads(x) for x in log.read_text(encoding="utf-8").splitlines() if x.strip()]
                 if log.exists() else [])
        rec = [a for a in lines if a.get("action") == "locate"]
        check("E5 locate 动作落审计（含命中信息）",
              rec and rec[-1].get("hit") is True and rec[-1].get("role") == "AXButton",
              str(rec[-1] if rec else None))
    finally:
        undo()


# ── F 组：config 键登记与校验（照 0.4.31 ctx_lazy_* 同款范式）────────────────
def test_f_config_key():
    import sidecar.config as cfg
    from sidecar.config.store import DEFAULT_CONFIG
    isolate_all("ax_f_")
    cfg.reload_config({})
    c = cfg.get_config()
    check("F1 cu_element_locate_enabled 已登记且默认 True",
          "cu_element_locate_enabled" in DEFAULT_CONFIG
          and c.get("cu_element_locate_enabled") is True,
          str(c.get("cu_element_locate_enabled")))
    try:
        cfg.reload_config({"cu_element_locate_enabled": "yes"})
        ok = False
    except ValueError:
        ok = True
    check("F2 非 bool 值→校验拒绝", ok)
    cfg.reload_config({"cu_element_locate_enabled": False})
    check("F3 合法 False 写入生效", cfg.get_config().get("cu_element_locate_enabled") is False)
    cfg.reload_config({"cu_element_locate_enabled": True})


# ── G 组：tools_spec 形态（CU 条件组 + 子 Agent 可见性）─────────────────────
def test_g_tools_spec():
    from sidecar.agent_engine.loop import tools_spec
    isolate_all("ax_g_")

    off = {t["function"]["name"] for t in tools_spec(with_computer_use=False)}
    on = {t["function"]["name"] for t in tools_spec(with_computer_use=True)}
    check("G1 总开关关→element_locate 不暴露（零开销）", "element_locate" not in off, str(off))
    check("G2 总开关开→element_locate 暴露", "element_locate" in on, str(on))

    sub = {t["function"]["name"] for t in
           tools_spec(with_delegation=False, with_install=False, with_computer_use=False)}
    check("G3 子 Agent 无 element_locate（同现有 CU 工具可见性规则）",
          "element_locate" not in sub, str(sub))

    el = next(t for t in tools_spec(with_computer_use=True)
              if t["function"]["name"] == "element_locate")
    props = el["function"]["parameters"]
    check("G4 element_locate 必填 x/y", set(props.get("required", [])) == {"x", "y"},
          str(props.get("required")))
    desc = el["function"]["description"]
    check("G5 描述一句话（精简风格，≤120 字符）且含「只读」",
          len(desc) <= 120 and "只读" in desc, desc)

    # 默认形态 11 工具不变（element_locate 在 CU 条件组内，不进默认形态；
    # 与 test_web_search.py:184 的计数断言同源同步）
    check("G6 默认形态仍 11 工具（test_web_search 计数不腐）",
          len(tools_spec()) == 11, str(len(tools_spec())))


# ── H 组：真机真值用例（AX 只读，无副作用；skip 条件照 test_computer_use C 组）──
def test_h_ground_truth():
    import sidecar.computer_use.ax_element as axe
    isolate_all("ax_h_")
    if os.uname().sysname != "Darwin":
        print("SKIP  H 组（非 macOS）")
        return
    if not axe.ax_available():
        # 无辅助功能授权时不判失败（同 C 组对屏幕录制权限的处理）
        print("SKIP  H 组（辅助功能未授权，真值用例跳过）")
        return
    # 菜单栏横贯屏幕顶部（高约 24~33 点）：命中 (屏宽/2, 5) 应得 AXMenuBar* 元素
    r = axe.hit_test(864, 5)
    if r is None:
        print(f"SKIP  H1（环境无可用 AX 命中：{axe.LAST_ERROR}）")
    else:
        check("H1 菜单栏命中返回结构化元素（role 非空）",
              isinstance(r, dict) and bool(r.get("role")), str(r)[:200])
        check("H1b 命中元素带屏幕绝对坐标 frame 或 role（零换算坐标系）",
              r.get("frame") is None or
              (isinstance(r["frame"], tuple) and len(r["frame"]) == 4), str(r.get("frame")))
    els = axe.app_elements("Finder", depth=1)
    if not els:
        print(f"SKIP  H2（Finder 无窗口或未运行：{axe.LAST_ERROR}）")
    else:
        check("H2 Finder 局部枚举：窗口 depth=0 且子元素 depth=1",
              els[0]["depth"] == 0 and all(e["depth"] in (0, 1) for e in els),
              str([(e.get("role"), e.get("depth")) for e in els[:6]]))
        check("H2b 元素 frame 为屏幕绝对逻辑点（坐标非负、尺寸为正）",
              all(e["frame"] is None or
                  (e["frame"][0] >= 0 and e["frame"][1] >= 0
                   and e["frame"][2] > 0 and e["frame"][3] > 0) for e in els),
              str([e.get("frame") for e in els[:4]]))


def main():
    print("=" * 70)
    print("0.4.32（CU 二期 P0+P1）AX 元素定位 + 点击校正链 专项回归")
    print("⛔ 全程不产生真实点击/输入（假 CG/CF/AS 层；真值用例只读）")
    if MUTATE:
        print(f"⚠️ 变异 {MUTATE} 已注入（预期本套件变红；全绿=断言无效）")
    print("=" * 70)
    try:
        _apply_mutation()
        test_a_hit_test_branches()
        test_b_app_elements()
        test_c_correction_chain()
        test_d_click_integration_audit()
        test_e_element_locate()
        test_f_config_key()
        test_g_tools_spec()
        if MUTATE:
            # ⛔ 变异模式跳过真机组：变异 1 这类破坏在【真实 CF 层】就是进程级
            # NSException abort（实测：H 组真实 app_elements 越界索引直接 SIGABRT，
            # finally 都来不及还原）——变异有效性由假层组验证，真机组不参与。
            print(f"SKIP  H 组（变异 {MUTATE} 模式：真值用例不参与变异验证）")
        else:
            test_h_ground_truth()
    finally:
        _restore()
    print("\n" + "=" * 70)
    print(f"===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print("  -", f)
    print("=" * 70)
    if MUTATE:
        if FAIL:
            print(f"变异 {MUTATE} 已命中（FAIL={FAIL}，符合预期）")
            return 0
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
        return 3
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
