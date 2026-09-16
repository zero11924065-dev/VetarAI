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
"""REQ-AGT-019（0.4.28）零图片+图片意图委派守卫 专项测试（mock connector，直接跑）。

根因（0.4.27 实测）：技能不提 image_paths → 主模型不传 → F1 拦截（只在"传了参但
一张没加载到"时触发）与 delegation.py 视觉守卫（只在"有图"时查模型能力）都以
"传了图"为前提 → 零图片静默委派成功，子 Agent 只能说"不支持OCR"或编造。

修法 = 守卫层 + 提示层：
  ① 合并图片（聊天附着图 + image_paths 加载图）之后、发起委派之前——
     零图片且任务书含图片意图关键词 → 拦截，回传两条图通道指引（对齐 F1 风格）；
  ② 系统提示词委派纪律补【分批委派图片】规则（每批 image_paths 传该批绝对路径子集）。

覆盖（对齐任务书 ①~⑤）：
  1  任务书含"图片"且零图片零附着 → 拦截，回传两通道指引 + 真实图片清单，委派未发起
  2  传了 image_paths（真实加载成功）→ 放行，图片随委派传给子 Agent
  3  有聊天附着图 → 放行（附着图场景不拦）
  4  非图片任务零图片（"总结这段文字"）→ 放行，守卫不误伤
  5  关键词边界（含"识别"但不含图片词）→ 放行（裸"识别"刻意不在关键词集合）
  6  提示层：委派纪律含分批委派图片规则；_IMAGE_INTENT_RE 大小写不敏感

只输出 PASS/FAIL 摘要。退出码 0=全过，1=有失败。
"""
import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PASS, FAIL = 0, 0
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


class MockConn:
    """按序返回预置脚本的假 connector（与 test_loop.py 同款）。
    每轮脚本 = (content_chunks, tool_calls) 列表。
    ⛔ 必须收 **_kwargs：loop 在有附着图时会给 chat_stream 传 images=...
       （run_tool_loop 的 _stream_kwargs），不收会直接 TypeError。"""

    def __init__(self, rounds):
        self.rounds = rounds
        self.calls = 0
        self.seen = []          # 每轮送入模型的 messages 快照（供断言 tool_report 回注内容）

    async def chat_stream(self, model, messages, tools=None, **_kwargs):
        i = min(self.calls, len(self.rounds) - 1)
        self.calls += 1
        self.seen.append([dict(m) for m in messages])
        content, tcs = self.rounds[i]
        for ch in content:
            yield {"content_delta": ch}
        if tcs:
            yield {"tool_calls": [{"id": f"mock_{self.calls}",
                                   "function": {"name": n, "arguments": json.dumps(a)}}
                                  for n, a in tcs]}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 5}}


# 占位 PNG 字节：_load_delegation_images 按【扩展名】选 mime 并做 base64，不校验 PNG 结构
# （与 test_checkpoint093 的 _MIN_JPEG 同一纪律，避免依赖 PIL）。
_MIN_PNG = b"\x89PNG\r\n\x1a\n" + b"placeholder-png-bytes-for-agt019"


