"""#15（0.4.19）· 委派传【文档路径】，把读文件的动作交给子 Agent。

## 缺陷与修复

**缺陷**：delegate_task 此前只有 image_paths（图片由后端代读注入视觉流），
**没有文档路径通道**。主 Agent 想把 docx/pdf 交给子 Agent，唯一办法是自己先
read_file 再把全文抄进任务书 → 90KB PDF 自读、大 prompt prefill 极慢
（0.4.8 实测一次委派前空耗约 20 分钟），且长文易被截断。
用户明确要求："我要的不是他不读，而是把读的动作交给子 Agent"；
"如果没有发生委派行为，主 Agent 才自己读"。

**修复**：
1. delegate_task 增加 file_paths 参数（文档/文本路径列表）；
2. loop._resolve_delegation_files 解析+校验路径（复用图片通道的裸文件名自纠正），
   ⛔ **只解析路径、不读内容**（读的动作交给子 Agent，主 Agent 上下文不被撑爆）；
3. 路径全落空 → 拦截委派并附 _real_docs_hint 真实清单（防子 Agent 凭空编造）；
4. 任务书（普通+简单两种模式）注入【必读文件】绝对路径清单，要求子 Agent 自己 read_file；
5. 系统提示词委派纪律补"文档传路径·主 Agent 不自读"强制条。

## 依赖

#4（read_file 解析 docx/pdf）已完成——否则子 Agent 拿到路径也读不出内容，传了白传。

## 覆盖

- T1 路径解析：相对/绝对/裸文件名唯一命中/多处同名不猜/不存在/非文档扩展名/超上限
- T2 只解析不读内容：损坏文件与 0 字节文件仍能解析成功（守住"不代读"设计）
- T3 _real_docs_hint 真实清单（拦截报错用）
- T4 任务书注入【必读文件】：普通模式 + 简单模式；无文件时不注入
- T5 工具规格 delegate_task 含 file_paths
- T6 委派纪律含"文档传路径·不自读"强制条
- T7 run_delegated_task 签名含 file_paths
- T8 变异测试：三处关键修复被撤掉时必须失败

⛔ 断言一律 find()/in，不用 index()——变异模式下子串缺失抛 ValueError 会崩溃掩盖后续。

运行：./sidecar/.venv/bin/python sidecar/agent_engine/test_p15_delegation_files.py
变异：MUTATE=1|2|3 ./sidecar/.venv/bin/python sidecar/agent_engine/test_p15_delegation_files.py
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import sidecar.agent_engine.loop as lp
import sidecar.agent_engine.delegation as dg

MUTATE = int(os.environ.get("MUTATE", "0"))
_PASS = 0
_FAIL = 0
_FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    global _PASS, _FAIL
    if cond:
        _PASS += 1
        print(f"  ✅ {name}")
    else:
        _FAIL += 1
        _FAILURES.append(name)
        print(f"  ❌ {name}  {detail[:400]}")


# ── 变异注入（内存备份还原，不用 git checkout：本次修复尚未提交）──
_BACKUP: dict[str, str] = {}


def _read_src(mod) -> str:
    return Path(mod.__file__).read_text(encoding="utf-8")


def _apply_mutation() -> None:
    if not MUTATE:
        return
    _BACKUP["loop"] = _read_src(lp)
    _BACKUP["dg"] = _read_src(dg)
    if MUTATE == 1:
        # 撤掉任务书里的【必读文件】注入（file_hint 段）→ 子 Agent 收不到清单
        src = _BACKUP["dg"]
        patched = src.replace(
            '        file_hint = (\n            "【必读文件】（路径已由系统校验存在',
            '        file_hint = ("" and\n            "【必读文件】（路径已由系统校验存在')
        assert patched != src, "变异 1 未命中 delegation 任务书注入，测试无效"
        Path(dg.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 2:
        # 撤掉 delegate_task 工具规格的 file_paths 参数
        src = _BACKUP["loop"]
        patched = src.replace('"file_paths": {\n                            "type": "array",',
                              '"_file_paths_removed": {\n                            "type": "array",')
        assert patched != src, "变异 2 未命中 loop 工具规格，测试无效"
        Path(lp.__file__).write_text(patched, encoding="utf-8")
    elif MUTATE == 3:
        # 撤掉委派纪律的"文档传递·强制"条
        src = _BACKUP["loop"]
        patched = src.replace('"- 【文档传递·强制】委派涉及文档', '"- 【XX删除XX】委派涉及文档')
        assert patched != src, "变异 3 未命中 loop 委派纪律，测试无效"
        Path(lp.__file__).write_text(patched, encoding="utf-8")
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")


def _restore() -> None:
    if not MUTATE or not _BACKUP:
        return
    try:
        if "loop" in _BACKUP and _read_src(lp) != _BACKUP["loop"]:
            Path(lp.__file__).write_text(_BACKUP["loop"], encoding="utf-8")
        if "dg" in _BACKUP and _read_src(dg) != _BACKUP["dg"]:
            Path(dg.__file__).write_text(_BACKUP["dg"], encoding="utf-8")
    finally:
        _BACKUP.clear()


def _reload_modules() -> None:
    import importlib
    importlib.reload(lp)
    importlib.reload(dg)


# ── 测试 ──────────────────────────────────────────────────

def _mk(p: Path, content: bytes = b"x") -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(content)


def _b(s: str) -> bytes:
    """中文字符串 → bytes。

    ⛔ 教训（本项目第二次踩同一坑）：bytes 字面量 **只能含 ASCII**，
    `b"这不是合法 zip"` 直接 SyntaxError，整个测试文件无法加载。
    写含中文的样本一律走 `_b("...")` / `.encode("utf-8")`，不要写 b"中文"。
    """
    return s.encode("utf-8")


def _rp(p: Path) -> str:
    """期望路径 → 与解析结果可比的字符串。

    ⛔ macOS 临时目录的 /var 是 /private/var 的符号链接，而
    resolve_sandboxed_path 内部会 resolve() 规范化路径。直接拿
    str(tmpdir / "x.docx") 与解析结果做字符串相等/包含比较必然假失败
    （'/var/...' != '/private/var/...'）。断言前一律先 resolve。
    """
    return str(p.resolve())


def t1_resolve_paths(tmp: Path) -> None:
    print("\nT1 路径解析：相对/绝对/裸名自纠正/多处同名/不存在/非文档/超上限")
    sb = tmp / "sb"
    _mk(sb / "证据" / "律师函.docx")
    _mk(sb / "借条.txt")
    _mk(sb / "目录A" / "合同.docx")
    _mk(sb / "目录B" / "合同.docx")   # 与 A 同名 → 裸名"合同.docx"多处命中，不猜
    _mk(sb / "图.png")                # 非文档扩展名 → 应跳过（图片走 image_paths）

    ok, skipped = lp._resolve_delegation_files(
        ["证据/律师函.docx", "借条.txt"], str(sb))
    check("相对路径解析为绝对路径", len(ok) == 2 and all(Path(p).is_absolute() for p in ok), str(ok))
    check("解析结果文件真实存在", all(Path(p).is_file() for p in ok), str(ok))
    check("相对路径无跳过", not skipped, str(skipped))

    ok2, _ = lp._resolve_delegation_files([str(sb / "证据" / "律师函.docx")], str(sb))
    check("绝对路径直接采用", len(ok2) == 1 and ok2[0] == _rp(sb / "证据" / "律师函.docx"), str(ok2))

    ok3, sk3 = lp._resolve_delegation_files(["律师函.docx"], str(sb))
    check("裸文件名唯一命中 → 自纠正到子目录", len(ok3) == 1 and "证据" in ok3[0], str(ok3))

    ok4, sk4 = lp._resolve_delegation_files(["合同.docx"], str(sb))
    check("裸文件名多处同名 → 不猜、跳过", len(ok4) == 0 and sk4 == ["合同.docx"], f"ok={ok4} sk={sk4}")

    ok5, sk5 = lp._resolve_delegation_files(["不存在的.docx"], str(sb))
    check("不存在的文件 → 跳过", len(ok5) == 0 and sk5 == ["不存在的.docx"], f"ok={ok5} sk={sk5}")

    ok6, sk6 = lp._resolve_delegation_files(["图.png"], str(sb))
    check("非文档扩展名（图片）→ 跳过（应走 image_paths）", len(ok6) == 0 and sk6 == ["图.png"],
          f"ok={ok6} sk={sk6}")

    many = [f"借条.txt"] * (lp._MAX_DELEGATION_FILES + 5)
    ok7, sk7 = lp._resolve_delegation_files(many, str(sb))
    check(f"超上限（>{lp._MAX_DELEGATION_FILES}）→ 截断且多余标跳过",
          len(ok7) <= lp._MAX_DELEGATION_FILES and len(sk7) >= 5, f"ok={len(ok7)} sk={len(sk7)}")

    ok8, sk8 = lp._resolve_delegation_files([], str(sb))
    check("空列表 → 空结果不报错", ok8 == [] and sk8 == [], f"ok={ok8}")
    ok9, sk9 = lp._resolve_delegation_files(None, str(sb))
    check("None → 空结果不报错", ok9 == [] and sk9 == [], f"ok={ok9}")


def t2_no_content_read(tmp: Path) -> None:
    print("\nT2 只解析路径、不读内容（核心设计：读的动作交给子 Agent）")
    sb = tmp / "sb2"
    # ⛔ 损坏的 docx（不是合法 zip）和 0 字节文件——若函数"代读内容"必然失败/抛错，
    # 但它只校验路径，所以应解析成功。以此间接守住"不代读"设计。
    _mk(sb / "损坏.docx", _b("这不是合法 zip，只是扩展名叫 docx"))
    _mk(sb / "空.docx", b"")
    _mk(sb / "正常.txt", _b("内容"))

    ok, skipped = lp._resolve_delegation_files(
        ["损坏.docx", "空.docx", "正常.txt"], str(sb))
    check("损坏文档仍解析成功（证明未读内容）", _rp(sb / "损坏.docx") in ok, f"ok={ok}")
    check("0 字节文档仍解析成功（证明未读内容）", _rp(sb / "空.docx") in ok, f"ok={ok}")
    check("三个路径全部解析、无跳过", len(ok) == 3 and not skipped, f"ok={ok} sk={skipped}")
    # 返回值是路径字符串，不是文件内容
    check("返回值是路径而非内容", all(isinstance(p, str) and Path(p).exists() for p in ok), str(ok))


def t3_real_docs_hint(tmp: Path) -> None:
    print("\nT3 真实文档清单（拦截报错时供主 Agent 自纠正）")
    sb = tmp / "sb3"
    _mk(sb / "证据" / "律师函.docx")
    _mk(sb / "借条.txt")
    _mk(sb / "图.png")   # 图片不该出现在文档清单里
    hint = lp._real_docs_hint(str(sb))
    check("清单含 docx 绝对路径", str(sb / "证据" / "律师函.docx") in hint, hint[:300])
    check("清单含 txt", "借条.txt" in hint, hint[:300])
    check("清单不含图片（图片走 image_paths）", "图.png" not in hint, hint[:300])
    check("清单标注总数", "共 2 个" in hint, hint[:200])

    empty = tmp / "sb3empty"
    empty.mkdir(parents=True, exist_ok=True)
    hint2 = lp._real_docs_hint(str(empty))
    check("空目录如实说明未找到", "未找到任何文档" in hint2, hint2[:200])


def t4_task_message_injection() -> None:
    print("\nT4 任务书注入【必读文件】：普通模式 + 简单模式")
    files = ["/abs/证据/律师函.docx", "/abs/借条.txt"]

    # 普通模式
    msg = dg._task_user_message("tid-1", "整理证据", "输出清单", file_paths=files)
    check("普通模式含【必读文件】标题", "【必读文件】" in msg, msg[:400])
    check("普通模式列出全部绝对路径",
          "/abs/证据/律师函.docx" in msg and "/abs/借条.txt" in msg, msg[:500])
    check("普通模式要求子 Agent 自己 read_file", "read_file" in msg, msg[:500])
    check("普通模式禁止臆测内容", "禁止凭文件名臆测" in msg or "臆测" in msg, msg[:600])

    # 简单模式（措辞从简但同样要带清单）
    smsg = dg._task_user_message_simple("tid-2", "转写", "输出文字", file_paths=files)
    check("简单模式含【必读文件】", "【必读文件】" in smsg, smsg[:400])
    check("简单模式列出绝对路径", "/abs/证据/律师函.docx" in smsg, smsg[:400])
    check("简单模式仍要求 read_file", "read_file" in smsg, smsg[:400])

    # 无文件时不注入（防回归：纯文本委派任务书不应平白多出空清单段）
    msg_none = dg._task_user_message("tid-3", "算个数", "给结果", file_paths=None)
    check("普通模式无文件时不注入【必读文件】", "【必读文件】" not in msg_none, msg_none[:300])
    smsg_none = dg._task_user_message_simple("tid-4", "算个数", "给结果", file_paths=[])
    check("简单模式空列表不注入【必读文件】", "【必读文件】" not in smsg_none, smsg_none[:300])

    # 任务书既有结构不被破坏
    check("任务目标仍在", "整理证据" in msg, msg[:300])
    check("交卷标准仍在", "输出清单" in msg, msg[:300])


def t5_tool_spec() -> None:
    print("\nT5 工具规格 delegate_task 含 file_paths")
    spec = lp.tools_spec(with_delegation=True)
    dt = next((s for s in spec if s.get("function", {}).get("name") == "delegate_task"), None)
    check("delegate_task 工具存在", dt is not None)
    if dt is None:
        return
    props = dt["function"]["parameters"]["properties"]
    check("含 file_paths 参数", "file_paths" in props, str(list(props)))
    check("file_paths 是数组类型",
          props.get("file_paths", {}).get("type") == "array", str(props.get("file_paths")))
    desc = props.get("file_paths", {}).get("description", "")
    check("file_paths 描述强调子 Agent 自己读", "read_file" in desc or "子 Agent" in desc, desc[:200])
    check("file_paths 描述禁止主 Agent 自读",
          "绝不要自己先读" in desc or "不要自己先读" in desc, desc[:250])
    # 子会话不得拿到委派工具（防递归，既有约束未回归）
    spec_child = lp.tools_spec(with_delegation=False)
    check("子会话无 delegate_task（防递归未回归）",
          not any(s.get("function", {}).get("name") == "delegate_task" for s in spec_child))


def t6_delegation_discipline() -> None:
    print("\nT6 委派纪律含'文档传路径·主 Agent 不自读'强制条")
    prompt = lp.build_system_prompt(
        agent_name="主理人", agent_role="lawyer", sandbox_root="/tmp/sb",
        network_switch="off", can_delegate=True)
    check("提示词含【文档传递】纪律", "文档传递" in prompt, prompt[-1200:])
    check("纪律要求用 file_paths 传路径", "file_paths" in prompt, prompt[-1200:])
    check("纪律禁止主 Agent 自己先读全文",
          "绝不要自己先 read_file" in prompt or "不要自己先 read_file" in prompt, prompt[-1200:])
    check("纪律说明只有不委派时才自读",
          "不委派" in prompt and "才自己 read_file" in prompt, prompt[-1200:])
    # 既有图片传递纪律未回归
    check("图片传递纪律仍在（未回归）", "【图片传递】" in prompt, prompt[-1200:])
    # 不可委派时不注入委派纪律
    p2 = lp.build_system_prompt(agent_name="子", agent_role="x", sandbox_root="/tmp/sb",
                                network_switch="off", can_delegate=False)
    check("can_delegate=False 不注入文档纪律", "文档传递" not in p2, p2[-600:])


def t7_signature() -> None:
    print("\nT7 run_delegated_task 签名含 file_paths")
    import inspect
    sig = inspect.signature(dg.run_delegated_task)
    check("file_paths 是形参", "file_paths" in sig.parameters, str(list(sig.parameters)))
    fp = sig.parameters.get("file_paths")
    check("file_paths 有默认值 None（不破坏既有调用方）",
          fp is not None and fp.default is None, str(fp))
    # 两个任务书模板都接受 file_paths
    check("_task_user_message 接受 file_paths",
          "file_paths" in inspect.signature(dg._task_user_message).parameters)
    check("_task_user_message_simple 接受 file_paths",
          "file_paths" in inspect.signature(dg._task_user_message_simple).parameters)


def main() -> int:
    print("=" * 72)
    print(f"#15 委派传文档路径测试  |  变异模式 = {MUTATE}")
    print("=" * 72)
    _apply_mutation()
    if MUTATE:
        _reload_modules()
    try:
        with tempfile.TemporaryDirectory(prefix="p15_") as td:
            tmp = Path(td)
            t1_resolve_paths(tmp)
            t2_no_content_read(tmp)
            t3_real_docs_hint(tmp)
        # 变异 reload 后须用最新模块对象（t4~t7 直接引用 dg/lp 模块属性，reload 已更新）
        t4_task_message_injection()
        t5_tool_spec()
        t6_delegation_discipline()
        t7_signature()
    finally:
        _restore()
        if MUTATE:
            _reload_modules()

    print("\n" + "=" * 72)
    print(f"结果：{_PASS} 通过 / {_FAIL} 失败")
    if _FAILURES:
        print("失败项：" + "；".join(_FAILURES))
    if MUTATE and _FAIL == 0:
        print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
    print("=" * 72)
    return 1 if _FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
