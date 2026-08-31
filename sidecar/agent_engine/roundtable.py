"""M3-3（TS-109）：圆桌讨论执行模块。

设计依据：01-需求文档 3.13 / 3.13.1（决策 6 主持人 + 决策 7 共享讨论纪要）。
- 决策 6：主持可选用户（默认）或 AI；用户主持结束权 100% 在用户（每轮后 继续/结束）；
  AI 主持判定共识后仍需用户点"确认结束"才收尾，未共识自动续轮
- 决策 7：发言基于共享"讨论纪要"（共识/分歧/各方观点），非共享会话历史
- 弱模型兼容（H14~H17 教训）：纪要/总结/共识判定纯文本宽松判定，不依赖严格格式
- 轮次串行（_ROUND_LOCK，防并发抢 Ollama）；发言失败跳过继续不中断；不设超时
"""
from __future__ import annotations

import asyncio
import json
import uuid
from typing import Any

from sidecar.storage.store import (
    create_roundtable, get_roundtable, update_roundtable, list_agent_configs,
    add_roundtable_message, list_roundtable_messages,
)

_ROUND_LOCK = asyncio.Lock()

# checkpoint-067 N-1：圆桌手动停止——取消标志注册表。
# request_cancel(rt_id) 置标志；执行循环在检查点（每次发言前/纪要更新前/续轮前）
# 检测到标志即中止：已完成的本轮发言保留，状态置 waiting_user（用户可继续或结束）。
# N-2 联动：停止后不再调用模型，"停止大模型后又被自动激活"问题随之消解
# （根源是圆桌持锁连续调用模型，卸载模型后下一轮调用又会把它拉回内存）。
_CANCEL_FLAGS: dict[str, bool] = {}


def request_cancel(rt_id: str) -> None:
    _CANCEL_FLAGS[str(rt_id)] = True


def clear_cancel(rt_id: str) -> None:
    _CANCEL_FLAGS.pop(str(rt_id), None)


def _is_cancelled(rt_id: str) -> bool:
    return bool(_CANCEL_FLAGS.get(str(rt_id)))

INITIAL_MINUTES_TMPL = (
    "【议题】{topic}\n"
    "【共识】（尚无）\n"
    "【分歧】（尚无）\n"
    "【各方观点】（首轮待发言）"
)

SPEAK_PROMPT_TMPL = (
    "【圆桌讨论】\n"
    "议题：{topic}\n"
    "{materials}"
    "当前讨论纪要：\n"
    "{minutes}\n\n"
    "你是 {name}（角色：{role}）。请从你的角色立场出发，对议题发表本轮观点：\n"
    "1) 明确的观点或结论 2) 理由或依据。\n"
    "不要复述他人已说过的内容；同意或反对某人时请指名。发言控制在 300 字以内。"
)

MINUTES_UPDATE_PROMPT_TMPL = (
    "你是圆桌讨论的纪要员。根据议题与以下最新一轮的全部发言，更新讨论纪要。\n"
    "议题：{topic}\n\n"
    "旧纪要：\n{minutes}\n\n"
    "本轮新发言：\n{speeches}\n\n"
    "请输出更新后的完整纪要，必须且仅包含三段：\n"
    "【共识】…\n【分歧】…\n【各方观点】…\n"
    "总字数不超过 500 字；只输出纪要正文，不要其他说明。"
)

CONSENSUS_PROMPT_TMPL = (
    "你是圆桌讨论的主持人（{name}，角色：{role}）。议题：{topic}\n"
    "当前纪要：\n{minutes}\n\n"
    "请判断各方是否已就议题的核心达成共识。\n"
    "第一行必须输出：达成共识：是 或 达成共识：否（二选一）\n"
    "第二行用一句话说明理由。只输出这两行。"
)

