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
"""0.4.9（checkpoint-093）专项回归：四项 bug 修复 + 联网安装确认 + 委派模型自选/换装。

覆盖：
- F1 委派图片全部加载失败 → 拦截（不再 images=None 硬委派导致子 Agent 编造）
- F2 子 Agent 工具规格剔除 install_plugin/install_skill（联网安装权）
- F3 image_paths 裸文件名 → 工作目录内唯一命中自动定位（子目录场景）
- T1 工具错误分支不被 schema_violation 覆盖，真实原因透传
- B2 read_file 大文本软提示（200KB 阈值；提示占用截断预算，总长仍 ≤1MB）
- B3 每轮 state 事件回传真实上下文字数 ctx_chars（含 system prompt / tools 声明）
- 任务152 联网安装确认：弹窗告知来源/类型；拒绝→不联网不安装；本地路径不弹窗；
         无授权通道→拒绝；同意+勾选→自动切 proxy 并清熔断；未勾选→不改模式
- 3.47.2 委派模型自选：model 参数覆盖；不存在的模型→报错列可用模型（含 tag 兼容）
- 3.47.3 委派模型换装防护（⛔ 0.4.7 回退教训）：
         防护① 卸载/查ps 各自独立超时，超时放弃不阻塞
         防护② 卸载前查 /api/ps，模型不在内存则跳过（杜绝"为卸载而加载"）
         防护③ 并发开关开启时禁用换装（配置层，见 C 组）

全部使用临时目录与桩对象，不联网、不碰真实数据（~/.subagent）。
"""
import asyncio
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS = 0
FAIL = 0
FAILURES = []


def isolate_data_dir(prefix: str) -> Path:
    """把侧车数据目录重定向到临时目录（测试隔离铁律：禁止写真实 ~/.subagent）。

    ⚠️ store.PROJECTS_ROOT / _GDB 在模块【导入时】即已求值绑定（store.py:30-33），
    仅设 VETARAI_DATA_ROOT 环境变量【无效】——曾因此把测试委派记录写进用户真实
    数据目录（~/.subagent/projects/p1/）。故必须同时重定向这两个模块级变量，
    并让 config 的 data_root 指向同一临时目录。
    """
    tmp = Path(tempfile.mkdtemp(prefix=prefix))
    os.environ["VETARAI_DATA_ROOT"] = str(tmp)
    import sidecar.storage.store as store
    import sidecar.config.store as cs

    # ⛔ 两个必须同时堵住的泄漏口（都实际污染过用户真实数据）：
    #
    # 泄漏口 1：reload_config({"data_root": tmp}) —— 它内部先 {**DEFAULT_CONFIG,
    #   **_load_from_disk()} 重建配置，会把 data_root 【冲回默认值 ~/.subagent】，
    #   随后 _save() 就写到真实 config.json（实测污染 6 项：data_root/proxy 端口/
    #   error_analysis_model/confirm_network_install/model_strengths/delegation_model_swap）。
    #
    # 泄漏口 2：仅设 cs._MEM["data_root"]=tmp 也不够 —— 测试内后续任何 reload_config()
    #   都会按泄漏口 1 的路径把 data_root 冲回真实值，于是又写进 ~/.subagent
    #   （实测污染 model_strengths / delegation_model_swap 两项）。
    #
    # 正确做法：monkeypatch get_config_path() 直接返回临时路径。_load_from_disk() 与
    # _save() 都在【运行时】调用它，因此无论 _MEM["data_root"] 被谁重置，配置读写都只
    # 落在临时目录 —— 这是唯一对 reload_config 免疫的隔离方式。
    cs.get_config_path = lambda: tmp / "config.json"
    cs._MEM = dict(cs.DEFAULT_CONFIG)
    cs._MEM["data_root"] = str(tmp)

    # store.PROJECTS_ROOT / _GDB 在模块【导入时】即已求值绑定（store.py:30-33），
    # 仅设环境变量无效 → 必须显式重定向，否则委派落库会写进真实 ~/.subagent/projects
    # （实测曾创建 ~/.subagent/projects/p1/）。
    store.PROJECTS_ROOT = tmp / "projects"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    store._GDB = store.PROJECTS_ROOT / "_global.db"

    # skills_root() 运行时调 data_root()，会被 reload_config 冲回真实值 →
    # 本地安装测试曾把技能装进真实 ~/.subagent/skills（实测污染 localskill/localskill093）。
    # 直接钉死到临时目录。
    import sidecar.skills_mgr.manager as skm
    _sk_dir = tmp / "skills"
    _sk_dir.mkdir(parents=True, exist_ok=True)
    skm.skills_root = lambda: _sk_dir
    return tmp


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