async def main():
    # 隔离数据目录（不碰 ~/.subagent，与 test_delegation.py 同一做法）
    TMP = Path(tempfile.mkdtemp(prefix="agt019_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"

    import sidecar.agent_engine.delegation as deleg_mod
    from sidecar.agent_engine.loop import (
        run_tool_loop, tools_spec, build_system_prompt, _IMAGE_INTENT_RE)

    sandbox = TMP / "ws"
    sandbox.mkdir()
    # 工作目录下放 3 张真图（子目录"票据"）——供 image_paths 加载与 F1 真实清单 hint
    (sandbox / "票据").mkdir()
    for i in (1, 2, 3):
        (sandbox / "票据" / f"{i}.png").write_bytes(_MIN_PNG)

    pid = store.create_project("agt019", TMP / "wd")
    main_id = store.add_agent_config(pid, "Main", "main", model_name="m")
    store.add_agent_config(pid, "OCR专员", "sub", model_name="m")

    # 打桩 run_delegated_task：记录调用 + 直接交卷，避免真跑子会话 loop。
    # loop.py 是在委派分支内【调用时】from delegation import run_delegated_task，
    # 故 patch 模块属性即可生效。
    calls = []

    async def stub_delegate(project_id, parent_agent_id, parent_session_id,
                            target_agent, task, expect, **kwargs):
        calls.append({"task": task, "expect": expect,
                      "target": target_agent.get("name"), "kwargs": kwargs})
        return {"ok": True, "task_id": "t-stub", "status": "success",
                "summary": "stub 交卷", "artifacts": []}

    orig_delegate = deleg_mod.run_delegated_task
    deleg_mod.run_delegated_task = stub_delegate

    async def drive(task, expect="按要求产出", image_paths=None, attach=None):
        """驱动一轮真实 run_tool_loop：模型首轮发 delegate_task，次轮收尾。"""
        args = {"target": "OCR专员", "task": task, "expect": expect}
        if image_paths is not None:
            args["image_paths"] = image_paths
        conn = MockConn([([], [("delegate_task", args)]), (["收尾"], None)])
        dctx = {"project_id": pid, "agent_id": main_id, "session_id": "sess-1",
                "connector": conn}
        evs = []
        async for ev in run_tool_loop(
                "m", [{"role": "user", "content": "hi"}],
                tools_spec(with_delegation=True), str(sandbox),
                max_rounds=4, connector=conn,
                delegation_ctx=dctx, first_round_images=attach):
            evs.append(ev)
        tr = next((e for e in evs if e["event"] == "tool_result"), None)
        return evs, (tr or {"data": {}})["data"], conn

    try:
        # ── ① 任务书含"图片" + 零图片零附着 → 拦截，委派未发起，回传两通道指引 ──
        n0 = len(calls)
        evs, tr, _c1 = await drive("把本批图片逐张转写为文字", expect="每张图的文字内容")
        err = str(tr.get("error", ""))
        check("1a 零图片+图片意图 → tool_result ok=False", tr.get("ok") is False, str(tr)[:200])
        check("1b 错误码 images_missing", "images_missing" in err, err[:160])
        check("1c ⛔ 委派未真正发起（run_delegated_task 未被调用）",
              len(calls) == n0, f"calls={len(calls)}")
        check("1d 指引含通道② image_paths + list_dir 盘点",
              "image_paths" in err and "list_dir" in err, err[:240])
        check("1e 指引含通道① 聊天附着图全量自动携带",
              "附着" in err and "自动携带" in err, err[:240])
        check("1f 回传 F1 风格真实图片清单（含子目录内 1.png）",
              "1.png" in err and "共" in err, err[-200:])

        # ── ② 传了 image_paths（真实加载成功）→ 放行，图片随委派传给子 Agent ──
        n0 = len(calls)
        evs, tr, conn2 = await drive("把本批图片逐张转写为文字", expect="每张图的文字内容",
                                     image_paths=["票据/1.png", "票据/2.png"])
        check("2a 传 image_paths → 放行（ok=True）", tr.get("ok") is True, str(tr)[:200])
        check("2b ⛔ 委派真正发起（stub 被调用 1 次）",
              len(calls) == n0 + 1, f"calls={len(calls)}")
        _imgs = calls[-1]["kwargs"].get("images") if calls else None
        check("2c 加载的 2 张图经 images 传给子 Agent",
              isinstance(_imgs, list) and len(_imgs) == 2, str(type(_imgs)))
        # images_loaded 不在 tool_result 事件（事件只带摘要），而是随完整 result
        # 以 tool_report 消息回注模型——断言第 2 轮送入模型的消息里能看到它。
        check("2d 结果如实报告 images_loaded=2（tool_report 回注模型）",
              len(conn2.seen) >= 2 and '"images_loaded": 2' in str(conn2.seen[1]),
              str(conn2.seen[1])[-300:] if len(conn2.seen) >= 2 else "round2 missing")

        # ── ③ 有聊天附着图 → 放行（附着图场景不拦；附着图全量自动携带）──
        n0 = len(calls)
        attach = ["data:image/png;base64,QUFB"]  # 附着图是 data URI，内容由附件通道保证
        evs, tr, _c3 = await drive("将附图逐张转写为文字", expect="转写结果", attach=attach)
        check("3a 附着图场景 → 放行（ok=True）", tr.get("ok") is True, str(tr)[:200])
        check("3b ⛔ 委派真正发起", len(calls) == n0 + 1, f"calls={len(calls)}")
        _imgs3 = calls[-1]["kwargs"].get("images") if calls else None
        check("3c 附着图经 images 传给子 Agent（全量自动携带）",
              isinstance(_imgs3, list) and _imgs3 == attach, str(_imgs3)[:120])

        # ── ④ 非图片任务零图片 → 放行，守卫不误伤 ──
        n0 = len(calls)
        evs, tr, _c4 = await drive("总结这段文字的核心观点", expect="三段式摘要")
        check("4a 非图片任务零图片 → 放行（ok=True）", tr.get("ok") is True, str(tr)[:200])
        check("4b ⛔ 委派真正发起", len(calls) == n0 + 1, f"calls={len(calls)}")
        check("4c 无图任务的 images=None（不凭空塞图）",
              calls[-1]["kwargs"].get("images") is None, str(calls[-1]["kwargs"].get("images")))

        # ── ⑤ 关键词边界：含裸"识别"但不含图片词 → 放行 ──
        # （"识别"刻意不在关键词集合——纯文本识别任务太常见，误伤面太大）
        n0 = len(calls)
        evs, tr, _c5 = await drive("识别这段文字的语种并给出置信度", expect="语种+置信度")
        check("5a 含裸「识别」非图片任务 → 放行（ok=True）", tr.get("ok") is True, str(tr)[:200])
        check("5b ⛔ 委派真正发起", len(calls) == n0 + 1, f"calls={len(calls)}")

        # ── ⑥ 提示层：委派纪律含分批委派图片规则 + 关键词表大小写不敏感 ──
        sp = build_system_prompt("小助手", "工程师", "/data/ws", "auto", can_delegate=True)
        check("6a 委派纪律含【分批委派图片】规则", "【分批委派图片" in sp, sp[-500:])
        check("6b 规则要求每批经 image_paths 传该批绝对路径子集",
              "image_paths" in sp and "绝对路径子集" in sp, sp[-500:])
        check("6c 规则讲明附着图无法按批拆分（分批一律 image_paths）",
              "无法按批拆分" in sp, sp[-500:])
        check("6d 关键词表大小写不敏感（小写 ocr 命中）",
              _IMAGE_INTENT_RE.search("帮我做 ocr 转写") is not None, "")
        check("6e 关键词表覆盖 截图/扫描件/图中",
              all(_IMAGE_INTENT_RE.search(t) for t in ("看这张截图", "扫描件转文字", "图中的人")),
              "")
        check("6f ⛔ 裸「识别」不在关键词表（守护 ⑤ 的前提）",
              _IMAGE_INTENT_RE.search("识别这段文字的语种") is None, "")
    finally:
        deleg_mod.run_delegated_task = orig_delegate

    print(f"\n===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
    if FAIL:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