SUMMARY_PROMPT_TMPL = (
    "你是圆桌讨论的总结人。议题：{topic}\n"
    "最终纪要：\n{minutes}\n\n"
    "各方全部发言：\n{speeches}\n\n"
    "请输出讨论总结，必须且仅包含四段：\n"
    "【共识】…\n【分歧】…\n【结论】…\n【建议】…\n"
    "总字数不超过 800 字；只输出总结正文，不要其他说明。"
)


def _build_materials_text(attachments: list[dict] | None) -> str:
    """从附件元数据重构背景材料文本（每轮发言独立注入，不依赖纪要保留——
    纪要每轮会被模型重写，材料若只存纪要里会在更新后丢失）。"""
    if not attachments:
        return ""
    parts = []
    for att in attachments:
        text = str(att.get("text") or "").strip()
        if not text:
            continue
        truncated = "（超长已截断）" if att.get("truncated") else ""
        parts.append(f"【附件：{att.get('name', '未命名')}】{truncated}\n{text}")
    if not parts:
        return ""
    return "背景材料（用户提供的参考文件，请以其为依据）：\n" + "\n\n".join(parts) + "\n\n"


def _initial_minutes(topic: str, attachments: list[dict] | None = None) -> str:
    minutes = INITIAL_MINUTES_TMPL.format(topic=topic)
    # TS-109 增强（H18-3）：议题附件的文本内容注入初始纪要，供各参与者发言时参考
    materials = _build_materials_text(attachments)
    if materials:
        minutes += "\n\n【背景材料】（用户提供的参考文件，讨论时请以其为依据）\n" + "\n\n".join(
            f"【附件：{a.get('name', '')}】{'（超长已截断）' if a.get('truncated') else ''}\n{str(a.get('text') or '').strip()}"
            for a in attachments if str(a.get('text') or '').strip())
    return minutes


async def create_and_start(project_id: str, topic: str, agent_ids: list[str],
                           moderator: str = "user", moderator_agent_id: str | None = None,
                           max_rounds: int = 5, connector: Any = None,
                           attachments: list[dict] | None = None) -> dict:
    """创建圆桌并执行第一轮。校验失败抛 ValueError（API 层转 400）。"""
    topic = str(topic or "").strip()
    if not topic:
        raise ValueError("议题不能为空")
    agents_all = {a["id"]: a for a in list_agent_configs(project_id)}
    participants = []
    for aid in agent_ids or []:
        if aid not in agents_all:
            raise ValueError(f"参与者不存在: {aid}")
        a = agents_all[aid]
        participants.append({"id": a["id"], "name": a["name"], "role": a.get("role"),
                             "model_name": a.get("model_name")})
    if len(participants) < 2:
        raise ValueError("圆桌至少需要 2 个参与者")
    if moderator not in ("user", "ai"):
        raise ValueError("moderator 必须是 user 或 ai")
    if moderator == "ai":
        if not moderator_agent_id or moderator_agent_id not in [p["id"] for p in participants]:
            raise ValueError("AI 主持时 moderator_agent_id 必须是参与者之一")
    try:
        max_rounds = max(2, min(int(max_rounds), 10))
    except (TypeError, ValueError):
        max_rounds = 5

    rt_id = create_roundtable(project_id, topic, participants, moderator,
                              moderator_agent_id, max_rounds,
                              _initial_minutes(topic, attachments),
                              attachments=attachments)
    await run_round(project_id, rt_id, connector=connector)
    return get_roundtable(project_id, rt_id)


async def _one_speech(conn, model: str, topic: str, minutes: str, p: dict,
                      materials_text: str = "") -> str:
    """单个参与者的一轮发言（单轮非流式）。materials_text 为背景材料（每轮独立注入）。"""
    sys_prompt = (f"你是 {p['name']}，角色：{p.get('role') or '专家'}。"
                  "你正在参加一场多角色圆桌讨论，请按主持方给出的发言指令发言。")
    user_prompt = SPEAK_PROMPT_TMPL.format(
        topic=topic, materials=materials_text, minutes=minutes,
        name=p["name"], role=p.get("role") or "专家")
    text = await conn.chat(model=model, messages=[
        {"role": "system", "content": sys_prompt},
        {"role": "user", "content": user_prompt},
    ])
    return str(text or "").strip()