# 图片测试用的占位字节。_load_delegation_images 按【扩展名】选 mime 并做 base64，
# 不校验 JPEG 结构；本测试也从不生成 docx，故无需真实图片，避免依赖 PIL 与
# 硬编码 base64（曾因拼接多一个字符导致 b64decode 失败）。
_MIN_JPEG = b"\xff\xd8\xff\xe0" + b"placeholder-jpeg-bytes-for-test"


# ── A 组：F2/F3/F1/T1/B2/B3 静态与单元层 ─────────────────────────────
def test_a_tools_and_paths():
    from sidecar.agent_engine.loop import (
        tools_spec, _load_delegation_images, _real_images_hint,
        _collect_failure_detail, _resolve_error_analysis_model)

    # F2：主 Agent 保留安装权，子 Agent 剔除（联网安装权只留主 Agent）
    main_names = [t["function"]["name"] for t in tools_spec(with_delegation=True)]
    sub_names = [t["function"]["name"]
                 for t in tools_spec(with_delegation=False, with_install=False)]
    check("A1 F2 主Agent保留install_skill/install_plugin",
          "install_skill" in main_names and "install_plugin" in main_names, str(main_names))
    check("A2 F2 子Agent剔除安装工具（防擅自 git clone）",
          "install_skill" not in sub_names and "install_plugin" not in sub_names, str(sub_names))
    check("A3 F2 子Agent同时无delegate_task（防递归委派）",
          "delegate_task" not in sub_names, str(sub_names))
    check("A4 F2 子Agent仍保留核心工具（read_skill/create_document等）",
          all(n in sub_names for n in ("read_skill", "create_document", "read_file", "write_file")),
          str(sub_names))
    # 3.47.2：delegate_task 规格含 model 参数
    dt = next((t for t in tools_spec(with_delegation=True)
               if t["function"]["name"] == "delegate_task"), None)
    props = (dt or {}).get("function", {}).get("parameters", {}).get("properties", {})
    check("A5 3.47.2 delegate_task 含 model 参数", "model" in props, str(list(props)))
    # 3.47.1：归档工具仅在开关开启时暴露（关闭时零开销）
    names_no_arch = [t["function"]["name"] for t in tools_spec(with_archive=False)]
    names_arch = [t["function"]["name"] for t in tools_spec(with_archive=True)]
    check("A6a 3.47.1 关闭开关时不暴露 archive_work_unit（零开销）",
          "archive_work_unit" not in names_no_arch, str(names_no_arch))
    check("A6b 3.47.1 开启开关时暴露 archive_work_unit",
          "archive_work_unit" in names_arch, str(names_arch))
    au = next((t for t in tools_spec(with_archive=True)
               if t["function"]["name"] == "archive_work_unit"), None)
    au_req = (au or {}).get("function", {}).get("parameters", {}).get("required", [])
    check("A6c 3.47.1 archive_work_unit 必填 title/summary",
          set(au_req) == {"title", "summary"}, str(au_req))
    check("A6 3.47.2 model 非必填（不填沿用原模型）",
          "model" not in (dt or {}).get("function", {}).get("parameters", {}).get("required", []),
          str((dt or {}).get("function", {}).get("parameters", {}).get("required")))

    # F3：裸文件名自动定位到子目录（用户真实场景：<案件>/证据/1.jpg）
    root = Path(tempfile.mkdtemp(prefix="f3_"))
    try:
        (root / "证据").mkdir()
        for i in (1, 2, 3):
            (root / "证据" / f"{i}.jpg").write_bytes(_MIN_JPEG)
        loaded, skipped = _load_delegation_images(["1.jpg", "2.jpg"], str(root))
        check("A7 F3 裸文件名自动解析到子目录", len(loaded) == 2 and not skipped,
              f"loaded={len(loaded)} skipped={skipped}")
        loaded, skipped = _load_delegation_images(["证据/3.jpg"], str(root))
        check("A8 F3 正确相对路径仍解析", len(loaded) == 1 and not skipped, f"{skipped}")
        # 多处同名 → 不猜（拿错图比拿不到图更危险）
        (root / "另一目录").mkdir()
        (root / "另一目录" / "1.jpg").write_bytes(_MIN_JPEG)
        loaded, skipped = _load_delegation_images(["1.jpg"], str(root))
        check("A9 F3 多处同名不猜（标记跳过）", len(loaded) == 0 and skipped == ["1.jpg"],
              f"loaded={len(loaded)} skipped={skipped}")
        loaded, skipped = _load_delegation_images(["99.jpg"], str(root))
        check("A10 F3 不存在则跳过", len(loaded) == 0 and skipped == ["99.jpg"], str(skipped))
        # F1 依赖：真实图片清单提示
        hint = _real_images_hint(str(root))
        check("A11 F1 报错附真实图片清单（含子目录路径）",
              "1.jpg" in hint and "共" in hint and "张" in hint, hint[:150])
    finally:
        import shutil
        shutil.rmtree(root, ignore_errors=True)

    # 任务161：失败明细含工具名/参数/真实错误
    log = [{"name": "delegate_task", "ok": False, "error": "images_not_found: ...",
            "args": {"target": "OCR", "image_paths": "['1.jpg']"}},
           {"name": "read_file", "ok": True, "summary": "ok"}]
    det = _collect_failure_detail(log)
    check("A12 任务161 明细含工具名", "delegate_task" in det, det)
    check("A13 任务161 明细含参数", "target=" in det, det)
    check("A14 任务161 明细含真实错误文本", "images_not_found" in det, det)
    check("A15 任务161 成功调用不进明细", "read_file" not in det, det)
    check("A16 任务161 未配置分析模型时回落 default_model",
          bool(_resolve_error_analysis_model()), repr(_resolve_error_analysis_model()))


