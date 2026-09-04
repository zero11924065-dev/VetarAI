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
"""TS-109 M3-3 圆桌讨论执行模块单测（mock connector，venv 内直接跑）。
覆盖：创建校验 / 用户主持轮次 / 发言失败跳过 / AI 主持自动续轮与共识 /
达上限交用户 / 纪要更新失败保留旧纪要 / 总结兜底 / 共识宽松判定。
只输出 PASS/FAIL 摘要。
"""
import asyncio
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


class ScriptConn:
    """按调用序返回脚本的假 connector（圆桌全部调用走 chat 非流式）。
    脚本项：str 或 callable(call_index, messages)->str；'__RAISE__' 抛错。"""

    def __init__(self, scripts):
        self.scripts = scripts
        self.calls = 0
        self.calls_log: list = []  # 记录每次调用的 messages（供断言提示词内容）

    async def chat(self, model, messages, **kw):
        i = min(self.calls, len(self.scripts) - 1)
        item = self.scripts[i]
        self.calls += 1
        self.calls_log.append({"model": model, "messages": messages})
        if item == "__RAISE__":
            raise RuntimeError("模型调用失败(模拟)")
        if callable(item):
            return item(self.calls, messages)
        return item


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="m33rt_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar.agent_engine import roundtable as rt

    pid = store.create_project("rt-proj", TMP / "wd")
    a1 = store.add_agent_config(pid, "产品", "main", model_name="qwen3.8", role="产品经理")
    a2 = store.add_agent_config(pid, "技术", "main", model_name="qwen3.8", role="技术负责人")
    a3 = store.add_agent_config(pid, "法务", "sub", model_name="qwen3.8", role="法务")

    # ══ 1. create 校验 ══
    for label, kwargs in [
        ("1a topic 空", dict(topic="  ", agent_ids=[a1, a2])),
        ("1b 参与者<2", dict(topic="t", agent_ids=[a1])),
        ("1c 参与者不存在", dict(topic="t", agent_ids=[a1, "ghost"])),
    ]:
        try:
            await rt.create_and_start(pid, kwargs["topic"], kwargs["agent_ids"],
                                      connector=ScriptConn(["x"]))
            check(label + " 报错", False, "未抛错")
        except ValueError as e:
            check(label + " 报错", True, str(e))
    try:
        await rt.create_and_start(pid, "t", [a1, a2], moderator="ai",
                                  moderator_agent_id="ghost", connector=ScriptConn(["x"]))
        check("1d AI 主持不在参与者中 报错", False)
    except ValueError:
        check("1d AI 主持不在参与者中 报错", True)

    # ══ 2. 用户主持：一轮发言 + 纪要更新 + waiting_user ══
    conn2 = ScriptConn(["产品观点：应当做", "技术观点：成本高", "【共识】都想做好产品"])
    rt2 = await rt.create_and_start(pid, "要不要做 X 功能", [a1, a2], connector=conn2)
    check("2a 用户主持一轮后 waiting_user", rt2["status"] == "waiting_user", str(rt2)[:200])
    check("2b round=1", rt2["round"] == 1)
    check("2c 纪要已更新", rt2["minutes"] == "【共识】都想做好产品", str(rt2.get("minutes"))[:100])
    msgs2 = store.list_roundtable_messages(pid, rt2["id"])
    check("2d 两参与者各发言 1 条落库",
          len(msgs2) == 2 and {m["agent_name"] for m in msgs2} == {"产品", "技术"}
          and all(m["ok"] for m in msgs2), str(msgs2)[:200])

    # ══ 3. 发言失败跳过继续 ══
    conn3 = ScriptConn(["产品观点 ok", "__RAISE__", "纪要v2"])
    rt3 = await rt.create_and_start(pid, "议题 3", [a1, a2], connector=conn3)
    msgs3 = store.list_roundtable_messages(pid, rt3["id"])
    check("3a 发言失败记 ok=0 且整场继续",
          len(msgs3) == 2 and msgs3[0]["ok"] is True and msgs3[1]["ok"] is False
          and msgs3[1]["content"] == "（本轮发言失败）", str(msgs3)[:200])
    check("3b 状态仍 waiting_user", rt3["status"] == "waiting_user")

    # ══ 4. AI 主持：否→自动续轮→是→confirm_end ══
    # 调用序：轮1 发言x2 纪要x1 判定(否) 轮2 发言x2 纪要x1 判定(是)
    scripts4 = ["A1观点", "A2观点", "纪要r1", "达成共识：否，尚有分歧",
                "A1观点2", "A2观点2", "纪要r2", "达成共识：是，各方一致"]
    conn4 = ScriptConn(scripts4)
    rt4 = await rt.create_and_start(pid, "议题 4", [a1, a2], moderator="ai",
                                    moderator_agent_id=a1, connector=conn4)
    check("4a AI 主持未共识自动续轮 → 共识后 confirm_end",
          rt4["status"] == "confirm_end" and rt4["round"] == 2, str(rt4)[:200])
    msgs4 = store.list_roundtable_messages(pid, rt4["id"])
    check("4b 两轮共 4 条发言", len(msgs4) == 4, str(len(msgs4)))

    # ══ 5. AI 主持达 max_rounds 未共识 → waiting_user ══
    # max_rounds=2：轮1 否 + 轮2 否 → waiting_user
    scripts5 = ["v1", "v2", "纪要1", "达成共识：否",
                "v3", "v4", "纪要2", "达成共识：否"]
    conn5 = ScriptConn(scripts5)
    rt5 = await rt.create_and_start(pid, "议题 5", [a1, a2], moderator="ai",
                                    moderator_agent_id=a1, max_rounds=2, connector=conn5)
    check("5 达上限未共识 → waiting_user（交用户决定）",
          rt5["status"] == "waiting_user" and rt5["round"] == 2, str(rt5)[:200])

    # ══ 6. finish：总结成功 → done ══
    conn6 = ScriptConn(["【共识】都好【分歧】无【结论】做【建议】尽快"])
    rt6 = await rt.finish_roundtable(pid, rt2["id"], connector=conn6)
    check("6a finish 后 done + summary 落库",
          rt6["status"] == "done" and rt6["summary"].startswith("【共识】"), str(rt6)[:150])

    # ══ 6b. finish：总结失败 → 纪要兜底仍 done ══
    conn6b = ScriptConn(["__RAISE__"])
    rt3b = await rt.finish_roundtable(pid, rt3["id"], connector=conn6b)
    check("6b 总结失败 → 纪要兜底仍 done",
          rt3b["status"] == "done" and rt3b["summary"].startswith("（总结生成失败"),
          str(rt3b)[:150])

    # ══ 7. 纪要更新失败 → 保留旧纪要 ══
    conn7 = ScriptConn(["观点一", "观点二", "__RAISE__"])  # 纪要调用抛错
    rt7 = await rt.create_and_start(pid, "议题 7", [a1, a2], connector=conn7)
    check("7 纪要更新失败保留旧纪要（含【议题】初始结构）",
          rt7["minutes"] and "【议题】议题 7" in rt7["minutes"], str(rt7.get("minutes"))[:100])

    # ══ 8. 共识宽松判定 ══
    # 8a 首行含"是" → 共识
    rt8a, _ = await rt._judge_consensus(ScriptConn(["达成共识：是\n理由"]), {"name": "主持"}, "t", "m")
    check("8a 首行'达成共识：是' → 共识", rt8a is True)
    # 8b 首行含"否" → 不共识
    rt8b, _ = await rt._judge_consensus(ScriptConn(["达成共识：否"]), {"name": "主持"}, "t", "m")
    check("8b 首行'达成共识：否' → 不共识", rt8b is False)
    # 8c 乱答 → 按未共识
    rt8c, _ = await rt._judge_consensus(ScriptConn(["这个嘛，很难说"]), {"name": "主持"}, "t", "m")
    check("8c 乱答 → 按未共识", rt8c is False)
    # 8d 调用异常 → 按未共识
    rt8d, _ = await rt._judge_consensus(ScriptConn(["__RAISE__"]), {"name": "主持"}, "t", "m")
    check("8d 判定调用异常 → 按未共识", rt8d is False)

    # ══ 9. TS-109 增强：附件注入发言提示词（每轮独立注入，不依赖纪要保留）══
    conn9 = ScriptConn(["P发言", "T发言", "纪要v"])
    rt9 = await rt.create_and_start(pid, "带材料的议题", [a1, a2], connector=conn9,
                                    attachments=[{"name": "材料.txt", "text": "材料正文ABC", "truncated": False}])
    # 两次发言调用的 user 提示词都应含材料正文（纪要被重写也不丢失）
    speech_prompts = [c["messages"][-1]["content"] for c in conn9.calls_log[:2]]
    check("9a 每轮发言提示词均注入材料正文",
          all("材料正文ABC" in p for p in speech_prompts), str(speech_prompts)[:200])
    check("9b attachments 元数据落库",
          len(rt9.get("attachments") or []) == 1 and rt9["attachments"][0]["name"] == "材料.txt",
          str(rt9.get("attachments"))[:150])

    # ══ 10. TS-109 增强：导出 Markdown ══
    from pathlib import Path as _P
    out = rt.export_roundtable_md(pid, rt9["id"])
    check("10a 导出返回路径且文件存在",
          out.get("path") and _P(out["path"]).exists(), str(out)[:200])
    content = _P(out["path"]).read_text(encoding="utf-8")
    check("10b 导出内容含议题/纪要/发言/附件标注",
          "带材料的议题" in content and "## 讨论纪要" in content
          and "P发言" in content and "材料.txt" in content, content[:200])
    # 10c：默认保存到项目工作目录（建项目时选的文件夹）下的 roundtables/
    wd_resolved = (TMP / "wd").resolve()
    out_path = _P(out["path"]).resolve()
    check("10c 默认保存到项目工作目录下的 roundtables/（非软件数据目录）",
          out_path.parent == wd_resolved / "roundtables", out["path"])

    # ══ 11. TS-109 增强：删除圆桌（全清）══
    from sidecar.storage.store import delete_roundtable as _del, get_roundtable as _get_rt
    msgs9_before = len(store.list_roundtable_messages(pid, rt9["id"]))
    deleted = _del(pid, rt9["id"])
    check("11a 删除返回 True", deleted is True)
    check("11b 删除后详情为 None", _get_rt(pid, rt9["id"]) is None)
    check("11c 删除后发言全清", len(store.list_roundtable_messages(pid, rt9["id"])) == 0
          and msgs9_before > 0)

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M3-3 圆桌执行模块专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