async def _update_minutes(conn, model: str, topic: str, minutes: str,
                          speeches: list[dict]) -> str | None:
    """纪要更新。失败返回 None（保留旧纪要，不中断）。"""
    try:
        speech_text = "\n\n".join(
            f"【{s['name']}】\n{s['content']}" for s in speeches if s.get("ok"))
        text = await conn.chat(model=model, messages=[
            {"role": "system", "content": "你是圆桌讨论的纪要员，只输出纪要正文。"},
            {"role": "user", "content": MINUTES_UPDATE_PROMPT_TMPL.format(
                topic=topic, minutes=minutes, speeches=speech_text)},
        ])
        text = str(text or "").strip()
        return text or None
    except Exception:
        return None


async def _judge_consensus(conn, moderator: dict, topic: str, minutes: str) -> tuple[bool, str]:
    """AI 主持共识判定（宽松判定）。返回 (是否共识, 判定原文)。失败按未共识。"""
    try:
        text = await conn.chat(model=moderator.get("model_name") or "qwen3.8", messages=[
            {"role": "system", "content": "你是圆桌主持人，负责判定各方是否达成共识。"},
            {"role": "user", "content": CONSENSUS_PROMPT_TMPL.format(
                name=moderator.get("name"), role=moderator.get("role") or "主持人",
                topic=topic, minutes=minutes)},
        ])
        text = str(text or "").strip()
        first_line = text.split("\n")[0] if text else ""
        is_consensus = "否" not in first_line and "是" in first_line
        return is_consensus, text
    except Exception:
        return False, ""


async def run_round(project_id: str, rt_id: str, connector: Any = None) -> dict:
    """执行一轮（含 AI 主持的自动续轮，整场持锁）。"""
    from sidecar.ollama.connector import get_ollama_connector
    conn = connector or get_ollama_connector()

    async with _ROUND_LOCK:
        return await _run_round_inner(project_id, rt_id, conn)