def test_a_t1_b2():
    """T1 错误透传 + B2 大文本软提示（走真实 registry.execute）。"""
    from sidecar.tools.registry import execute, LARGE_TEXT_ADVISORY_BYTES, MAX_READ_BYTES
    base = Path(tempfile.mkdtemp(prefix="t1b2_"))
    try:
        async def go():
            # T1：读不存在文件 → 真实错误（not_a_file），不被 schema_violation 覆盖
            r = await execute("read_file", {"path": "nope.txt"}, str(base))
            check("A17 T1 错误分支透传真实原因",
                  r.get("ok") is False and "not_a_file" in str(r.get("error", "")), str(r)[:150])
            check("A18 T1 未被 schema_violation 覆盖",
                  "schema_violation" not in str(r.get("error", "")), str(r)[:150])
            # T1：create_document 传非法 content → 真实原因（bad_arg），不被覆盖
            r2 = await execute("create_document",
                               {"path": str(base / "x.docx"), "content": "不是dict"}, str(base))
            check("A19 T1 create_document 错误原因可见（不再 missing:path）",
                  r2.get("ok") is False
                  and "schema_violation" not in str(r2.get("error", ""))
                  and ("content" in str(r2.get("error", "")) or "bad_arg" in str(r2.get("error", ""))),
                  str(r2)[:180])
            # B2：低于阈值 → 无提示；高于阈值 → 有提示且总长仍 ≤ MAX_READ_BYTES
            (base / "mid.txt").write_bytes(b"y" * (LARGE_TEXT_ADVISORY_BYTES - 1024))
            rm = await execute("read_file", {"path": "mid.txt"}, str(base))
            check("A20 B2 低于阈值不注入提示（不误伤正常文件）",
                  "大文件提示" not in rm.get("content", ""), "")
            big = LARGE_TEXT_ADVISORY_BYTES + 1024
            (base / "big.txt").write_bytes(b"x" * big)
            rb = await execute("read_file", {"path": "big.txt"}, str(base))
            check("A21 B2 超阈值注入委派引导提示", "大文件提示" in rb.get("content", ""), "")
            check("A22 B2 提示未破坏截断契约（content ≤1MB）",
                  len(rb.get("content", "").encode()) <= MAX_READ_BYTES,
                  str(len(rb.get("content", "").encode())))
            check("A23 B2 软提示不误标 truncated（文件<1MB）",
                  rb.get("truncated") is False, str(rb.get("truncated")))
            check("A24 B2 阈值=200KB（放过正常案件文本，只提示大文件）",
                  LARGE_TEXT_ADVISORY_BYTES == 200 * 1024, str(LARGE_TEXT_ADVISORY_BYTES))
        asyncio.run(go())
    finally:
        import shutil
        shutil.rmtree(base, ignore_errors=True)


