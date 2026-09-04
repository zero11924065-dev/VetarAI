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
"""TS-110 M4 注入集成单测：build_system_prompt 四段注入 + read_skill 工具路由。
venv 内 python test_knowledge_inject.py 直接跑。只输出 PASS/FAIL 摘要。
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
    """按序返回脚本：每轮 (content, tool_calls)。"""

    def __init__(self, rounds):
        self.rounds = rounds
        self.calls = 0

    async def chat_stream(self, model, messages, tools=None):
        i = min(self.calls, len(self.rounds) - 1)
        self.calls += 1
        content, tcs = self.rounds[i]
        if content:
            yield {"content_delta": content}
        if tcs:
            yield {"tool_calls": [{"id": f"mock_{self.calls}", "function": {
                "name": n, "arguments": json.dumps(a, ensure_ascii=False)}}
                for n, a in tcs]}
        yield {"done": True, "counts": {"prompt_eval_count": 5, "eval_count": 5}}


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="m4inj_"))
    import sidecar.config as cfgmod
    cfgmod.data_root = lambda: TMP / "dataroot"
    from sidecar.agent_engine.loop import build_system_prompt, tools_spec, run_tool_loop
    from sidecar.skills_mgr import manager as sm

    # ══ 12. build_system_prompt 四段注入 ══
    sp = build_system_prompt(
        "助手", "工程师", "/data/ws", "auto",
        knowledge_text="【规范.md】\n必须用中文回复",
        memory_text="【本项目记忆】\n用户叫小明",
        prohibitions=["禁止讨论薪资话题。", "严禁泄露密钥。"],
        skills_list_text="- 周报助手：按模板生成周报",
    )
    head = sp.split("\n你是")[0]
    check("12a 禁止事项并入首段【禁止事项】",
          "【禁止事项】" in head and "禁止讨论薪资话题。" in head and "严禁泄露密钥。" in head, head[:200])
    check("12b 记忆段注入", "【长期记忆】" in sp and "用户叫小明" in sp)
    check("12c 知识库段注入（含优先级说明）",
          "【项目知识库】" in sp and "必须用中文回复" in sp and "以记忆为准" in sp)
    check("12d 技能清单注入（含 read_skill 指引）",
          "【可用技能】" in sp and "周报助手" in sp and "read_skill" in sp)
    check("12e 段落顺序：记忆先于知识库",
          sp.index("【长期记忆】") < sp.index("【项目知识库】"))
    sp_empty = build_system_prompt("助手", None, "/ws", "auto")
    check("12f 无注入时不出现四个段落",
          "【长期记忆】" not in sp_empty and "【项目知识库】" not in sp_empty
          and "【可用技能】" not in sp_empty and "用户设定的禁止事项" not in sp_empty)

    # ══ 13. tools_spec 两态均含 read_skill ══
    names_t = [s["function"]["name"] for s in tools_spec(with_delegation=True)]
    names_f = [s["function"]["name"] for s in tools_spec(with_delegation=False)]
    check("13a 主会话 spec 含 read_skill", "read_skill" in names_t, str(names_t))
    check("13b 子会话 spec 也含 read_skill（技能全局可用）", "read_skill" in names_f, str(names_f))

    # ══ 14. loop 路由：read_skill 工具执行 ══
    sm.create_or_update_skill("测试技能", "描述X", "技能正文ABC", True)
    sm.create_or_update_skill("禁用技能", "描述Y", "正文Y", False)

    async def collect(tool_args):
        evs = []
        async for ev in run_tool_loop(
                "m", [{"role": "user", "content": "hi"}], tools_spec(with_delegation=True),
                str(TMP), connector=MockConn([
                    ("", [("read_skill", tool_args)]),
                    ("完成", [])])):
            evs.append(ev)
        return evs

    # 14a 存在技能 → ok + 摘要显示描述（正文随结果回注模型）
    evs = await collect({"name": "测试技能"})
    tr = next((e for e in evs if e["event"] == "tool_result" and e["data"]["name"] == "read_skill"), None)
    check("14a read_skill 存在 → ok + 摘要含技能名与描述",
          tr is not None and tr["data"]["ok"] is True
          and "测试技能" in tr["data"].get("summary", "") and "描述X" in tr["data"].get("summary", ""),
          str(tr)[:200] if tr else "无结果")
    # 14b 不存在 → ok=False + 可用名单
    evs = await collect({"name": "幽灵技能"})
    tr = next((e for e in evs if e["event"] == "tool_result" and e["data"]["name"] == "read_skill"), None)
    check("14b 不存在技能 → 错误 + 可用名单",
          tr is not None and tr["data"]["ok"] is False
          and "不存在" in tr["data"].get("error", "") and "测试技能" in tr["data"].get("error", ""),
          str(tr)[:200] if tr else "无结果")
    # 14c 禁用技能 → 提示启用
    evs = await collect({"name": "禁用技能"})
    tr = next((e for e in evs if e["event"] == "tool_result" and e["data"]["name"] == "read_skill"), None)
    check("14c 禁用技能 → 提示已禁用",
          tr is not None and tr["data"]["ok"] is False and "禁用" in tr["data"].get("error", ""),
          str(tr)[:200] if tr else "无结果")
    # 14d 工具结果进 done（模型第二轮能收到）
    done = next((e for e in evs if e["event"] == "done"), None)
    check("14d read_skill 后正常走到 done", done is not None)

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M4 注入集成专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