async def _run_round_inner(project_id: str, rt_id: str, conn) -> dict:
    """单轮执行主体（调用方须已持 _ROUND_LOCK）。AI 主持未共识且未达上限时锁内递归续轮。"""
    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise ValueError("圆桌不存在")
    round_no = int(rt.get("round") or 0) + 1
    topic = rt["topic"]
    minutes = rt.get("minutes") or _initial_minutes(topic)
    participants = rt.get("participants") or []
    # 纪要员/总结/主持判定用模型：取第一个参与者的模型
    judge_model = participants[0].get("model_name") or "qwen3.8"

    update_roundtable(project_id, rt_id, round=round_no, status="running")

    # 背景材料：每轮独立注入（纪要会被模型重写，材料不能只靠纪要保留）
    materials_text = _build_materials_text(rt.get("attachments"))

    # ── 各参与者顺序发言（决策 7：基于纪要，非共享会话历史）──
    # checkpoint-067 N-1：每次发言前检查取消标志；取消则保留已完成的本轮发言，中止本轮。
    round_speeches: list[dict] = []
    cancelled = False
    for p in participants:
        if _is_cancelled(rt_id):
            cancelled = True
            break
        try:
            text = await _one_speech(conn, p.get("model_name") or "qwen3.8",
                                     topic, minutes, p, materials_text)
            if not text:
                raise ValueError("空回复")
            add_roundtable_message(project_id, rt_id, round_no,
                                   p["id"], p["name"], text, ok=True)
            round_speeches.append({"name": p["name"], "content": text, "ok": True})
        except Exception:
            add_roundtable_message(project_id, rt_id, round_no,
                                   p["id"], p["name"], "（本轮发言失败）", ok=False)
            round_speeches.append({"name": p["name"], "content": "", "ok": False})

    # checkpoint-067 N-1：已取消 → 不再更新纪要/续轮，状态置 waiting_user（保留已完成发言，
    # 用户可继续或结束），清标志后返回。
    if cancelled:
        clear_cancel(rt_id)
        update_roundtable(project_id, rt_id, status="waiting_user")
        return get_roundtable(project_id, rt_id)

    # ── 纪要更新（失败保留旧纪要，不中断）──
    # checkpoint-067 N-1：纪要更新前再次检查取消（发言循环内取消已在上面返回，此处兜底）。
    if _is_cancelled(rt_id):
        clear_cancel(rt_id)
        update_roundtable(project_id, rt_id, status="waiting_user")
        return get_roundtable(project_id, rt_id)
    new_minutes = await _update_minutes(conn, judge_model, topic, minutes, round_speeches)
    if new_minutes:
        minutes = new_minutes
        update_roundtable(project_id, rt_id, minutes=minutes)

    # ── 状态分流（决策 6）──
    if rt.get("moderator") == "ai":
        moderator = next((p for p in participants
                          if p["id"] == rt.get("moderator_agent_id")), None) or participants[0]
        is_consensus, _verdict = await _judge_consensus(conn, moderator, topic, minutes)
        if is_consensus:
            update_roundtable(project_id, rt_id, status="confirm_end")
        elif round_no >= int(rt.get("max_rounds") or 5):
            update_roundtable(project_id, rt_id, status="waiting_user")
        else:
            # 未共识且未达上限 → 锁内自动续轮。
            # checkpoint-067 N-1：续轮前最后检查取消（防止 AI 主持无限续轮时无法停止）。
            if _is_cancelled(rt_id):
                clear_cancel(rt_id)
                update_roundtable(project_id, rt_id, status="waiting_user")
                return get_roundtable(project_id, rt_id)
            return await _run_round_inner(project_id, rt_id, conn)
    else:
        update_roundtable(project_id, rt_id, status="waiting_user")

    return get_roundtable(project_id, rt_id)


async def continue_roundtable(project_id: str, rt_id: str, connector: Any = None) -> dict:
    """用户主持点"继续"→ 下一轮。仅 waiting_user 允许（API 层已守卫）。"""
    return await run_round(project_id, rt_id, connector=connector)


async def finish_roundtable(project_id: str, rt_id: str, connector: Any = None) -> dict:
    """结束并生成总结。总结失败 → 纪要兜底，仍置 done。"""
    from sidecar.ollama.connector import get_ollama_connector
    conn = connector or get_ollama_connector()

    async with _ROUND_LOCK:
        rt = get_roundtable(project_id, rt_id)
        if not rt:
            raise ValueError("圆桌不存在")
        topic = rt["topic"]
        minutes = rt.get("minutes") or _initial_minutes(topic)
        participants = rt.get("participants") or []
        judge_model = participants[0].get("model_name") or "qwen3.8"

        msgs = list_roundtable_messages(project_id, rt_id)
        speeches_text = "\n\n".join(
            f"【{m['agent_name']}·第{m['round']}轮】\n{m['content']}" for m in msgs if m.get("ok"))

        summary = None
        try:
            summary = await conn.chat(model=judge_model, messages=[
                {"role": "system", "content": "你是圆桌讨论的总结人，只输出总结正文。"},
                {"role": "user", "content": SUMMARY_PROMPT_TMPL.format(
                    topic=topic, minutes=minutes, speeches=speeches_text)},
            ])
            summary = str(summary or "").strip() or None
        except Exception:
            summary = None
        if not summary:
            summary = "（总结生成失败，纪要如下）\n" + minutes
        update_roundtable(project_id, rt_id, summary=summary, status="done")
        return get_roundtable(project_id, rt_id)