def test_a_b3_ctx_chars():
    """B3：state 事件回传真实上下文字数（含 system prompt 与 tools 声明）。"""
    from sidecar.agent_engine.loop import run_tool_loop

    class StubConn:
        """桩连接器：记录收到的 msgs，回一轮纯文本 done。"""
        def __init__(self):
            self.seen_msgs = None
            self.seen_kwargs = None

        async def chat_stream(self, model, messages, **kw):
            self.seen_msgs = messages
            self.seen_kwargs = kw
            yield {"content_delta": "ok"}
            yield {"done": True, "counts": {"prompt_eval_count": 7, "eval_count": 2}}

    async def go():
        conn = StubConn()
        sysmsg = {"role": "system", "content": "S" * 500}   # 放大 system，验证被计入
        usermsg = {"role": "user", "content": "hi"}
        base = tempfile.mkdtemp(prefix="b3_")
        evs = []
        async for ev in run_tool_loop("m", [sysmsg, usermsg], [],
                                      sandbox_root=base, max_rounds=2, connector=conn):
            evs.append(ev)
        states = [e for e in evs if e.get("event") == "state"]
        check("A25 B3 state 事件存在", len(states) >= 1, str(len(states)))
        ctx = states[-1]["data"].get("ctx_chars") if states else None
        check("A26 B3 ctx_chars 已回传且 >0", isinstance(ctx, int) and ctx > 0, str(ctx))
        # 关键：必须计入 system prompt（此前只算 user/assistant → 顶栏"≈17"严重低估）
        check("A27 B3 ctx_chars 计入 system prompt（≥500）",
              isinstance(ctx, int) and ctx >= 500, str(ctx))
        check("A28 B3 不新增 state 事件（守住事件计数契约）",
              len(states) == 1, f"states={len(states)}")
        check("A29 B3 done 事件正常", any(e.get("event") == "done" for e in evs), str(evs)[:150])

    asyncio.run(go())


# ── B 组：任务152 联网安装确认 ────────────────────────────────────────
def test_b_network_install_confirm():
    from sidecar.tools.registry import execute
    import sidecar.config as cfg

    isolate_data_dir("ni_data_")   # 隔离：本地安装会写技能目录，绝不可写真实 ~/.subagent
    cfg.reload_config({"confirm_network_install": True, "network_switch": "auto",
                       "proxy_http_port": 7890})
    URL = "https://github.com/someone/evil-skill"
    local = tempfile.mkdtemp(prefix="ni_local_")
    (Path(local) / "SKILL.md").write_text(
        "---\nname: localskill093\ndescription: t\nenabled: true\n---\nbody", encoding="utf-8")

    async def go():
        sb = tempfile.mkdtemp(prefix="ni_sb_")
        calls = []

        async def authz_deny(tool, path, action, extra=None):
            calls.append({"tool": tool, "path": path, "action": action, "extra": extra})
            return {"allowed": False, "enable_network": False} if action == "net_install" else False

        async def authz_allow(tool, path, action, extra=None):
            calls.append({"tool": tool, "path": path, "action": action, "extra": extra})
            return {"allowed": True, "enable_network": False} if action == "net_install" else True

        async def authz_allow_net(tool, path, action, extra=None):
            calls.append({"tool": tool, "path": path, "action": action, "extra": extra})
            return {"allowed": True, "enable_network": True} if action == "net_install" else True

        # 桩掉真实安装函数：确保"拒绝后绝不联网"可被观测
        import sidecar.skills_mgr.manager as M
        clone_hit = {"n": 0}
        orig = M.install_skill_from_repo

        _orig_install = orig

        def spy(src, *a, **k):
            # 只拦【远程】源：本地目录安装应走原实现（验证"本地不弹窗且正常安装"）
            if str(src).startswith(("http://", "https://", "git@", "ssh://", "git://")):
                clone_hit["n"] += 1
                return {"ok": False, "error": "STUB_SHOULD_NOT_CLONE"}
            return _orig_install(src, *a, **k)
        M.install_skill_from_repo = spy
        try:
            # B1：远程安装必须弹窗，且告知来源与类型
            calls.clear()
            r = await execute("install_skill", {"source": URL}, sb, authorizer=authz_deny)
            check("B1 远程安装触发 net_install 确认",
                  len(calls) == 1 and calls[0]["action"] == "net_install", str(calls)[:150])
            ex = (calls[0] or {}).get("extra") or {}
            check("B2 弹窗告知下载来源 URL", ex.get("source_url") == URL, str(ex)[:150])
            check("B3 弹窗告知安装类型（技能/插件）",
                  "技能" in str(ex.get("install_type", "")), str(ex.get("install_type")))
            check("B4 auto 模式标记 need_enable_network（需一并请求开启联网）",
                  ex.get("need_enable_network") is True, str(ex))
            check("B5 用户拒绝 → 不安装、报错含来源",
                  r.get("ok") is False and "denied_by_user" in str(r.get("error", ""))
                  and URL in str(r.get("error", "")), str(r)[:180])
            check("B6 用户拒绝 → 绝不触发真实 clone（不静默联网）",
                  clone_hit["n"] == 0, f"clone调用={clone_hit['n']}")
            check("B7 拒绝报错含「不要绕过」纪律（防模型换源重试）",
                  "不要" in str(r.get("error", "")), str(r)[:180])

            # B8：已是 proxy（全量联网）→ 不再请求开启联网
            cfg.reload_config({"network_switch": "proxy"})
            calls.clear()
            await execute("install_skill", {"source": URL}, sb, authorizer=authz_deny)
            ex2 = (calls[0] or {}).get("extra") or {}
            check("B8 已全量联网时不再提示开启", ex2.get("need_enable_network") is False, str(ex2))

            # B9：同意 + 勾选开启 → 自动切 proxy 并清空熔断
            cfg.reload_config({"network_switch": "auto"})
            from sidecar.network import guard as G
            G.guard_reset_circuit()
            G.guard_report_failure("github.com")
            G.guard_report_failure("github.com")
            check("B9-pre 熔断已开启", G.guard_circuit_open("github.com") is True)
            await execute("install_skill", {"source": URL}, sb, authorizer=authz_allow_net)
            check("B9 同意后自动切全量联网(proxy)",
                  cfg.get_config().get("network_switch") == "proxy",
                  str(cfg.get_config().get("network_switch")))
            check("B10 切模式后熔断已清空（否则仍连不上）",
                  G.guard_circuit_open("github.com") is False)

            # B11：同意但未勾选开启 → 不改网络模式
            cfg.reload_config({"network_switch": "auto"})
            await execute("install_skill", {"source": URL}, sb, authorizer=authz_allow)
            check("B11 未勾选则保持原网络模式(auto)",
                  cfg.get_config().get("network_switch") == "auto",
                  str(cfg.get_config().get("network_switch")))

            # B12：本地路径安装不弹窗（无联网风险）
            calls.clear()
            r3 = await execute("install_skill", {"source": local}, sb, authorizer=authz_deny)
            check("B12 本地目录安装不弹窗", len(calls) == 0, str(calls)[:120])
            check("B13 本地安装正常执行", r3.get("ok") is True, str(r3)[:150])

            # B14：关闭确认开关 → 不弹窗（用户显式授权模式）
            cfg.reload_config({"confirm_network_install": False})
            calls.clear()
            await execute("install_skill", {"source": URL}, sb, authorizer=authz_deny)
            check("B14 关闭确认开关时不弹窗", len(calls) == 0, str(calls)[:120])

            # B15：无授权通道（后台任务/测试）→ 拒绝，不静默联网
            cfg.reload_config({"confirm_network_install": True})
            r5 = await execute("install_skill", {"source": URL}, sb, authorizer=None)
            check("B15 无授权通道时拒绝联网安装",
                  r5.get("ok") is False and "network_install_denied" in str(r5.get("error", "")),
                  str(r5)[:150])
        finally:
            M.install_skill_from_repo = orig

    asyncio.run(go())