def export_roundtable_md(project_id: str, rt_id: str, out_dir: str | None = None) -> dict:
    """TS-109 增强（H18-2 保存模块）：把整场讨论导出为 Markdown 文件。

    保存位置：out_dir（可选）→ 默认 **项目工作目录**/roundtables/
    （用户 2026-08-29 纠正：不要存到软件数据目录，要存到用户的项目文件夹）。
    项目工作目录取不到时兜底软件数据目录，保证导出永不失败。
    返回 {"path": 绝对路径, "name": 文件名}；圆桌不存在抛 ValueError。
    文件结构：元信息（议题/主持人/参与者/轮次/状态）→ 纪要 → 逐轮发言 → 总结。
    """
    from datetime import datetime as _dt
    from pathlib import Path as _Path

    rt = get_roundtable(project_id, rt_id)
    if not rt:
        raise ValueError("圆桌不存在")
    msgs = list_roundtable_messages(project_id, rt_id)

    if out_dir:
        target_dir = _Path(str(out_dir)).expanduser()
    else:
        # M7（TS-113）：统一走默认导出目录配置（空=项目工作目录；
        # 内部含项目工作目录取不到时的数据目录兜底，导出永不失败）
        from sidecar.exporter import resolve_export_dir
        target_dir = resolve_export_dir(project_id) / "roundtables"
    target_dir.mkdir(parents=True, exist_ok=True)

    ts = _dt.now().strftime("%Y%m%d_%H%M%S")
    # 文件名：时间戳 + 议题前 20 字（清洗非法字符）
    safe_topic = "".join(c for c in rt["topic"] if c not in r'\/:*?"<>|').strip()[:20] or "圆桌讨论"
    fname = f"roundtable_{ts}_{safe_topic}.md"
    fpath = target_dir / fname

    moderator_agent = None
    if rt.get("moderator") == "ai":
        moderator_agent = next((p for p in rt.get("participants", [])
                                if p.get("id") == rt.get("moderator_agent_id")), None)
    moderator_line = (f"AI 主持：{moderator_agent.get('name')}" if moderator_agent
                      else "用户主持")

    lines: list[str] = []
    lines.append(f"# 圆桌讨论记录：{rt['topic']}")
    lines.append("")
    lines.append(f"- **状态**：{rt.get('status')}")
    lines.append(f"- **轮次**：{rt.get('round')}/{rt.get('max_rounds')}")
    lines.append(f"- **主持人**：{moderator_line}")
    lines.append(f"- **参与者**：{'、'.join(p.get('name', '') for p in rt.get('participants', []))}")
    lines.append(f"- **创建时间**：{rt.get('created_at', '')}")
    lines.append(f"- **导出时间**：{_dt.now().strftime('%Y-%m-%d %H:%M:%S')}")
    if rt.get("attachments"):
        names = "、".join(str(a.get("name", "")) for a in rt["attachments"])
        lines.append(f"- **议题附件**：{names}")
    lines.append("")
    if rt.get("minutes"):
        lines.append("## 讨论纪要")
        lines.append("")
        lines.append(rt["minutes"])
        lines.append("")
    # 逐轮发言
    rounds: dict[int, list] = {}
    for m in msgs:
        rounds.setdefault(m["round"], []).append(m)
    for rn in sorted(rounds):
        lines.append(f"## 第 {rn} 轮")
        lines.append("")
        for m in rounds[rn]:
            ok_mark = "" if m.get("ok") else "（发言失败）"
            lines.append(f"### {m['agent_name']}{ok_mark}")
            lines.append("")
            lines.append(m.get("content") or "")
            lines.append("")
    if rt.get("summary"):
        lines.append("## 讨论总结")
        lines.append("")
        lines.append(rt["summary"])
        lines.append("")

    fpath.write_text("\n".join(lines), encoding="utf-8")
    return {"path": str(fpath), "name": fname}