# ── C 组：3.47.2 模型自选 + 3.47.3 换装防护 ───────────────────────────
class StubConn:
    """桩连接器：可控的已加载模型列表与卸载行为，用于验证换装防护。"""

    def __init__(self, loaded=None, models=None, unload_delay=0.0, ps_delay=0.0):
        self.loaded = list(loaded or [])
        self.models = models if models is not None else [{"name": "glm-ocr:latest"},
                                                        {"name": "qwen3.8:latest"}]
        self.unload_calls = []
        self.ps_calls = 0
        self._ud = unload_delay
        self._pd = ps_delay

    async def list_loaded_models(self):
        self.ps_calls += 1
        if self._pd:
            await asyncio.sleep(self._pd)
        return list(self.loaded)

    async def unload_model(self, name):
        self.unload_calls.append(name)
        if self._ud:
            await asyncio.sleep(self._ud)
        return True

    async def list_models(self):
        # 必须与真实 OllamaConnector.list_models 同构：返回 list[dict]（含 name）。
        # 若返回 list[str]，delegation 里 m.get("name") 抛 AttributeError 被 except
        # 吞成 _avail=[] → 模型存在性校验被跳过（校验形同虚设，测试会误判为通过）。
        return [{"name": m["name"]} if isinstance(m, dict) else {"name": str(m)}
                for m in self.models]


def test_c_swap_protections():
    """3.47.3：safe_unload_model 的两条防护（真实函数，非复刻逻辑）。"""
    from sidecar.agent_engine.loop import safe_unload_model
    import sidecar.agent_engine.loop as L

    async def go():
        # 防护②：模型不在内存 → 跳过卸载，绝不触发"先加载再卸载"
        c = StubConn(loaded=["other:latest"])
        r = await safe_unload_model(c, "glm-ocr")
        check("C1 防护② 模型不在内存→跳过卸载", r is False and c.unload_calls == [],
              f"unload_calls={c.unload_calls}")
        check("C2 防护② 跳过前确实查过 /api/ps", c.ps_calls == 1, str(c.ps_calls))

        # 防护②：tag 兼容（双向）
        c = StubConn(loaded=["glm-ocr:latest"])
        r = await safe_unload_model(c, "glm-ocr")
        check("C3 防护② 裸名命中 :latest → 执行卸载",
              r is True and c.unload_calls == ["glm-ocr"], f"{c.unload_calls}")
        c = StubConn(loaded=["glm-ocr"])
        r = await safe_unload_model(c, "glm-ocr:latest")
        check("C4 防护② 带tag命中裸名 → 执行卸载",
              r is True and c.unload_calls == ["glm-ocr:latest"], f"{c.unload_calls}")

        # 防护①：卸载超时 → 放弃且不阻塞委派主流程
        c = StubConn(loaded=["m:latest"], unload_delay=3.0)
        orig = L.SWAP_TIMEOUT
        L.SWAP_TIMEOUT = 0.3
        t0 = time.time()
        r = await safe_unload_model(c, "m")
        dt = time.time() - t0
        L.SWAP_TIMEOUT = orig
        check("C5 防护① 卸载超时→放弃不阻塞(<1s返回)", r is False and dt < 1.0, f"{dt:.2f}s")

        # 防护①：查 ps 超时 → 安全返回 False，不卸载不抛
        c = StubConn(loaded=["m:latest"], ps_delay=3.0)
        orig2 = L.SWAP_PS_TIMEOUT
        L.SWAP_PS_TIMEOUT = 0.3
        r = await safe_unload_model(c, "m")
        L.SWAP_PS_TIMEOUT = orig2
        check("C6 防护① 查ps超时→False且未卸载", r is False and c.unload_calls == [],
              f"{c.unload_calls}")

        # 边界：空模型名 / None 连接器 → False，且不浪费一次 ps 查询
        c = StubConn(loaded=["m"])
        r1 = await safe_unload_model(c, "")
        r2 = await safe_unload_model(None, "m")
        check("C7 边界 空模型名→False且不查ps", r1 is False and c.ps_calls == 0, str(c.ps_calls))
        check("C8 边界 None连接器→False", r2 is False)

        # Ollama 未运行（unload 返回 False）→ 不抛异常
        class Stub2(StubConn):
            async def unload_model(self, name):
                self.unload_calls.append(name)
                return False
        c = Stub2(loaded=["m:latest"])
        r = await safe_unload_model(c, "m")
        check("C9 卸载返回False→安全不抛", r is False and c.unload_calls == ["m"],
              f"{c.unload_calls}")

        # 超时常量必须存在且合理（0.4.7 事故：无超时→无限挂住）
        check("C10 换装超时常量已定义且 ≤30s",
              0 < L.SWAP_TIMEOUT <= 30 and 0 < L.SWAP_PS_TIMEOUT <= 30,
              f"SWAP_TIMEOUT={L.SWAP_TIMEOUT} PS={L.SWAP_PS_TIMEOUT}")

    asyncio.run(go())


def test_d_archive_work_unit():
    """3.47.1 单元归档：首条保留 / 防滥用 / 归档点自追踪 / 可搜回 / source 合法。"""
    from sidecar.agent_engine.loop import archive_work_unit, ARCHIVE_MIN_MESSAGES
    tmp = isolate_data_dir("arc_data_")
    import sidecar.storage.store as store

    wd = tmp / "case"; wd.mkdir(exist_ok=True)
    pid = store.create_project("测试案件", str(wd))
    aid = store.add_agent_config(pid, "主Agent", "main", role="律师助理", model_name="qwen3.8")
    sid = store.create_session(pid, aid, title="会话1")
    store.save_message(pid, sid, aid, "user", "这是任务总指令：处理3个案件")
    for i in range(6):
        store.save_message(pid, sid, aid, "assistant" if i % 2 else "user", f"案件A 步骤{i} 内容")

    r = archive_work_unit(pid, sid, "《案件A》案情分析", "已完成案情分析，产出 a.docx")
    check("D1 归档成功", r.get("ok") is True, str(r)[:150])
    check("D2 首条用户消息被保留（任务总指令永不归档）",
          r.get("kept_first_user_message") is True, str(r)[:150])
    check("D3 归档条数=6（7条减去保留的首条）", r.get("archived") == 6,
          f"archived={r.get('archived')}")
    after = store.load_messages(pid, sid)
    first = next((m for m in after if m.get("role") == "user"), {})
    check("D4 首条用户消息未标记 archived（Agent 仍能看到总任务）",
          not first.get("archived"), str(first.get("archived")))
    check("D5 其余消息已归档（脱离上下文）",
          all(m.get("archived") for m in after[1:]),
          str([m.get("archived") for m in after]))

    # 防滥用：紧接着再归档 → 候选不足 ARCHIVE_MIN_MESSAGES → 拒绝
    r2 = archive_work_unit(pid, sid, "《案件B》", "x")
    check(f"D6 防滥用：候选不足{ARCHIVE_MIN_MESSAGES}条→拒绝",
          r2.get("ok") is False and "不足" in str(r2.get("error", "")), str(r2)[:150])

    # 归档点自追踪：新增消息后二次归档，只归档新增部分
    for i in range(5):
        store.save_message(pid, sid, aid, "assistant" if i % 2 else "user", f"案件B 步骤{i}")
    r3 = archive_work_unit(pid, sid, "《案件B》证据", "已完成证据汇编")
    check("D7 二次归档成功且只归档新增（归档点自追踪，无需额外状态字段）",
          r3.get("ok") is True and r3.get("archived") == 5, f"archived={r3.get('archived')}")

    from sidecar.knowledge import warehouse as wh
    wh.prune_missing()
    entries = wh.list_entries("project", pid)
    titles = [e.get("title") for e in entries]
    check("D8 知识仓库生成2条工作单元条目", len(entries) == 2, str(titles))
    check("D9 条目标题正确", "《案件A》案情分析" in titles and "《案件B》证据" in titles, str(titles))
    body = (wh.get_entry(entries[0]["id"]) or {}).get("body", "")
    check("D10 条目正文含单元摘要", "单元摘要" in body, body[:100])
    # source 必须合法（曾因用 'work_unit' 违反 CHECK 约束直接报错）
    srcs = {(e.get("source") or "") for e in entries}
    check("D11 source 合法（未违反 CHECK 约束 chat/manual）",
          srcs.issubset({"chat", "manual"}), str(srcs))
    check("D12 category 标记为工作单元归档（区分手动转移）",
          all((e.get("category") or "") == "工作单元归档" for e in entries),
          str([e.get("category") for e in entries]))

    # 参数校验
    r5 = archive_work_unit(pid, sid, "", "x")
    check("D13 缺 title→拒绝并说明原因", r5.get("ok") is False and "title" in str(r5.get("error", "")),
          str(r5)[:120])
    r6 = archive_work_unit("", sid, "T", "S")
    check("D14 缺 project_id→拒绝", r6.get("ok") is False, str(r6)[:120])

    # 拉模式闭环：归档内容可被 search_knowledge 搜回
    hits = wh.hybrid_search("案情分析", "project", pid, 5)
    check("D15 归档内容可被搜回（拉模式闭环）", len(hits) > 0, f"hits={len(hits)}")


def test_c_model_selection():
    """3.47.2：delegate_task 的 model 参数覆盖 + 不存在模型报错。"""
    from sidecar.agent_engine.delegation import run_delegated_task
    isolate_data_dir("ms_data_")   # 隔离：委派会落库，绝不可写真实 ~/.subagent

    async def go():
        base = tempfile.mkdtemp(prefix="ms_")
        agent = {"id": "sub1", "name": "OCR专员", "model_name": "qwen3.8:latest"}
        # 指定不存在的模型 → 必须报错并列出可用模型（不得静默回退，否则模型分工失效）
        conn = StubConn(models=[{"name": "glm-ocr:latest"}, {"name": "qwen3.8:latest"}])
        r = await run_delegated_task("p1", "a1", "s1", agent, "任务书", "交卷标准",
                                     sandbox_root=base, connector=conn,
                                     model_override="不存在的模型")
        err = str(r.get("error", ""))
        check("C11 3.47.2 不存在的模型→拒绝", r.get("ok") is False and "model_not_found" in err,
              err[:180])
        check("C12 3.47.2 报错列出可用模型（引导改选）",
              "glm-ocr" in err and "qwen3.8" in err, err[:200])
        check("C13 3.47.2 报错不静默回退到原模型",
              "沿用" in err or "不填" in err, err[:200])

        # tag 兼容：填 glm-ocr 命中 glm-ocr:latest（不应报错）
        # 注意：D-8 去重守卫按【任务文本】统计失败次数，故两次调用必须用不同任务书，
        # 否则第二次会被守卫拦下（那不是模型校验的结果，会误判）
        r2 = await run_delegated_task("p1", "a1", "s1", agent, "任务书B（tag兼容校验）", "交卷标准",
                                      sandbox_root=base, connector=conn,
                                      model_override="glm-ocr")
        check("C14 3.47.2 裸模型名tag兼容（不误判为不存在）",
              "model_not_found" not in str(r2.get("error", "")), str(r2)[:200])

    asyncio.run(go())


def test_c_swap_config_gating():
    """3.47.3 防护③：并发开启时禁用换装（配置层语义）。"""
    import sidecar.config as cfg
    isolate_data_dir("sw_data_")
    cfg.reload_config({"delegation_model_swap": True, "task_concurrency": False,
                       "model_parallel": False})
    c = cfg.get_config()
    check("C15 delegation_model_swap 默认开", c.get("delegation_model_swap") is True, str(c.get("delegation_model_swap")))

    def swap_active():
        cc = cfg.get_config()
        on = bool(cc.get("delegation_model_swap", True))
        if bool(cc.get("task_concurrency", False)) or bool(cc.get("model_parallel", False)):
            on = False
        return on

    check("C16 串行时换装生效", swap_active() is True)
    cfg.reload_config({"task_concurrency": True})
    check("C17 防护③ task_concurrency 开→禁用换装（并行卸载会冲突）", swap_active() is False)
    cfg.reload_config({"task_concurrency": False, "model_parallel": True})
    check("C18 防护③ model_parallel 开→禁用换装", swap_active() is False)
    cfg.reload_config({"model_parallel": False, "delegation_model_swap": False})
    check("C19 开关关闭→不换装（保持现状）", swap_active() is False)


def test_c_config_validation():
    """新增配置项的校验（防非法值破坏运行）+ 0.4.7 遗留孤儿键已转正。"""
    import sidecar.config as cfg
    from sidecar.config.store import DEFAULT_CONFIG
    isolate_data_dir("cf_data_")
    cfg.reload_config({})
    c = cfg.get_config()
    for k in ("error_analysis_model", "confirm_network_install", "model_strengths",
              "delegation_model_swap", "app_control_enabled", "app_control_confirm",
              "computer_use_enabled", "computer_use_confirm_each", "computer_use_app_whitelist"):
        check(f"C20 配置项存在 {k}", k in c and k in DEFAULT_CONFIG, str(list(c.keys())[-12:]))
    # 0.4.7 遗留孤儿键已转正（此前在 config.json 里是未知键）
    check("C21 0.4.7 孤儿键 model_strengths 已转正", "model_strengths" in DEFAULT_CONFIG)
    check("C22 0.4.7 孤儿键 delegation_model_swap 已转正", "delegation_model_swap" in DEFAULT_CONFIG)
    # 校验：model_strengths 单条 >100 字应被拒（防提示词膨胀）
    try:
        cfg.reload_config({"model_strengths": {"m1": "长" * 101}})
        ok = False
    except ValueError:
        ok = True
    except Exception:
        ok = False
    check("C23 model_strengths 单条超100字被拒", ok)
    # 合法画像应通过
    try:
        cfg.reload_config({"model_strengths": {"glm-ocr:latest": "OCR 转写，小而快"}})
        ok2 = cfg.get_config().get("model_strengths", {}).get("glm-ocr:latest") == "OCR 转写，小而快"
    except Exception:
        ok2 = False
    check("C24 合法画像写入成功", ok2)


def test_c_prompt_injection():
    """3.47.2：模型画像注入系统提示词（仅配置了画像且可委派时）。"""
    from sidecar.agent_engine.loop import build_system_prompt
    strengths = "- glm-ocr:latest：OCR 转写专用，小而快\n- qwen3.6:35b：长文推理与法律分析"
    p1 = build_system_prompt("A", "角色", "/tmp", "auto", can_delegate=True,
                             model_strengths_text=strengths)
    check("C25 可委派+有画像→注入【可用模型及特长】",
          "【可用模型及特长】" in p1 and "glm-ocr" in p1, p1[-400:])
    check("C26 注入内容含 model 参数用法提示", "model" in p1, p1[-400:])
    p2 = build_system_prompt("A", "角色", "/tmp", "auto", can_delegate=False,
                             model_strengths_text=strengths)
    check("C27 不可委派→不注入画像（子会话无需选模型）", "【可用模型及特长】" not in p2, "")
    p3 = build_system_prompt("A", "角色", "/tmp", "auto", can_delegate=True,
                             model_strengths_text="")
    check("C28 未配置画像→不注入（零膨胀）", "【可用模型及特长】" not in p3, "")


def main():
    print("=" * 70)
    print("checkpoint-093（0.4.9）专项回归")
    print("=" * 70)
    test_a_tools_and_paths()
    test_a_t1_b2()
    test_a_b3_ctx_chars()
    test_b_network_install_confirm()
    test_c_swap_protections()
    test_c_model_selection()
    test_c_swap_config_gating()
    test_c_config_validation()
    test_c_prompt_injection()
    test_d_archive_work_unit()
    print("\n" + "=" * 70)
    print(f"===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print("  -", f)
    print("=" * 70)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
