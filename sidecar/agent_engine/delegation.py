"""M3-1（TS-107）：主-子委派执行器。

设计依据：01-需求文档 3.13 / 3.13.1（用户拍板）+ 交接/任务单/TS-107。
- 决策 2：子 Agent 上下文隔离——只看任务书（目标+输入+预期输出），不看主对话历史
- 决策 3：固定交卷契约 {task_id, status, summary≤300, artifacts}；
          校验失败→主 Agent 侧自动追问 1 次，再失败标"异常"
- 决策 4：串行执行（本地 Ollama 单推理进程，防并行抢内存）
- 决策 5（本段）：2 次校验失败→标异常 + 告知缺失原因
- 决策 8：目标解析 = 精确匹配→模糊匹配→未命中返回错误并列出可用 Agent
- 用户补充拍板（2026-08-29）：子任务不设超时。异常判定仅两条：
  交卷 2 次校验失败、执行过程抛错。本模块禁止引入超时逻辑。

执行方式：子 Agent 复用现有 run_tool_loop + 沙盒/授权/网络守卫（不重复造轮子）。
"""
from __future__ import annotations

import asyncio
import json
from datetime import datetime
from typing import Any

from sidecar.storage.store import (
    create_agent_task, update_agent_task, create_session, save_message,
    load_messages, list_agent_configs, add_agent_config, get_agent_config,
    # checkpoint-068（3.22 D-8 去重/重试上限；3.21 D-2 自动清理）
    list_recent_delegations_to_target, delete_session, remove_agent_config,
)
from sidecar.agent_engine.loop import run_tool_loop, build_system_prompt, tools_spec

# ── 交卷契约常量（决策 3；M7 TS-113 扩容 300→1000）──
REPORT_STATUSES = ("success", "partial", "failed")
SUMMARY_MAX_LEN = 1000
ARTIFACTS_MAX_ITEMS = 20

# 串行锁（决策 4）：同一时刻只有一个子任务在推理。
# 整个委派主体（含落库与追问）都在锁内，保证执行时间区间不重叠。
_DELEGATION_LOCK = asyncio.Lock()

# checkpoint-068（3.22 D-4）：并发开关开启时用的异步空锁（永不阻塞，立即获取）。
# 注意：不能用 contextlib.nullcontext()（同步）也不能用 asyncio.Lock()（会串行化）。
class _NoopAsyncLock:
    async def __aenter__(self):
        return self
    async def __aexit__(self, *args):
        return False
_NOOP_LOCK = _NoopAsyncLock()

# checkpoint-068（3.22 D-7 活性超时；默认值由配置项覆盖，0=关闭）
DEFAULT_ACTIVITY_TIMEOUT = 900


def _norm_task_text(t: str) -> str:
    """归一化任务书文本用于去重比对：去首尾空白、压缩连续空白、去首尾标点。"""
    import re as _re
    s = _re.sub(r"\s+", " ", str(t or "")).strip()
    return s.strip("。．. \t")


def _dup_or_over_retry_limit(project_id: str, target_agent_id: str, task: str) -> tuple[str | None, int]:
    """checkpoint-068（3.22 D-8）：委派前置守卫（按任务文本，非按目标）。
    返回 (重复任务ID 或 None, 相同任务文本的历史失败数)。
    - 重复判定：相同任务书（归一化后）已存在且状态为 queued/running/done → 返回其 task_id
      （防止重复委派"进行中/已完成"的同一任务；失败的允许重试，受上限约束）。
    - 失败计数：相同任务文本的历史失败数，供上层与配置上限比较。
    只对"同一任务"生效，不同任务互不影响。
    """
    norm = _norm_task_text(task)
    same_text_failures = 0
    dup_id = None
    try:
        recent = list_recent_delegations_to_target(project_id, target_agent_id, limit=30)
    except Exception:
        return None, 0
    for r in recent:
        if _norm_task_text(r.get("task") or "") != norm:
            continue  # 只统计相同任务文本
        status = r.get("status")
        if status == "failed":
            same_text_failures += 1
        elif status in ("queued", "running", "done") and dup_id is None:
            dup_id = r.get("id")
    return dup_id, same_text_failures

# 追问固定文案（决策 3：校验失败后追问 1 次）
_RETRY_PROMPT_TMPL = (
    "你的交卷未通过格式校验。请重新交卷：只输出一个 JSON 对象，字段为 "
    '{{"task_id": "{task_id}", "status": "success/partial/failed", '
    '"summary": "≤1000字摘要", "artifacts": [ ... ]}}。不要输出 JSON 以外的任何文字。'
)

# 子 Agent system prompt 尾部追加的交卷契约说明
_REPORT_CONTRACT_PROMPT = (
    "\n【交卷契约】\n"
    "你正在执行一个委派任务。完成工作后，最终回复必须是且仅是以下 JSON（不要加任何解释文字）：\n"
    '{"task_id": "<任务ID>", "status": "success 或 partial 或 failed", '
    '"summary": "<不超过1000字的工作摘要>", "artifacts": ["<产出文件路径或结果说明，可多条，没有则空数组>"]}\n'
    "task_id 必须填写任务书中给出的任务ID。"
)


# ---------- 交卷解析与校验（决策 3） ----------
def _extract_json_candidate(text: str) -> str | None:
    """从回复中截取首个 JSON 对象候选：第一个 { 到最后一个 } 的子串。
    兼容三种情形：纯 JSON / ```json 围栏包裹 / JSON 前后混有少量文字。"""
    if not text:
        return None
    t = text.strip()
    # 优先剥 markdown 围栏
    if "```" in t:
        for seg in t.split("```"):
            s = seg.strip()
            if s.startswith("json"):
                s = s[4:].strip()
            if s.startswith("{") and s.endswith("}"):
                return s
    start = t.find("{")
    end = t.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    return t[start:end + 1]


def parse_report(text: str, task_id: str) -> dict | None:
    """解析并校验子 Agent 交卷。合法返回归一化 report dict，否则 None。

    H17 问题4（弱模型兼容）：校验采用"宽容归一化"——只要整体是 JSON 交卷结构就接收，
    小错自动修正而非判不合格（qwen3.6:35b 等弱模型常见：task_id 抄错/漏写、
    summary 超长、status 用词不准）。仅"完全不是 JSON 交卷"才返回 None（走兜底打包）。
    - task_id 缺失/不一致 → 强制修正为实际 task_id（标记 corrected）
    - status 非法 → 归一为 "partial"（标记 corrected）
    - summary 超 1000 字 → 不在此截断，由 _finalize_summary 落盘全文后截断标注（M7）
    - artifacts 非 list → []
    """
    candidate = _extract_json_candidate(text or "")
    if candidate is None:
        return None
    try:
        obj = json.loads(candidate)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(obj, dict):
        return None
    # 宽容归一化（H17）：交卷结构存在即接收，小错修正
    corrected = False
    status = obj.get("status")
    if status not in REPORT_STATUSES:
        status = "partial"
        corrected = True
    summary = obj.get("summary")
    if summary is None:
        # 无 summary 字段：弱模型可能把内容写在别处 → 无交卷结构可言
        return None
    if not isinstance(summary, str):
        summary = str(summary)
    if len(summary) > SUMMARY_MAX_LEN:
        # M7（TS-113）：不再直接截断——全文由 _finalize_summary 落盘后再截断回传
        corrected = True
    if str(obj.get("task_id", "")).strip() != task_id:
        corrected = True
    artifacts_raw = obj.get("artifacts", [])
    if artifacts_raw is None:
        artifacts_raw = []
    if not isinstance(artifacts_raw, list):
        artifacts_raw = []
        corrected = True
    artifacts = [str(a) for a in artifacts_raw][:ARTIFACTS_MAX_ITEMS]
    report = {"task_id": task_id, "status": status, "summary": summary, "artifacts": artifacts}
    if corrected:
        report["format_corrected"] = True
    return report


# ---------- 兜底打包（H17 问题4：弱模型两次交卷均无 JSON → 打包实际工作成果） ----------
def build_fallback_report(text: str, task_id: str) -> dict | None:
    """弱模型未按契约输出 JSON、但确有实质回复时的兜底：把回复全文打包为交卷。

    设计意图：子 Agent 已经真实执行了工作（搜索/写文件等），成果不应因格式问题
    整个丢弃、更不应逼主 Agent 自己重做一遍。打包为 status=partial 交卷，
    summary 保留实质回复全文（M7：超长由 _finalize_summary 落盘+截断回传），
    并标注"（未按契约交卷，以下为子 Agent 原始回复）"。
    无任何实质内容（空/仅空白）→ 返回 None。
    """
    body = (text or "").strip()
    if not body or len(body) < 10:
        return None
    return {
        "task_id": task_id,
        "status": "partial",
        "summary": "（子 Agent 未按契约交卷，以下为其实质回复）" + body,
        "artifacts": [],
        "fallback": True,
    }


# ---------- 交卷超长落盘（M7 TS-113：>1000 字确定性系统行为）----------
def _finalize_summary(project_id: str, task_id: str, report: dict, full_text: str) -> dict:
    """summary ≤1000 字原样回传；>1000 字 → 交卷全文落盘到导出目录
    delegation_reports/，summary 回传前 1000 字 + 文件路径标注。
    落盘失败不阻塞委派（仅截断）。"""
    summary = str(report.get("summary") or "")
    if len(summary) <= SUMMARY_MAX_LEN:
        return report
    path = None
    try:
        from sidecar.exporter import save_delegation_report_md
        path = save_delegation_report_md(project_id, task_id, report, full_text)
    except Exception:
        path = None
    if path:
        report["summary"] = summary[:SUMMARY_MAX_LEN] + f"\n[交卷全文已保存：{path}]"
        report["summary_saved_path"] = path
    else:
        report["summary"] = summary[:SUMMARY_MAX_LEN] + "\n[交卷全文过长已截断，落盘失败]"
    return report


# ---------- 目标解析（决策 8） ----------
def resolve_target(project_id: str, target: str, self_agent_id: str) -> tuple[dict | None, str]:
    """解析委派目标。返回 (agent, error)：命中时 error 为空；未命中时 agent 为 None。

    顺序：参数完整性 → 精确匹配（id 或 name，忽略大小写/首尾空白）
    → 模糊匹配（互为子串，多命中取 name 最短）→ 未命中列出可用名单。
    候选一律排除发起者自己。
    """
    t = str(target or "").strip()
    if not t:
        return None, "delegate_task 需要 target/task/expect 三个参数，请补全。"
    candidates = [a for a in list_agent_configs(project_id) if a.get("id") != self_agent_id]
    tl = t.lower()
    # 1) 精确匹配
    for a in candidates:
        if a.get("id") == t or str(a.get("name", "")).strip().lower() == tl:
            return a, ""
    # 2) 模糊匹配（互为子串）
    fuzzy = [a for a in candidates
             if tl in str(a.get("name", "")).lower() or str(a.get("name", "")).lower() in tl]
    if len(fuzzy) == 1:
        return fuzzy[0], ""
    if len(fuzzy) > 1:
        best = min(fuzzy, key=lambda a: len(str(a.get("name", ""))))
        return best, ""
    # 3) 未命中
    names = "、".join(str(a.get("name", "")) for a in candidates) or "（当前没有其他 Agent）"
    return None, f"未找到名为「{target}」的 Agent。当前可用：{names}。请从中选择。"


# ---------- 自动新建子 Agent（决策 9/10，TS-108） ----------
def auto_create_agent(project_id: str, suggested_role: str, model_name: str) -> dict:
    """按建议角色自动新建子 Agent（Codex 式）。新建后保留在项目内可复用。

    name = 建议角色（去首尾空白）；与现有 Agent 重名 → 追加 -2/-3…（取最小可用号）。
    返回新 Agent 的完整配置 dict（含 id）。
    """
    base = str(suggested_role or "").strip() or "子Agent"
    existing = {str(a.get("name", "")).strip() for a in list_agent_configs(project_id)}
    name = base
    n = 2
    while name in existing:
        name = f"{base}-{n}"
        n += 1
    aid = add_agent_config(project_id, name, "sub", model_name=model_name, role=base)
    return get_agent_config(project_id, aid) or {
        "id": aid, "name": name, "role": base, "model_name": model_name,
        "type_": "sub", "parent_agent_id": None, "system_prompt": None,
    }


# ---------- 委派执行器 ----------
# checkpoint-068（3.22 D-7）：活性超时——防止模型进入僵死（吞吐近零、不产出）时
# 委派无限等待。超时由 _run_pass_with_timeout 用 asyncio.wait_for 实现（0=关闭）。
async def _run_one_pass(model: str, msgs: list[dict], sandbox_root: str,
                        authorizer: Any, max_rounds: int, connector: Any) -> tuple[str, list[dict], str | None]:
    """跑一次子会话 loop，返回 (最终文本, tool_steps, 错误)。
    子任务不做压缩交互：compact 事件按跳过处理（不弹窗、不中断）。"""
    from sidecar.ollama.connector import get_ollama_connector
    conn = connector or get_ollama_connector()
    full_text = ""
    steps: list[dict] = []
    async for ev in run_tool_loop(model, msgs, tools_spec(with_delegation=False), sandbox_root,
                                  authorizer=authorizer, max_rounds=max_rounds,
                                  context_limit=0, connector=conn):
        e, d = ev.get("event"), ev.get("data") or {}
        if e == "token":
            full_text += d.get("delta", "")
        elif e == "tool_call":
            steps.append({"id": d.get("id", ""), "name": d.get("name", ""),
                          "args": d.get("args", {}), "status": "running"})
        elif e == "tool_result":
            entry = {"name": d.get("name", ""), "ok": bool(d.get("ok", True)),
                     "error": d.get("error"), "summary": d.get("summary"),
                     "status": "ok" if d.get("ok") else "error"}
            if steps and steps[-1].get("name") == entry["name"] and steps[-1].get("status") == "running":
                entry["id"] = steps[-1].get("id", "")
                entry["args"] = steps[-1].get("args")
                steps[-1] = entry
            else:
                steps.append(entry)
        elif e == "done":
            if isinstance(d.get("content"), str) and d["content"].strip():
                full_text = d["content"]
        elif e == "error":
            return full_text, steps, str(d.get("detail", "子任务执行出错"))
        # compact_auto / compact_required / state / thinking：跳过（子任务不压缩不交互）
    return full_text, steps, None


def _task_user_message(task_id: str, task: str, expect: str) -> str:
    return (
        "【委派任务】\n"
        f"任务ID：{task_id}\n"
        "任务目标与输入：\n"
        f"{task}\n\n"
        "交卷标准：\n"
        f"{expect}\n\n"
        "【执行须知】读取文件前必须先用 list_dir 列出目录确认文件真实存在，"
        "禁止凭猜测的文件名直接 read_file；找不到文件就如实说明，不要编造。\n"
        "完成后请按【交卷契约】输出交卷内容。"
    )


# checkpoint-068（3.22 D-7）：用活性超时包住一次子会话执行。
# timeout>0 时整个执行超过该秒数即抛 asyncio.TimeoutError（由调用方判卡死）；0=不限制。
async def _run_pass_with_timeout(model: str, msgs: list[dict], sandbox_root: str,
                               authorizer: Any, max_rounds: int, connector: Any,
                               timeout: float) -> tuple[str, list[dict], str | None]:
    if timeout and timeout > 0:
        return await asyncio.wait_for(
            _run_one_pass(model, msgs, sandbox_root, authorizer, max_rounds, connector),
            timeout=timeout)
    return await _run_one_pass(model, msgs, sandbox_root, authorizer, max_rounds, connector)


async def run_delegated_task(
    project_id: str, parent_agent_id: str, parent_session_id: str,
    target_agent: dict, task: str, expect: str,
    sandbox_root: str, authorizer: Any = None, max_rounds: int = 200,
    connector: Any = None,
) -> dict:
    """执行一次委派（默认串行锁内；task_concurrency 开启时并行）。

    成功：{"ok": True, "task_id", "status", "summary", "artifacts"}
    失败：{"ok": False, "task_id"?, "error": 缺失/失败原因}

    checkpoint-068（3.22）：
    - D-8 前置守卫：相同任务书（对同一目标）不重复委派；失败次数达配置上限则拒绝并提示主 Agent 停止重试。
    - D-7 活性超时：子任务执行超过 delegation_activity_timeout 秒（配置，默认 900，0=关）判卡死中止。
    - D-4 任务并发：task_concurrency=True 放开串行锁，允许并行委派。
    - D-2 自动清理：见成功路径（开关 + 交卷 success 才清理）。
    """
    target_agent_id = str(target_agent.get("id", ""))
    target_name = str(target_agent.get("name", "")) or target_agent_id[:8]
    model = target_agent.get("model_name") or "qwen3.8"

    # checkpoint-068 D-8：委派前置守卫（去重 + 失败重试上限），在落库前拦截
    dup_id, failed_count = _dup_or_over_retry_limit(project_id, target_agent_id, task)
    if dup_id is not None:
        return {"ok": False,
                "error": (f"相同任务已委派给「{target_name}」（任务 {dup_id[:8]}），请勿重复委派。"
                          f"可查看该任务结果，或调整任务书后再委派。")}
    try:
        import sidecar.config as _cfg0
        _max_retries = int(_cfg0.get_config().get("delegation_max_retries", 2))
    except Exception:
        _max_retries = 2
    if _max_retries > 0 and failed_count >= _max_retries:
        return {"ok": False,
                "error": (f"「{target_name}」已有 {failed_count} 次失败（上限 {_max_retries} 次），"
                          f"请勿继续重试同一委派。请向用户说明情况，建议调整任务书、更换目标或人工处理。")}

    # checkpoint-068 D-7：活性超时（秒，0=关闭）
    try:
        import sidecar.config as _cfg1
        _activity_timeout = float(_cfg1.get_config().get("delegation_activity_timeout", DEFAULT_ACTIVITY_TIMEOUT))
    except Exception:
        _activity_timeout = float(DEFAULT_ACTIVITY_TIMEOUT)

    # checkpoint-068 D-4：任务并发开关（默认关 = 串行排队）
    try:
        import sidecar.config as _cfg2
        _concurrent = bool(_cfg2.get_config().get("task_concurrency", False))
    except Exception:
        _concurrent = False

    # TS-108（决策 4 排队语义）：先落库（status=queued），再等串行锁。
    # 排队窗口对任务面板可见；拿到锁后才改 running。
    task_id = create_agent_task(project_id, parent_agent_id, parent_session_id,
                                target_agent_id, target_name, task, expect)

    try:
        _lock_ctx = _NOOP_LOCK if _concurrent else _DELEGATION_LOCK
        async with _lock_ctx:
            update_agent_task(project_id, task_id, status="running")
            # 上下文隔离（决策 2）：为子 Agent 新建独立会话，只有任务书，无主对话历史
            child_sid = create_session(project_id, target_agent_id, title=f"委派任务 {task_id[:8]}")
            update_agent_task(project_id, task_id, session_id=child_sid)

            import sidecar.config as _cfgmod
            net_switch = str(_cfgmod.get_config().get("network_switch", "auto"))
            # TS-110 M4：子 Agent 同样注入知识/记忆/技能（项目级/全局资源，助其完成任务）；
            # 加载失败一律降级为空，不阻塞委派
            _k_text, _m_text, _proh, _sk_text = "", "", [], ""
            try:
                from sidecar.knowledge import build_knowledge_text, build_memory_injection
                _k_text = build_knowledge_text(project_id)
                _m_text, _proh = build_memory_injection(project_id)
            except Exception:
                pass
            try:
                # 技能清单只含启用项（逐项开关生效：禁用技能不注入、不可用，见 checkpoint-047）
                from sidecar.skills_mgr import build_skills_list_text
                _sk_text = build_skills_list_text()
            except Exception:
                pass
            sys_prompt = build_system_prompt(
                agent_name=target_name,
                agent_role=target_agent.get("role"),
                sandbox_root=sandbox_root,
                network_switch=net_switch,
                system_prompt=target_agent.get("system_prompt"),
                knowledge_text=_k_text,
                memory_text=_m_text,
                prohibitions=_proh,
                skills_list_text=_sk_text,
            ) + _REPORT_CONTRACT_PROMPT

            user_msg = _task_user_message(task_id, task, expect)
            save_message(project_id, child_sid, target_agent_id, "user", user_msg)

            try:
                # 第一轮：任务书 → 子 Agent 执行 → 交卷
                msgs = [{"role": "system", "content": sys_prompt},
                        {"role": "user", "content": user_msg}]
                full_text, steps, err = await _run_pass_with_timeout(
                    model, msgs, sandbox_root, authorizer, max_rounds, connector,
                    _activity_timeout)
                save_message(project_id, child_sid, target_agent_id, "assistant", full_text,
                             model_used=model, tool_steps=steps or None)
                if err:
                    update_agent_task(project_id, task_id, status="failed", fail_reason=err)
                    return {"ok": False, "task_id": task_id,
                            "error": f"子 Agent「{target_name}」执行出错：{err}"}

                report = parse_report(full_text, task_id)
                _final_text = full_text
                if report is None:
                    # 追问 1 次（决策 3）：子会话完整历史 + 固定追问文案
                    retry_msg = _RETRY_PROMPT_TMPL.format(task_id=task_id)
                    save_message(project_id, child_sid, target_agent_id, "user", retry_msg)
                    msgs2 = msgs + [{"role": "assistant", "content": full_text},
                                    {"role": "user", "content": retry_msg}]
                    full_text2, steps2, err2 = await _run_pass_with_timeout(
                        model, msgs2, sandbox_root, authorizer, max_rounds, connector,
                        _activity_timeout)
                    save_message(project_id, child_sid, target_agent_id, "assistant", full_text2,
                                 model_used=model, tool_steps=steps2 or None)
                    _final_text = full_text2
                    if err2:
                        update_agent_task(project_id, task_id, status="failed",
                                          validation_failures=1, fail_reason=err2)
                        return {"ok": False, "task_id": task_id,
                                "error": f"子 Agent「{target_name}」执行出错：{err2}"}
                    report = parse_report(full_text2, task_id)
                    if report is None:
                        # H17 问题4：兜底打包——弱模型确实干了活但没按契约交卷，
                        # 把实质回复打包为 partial 交卷（成果不丢、不逼主 Agent 自己重做）
                        report = build_fallback_report(full_text2, task_id)
                    if report is None:
                        reason = "交卷格式两次校验未通过"
                        update_agent_task(project_id, task_id, status="failed",
                                          validation_failures=2, fail_reason=reason)
                        return {"ok": False, "task_id": task_id,
                                "error": (f"子 Agent「{target_name}」两次交卷均未通过格式校验，"
                                          f"该子任务标记异常。缺失的产出：{str(expect)[:200]}")}
                # M7（TS-113）交卷契约扩容：>1000 字自动落盘全文 + 截断回传（确定性系统行为）
                report = _finalize_summary(project_id, task_id, report, _final_text)
                update_agent_task(project_id, task_id, status="done", report=json.dumps(report, ensure_ascii=False))
                # checkpoint-068（3.21 D-2）：委派成功后自动清理子 Agent 与会话。
                # 前提（用户拍板）：开关开启 + 交卷确实 success（确实委派且确实完成）；
                # 且仅清理自动新建的 sub 型子 Agent，绝不误删用户的主 Agent。
                try:
                    import sidecar.config as _cfg_clean
                    if bool(_cfg_clean.get_config().get("delegation_auto_cleanup", False)) \
                            and report.get("status") == "success":
                        _agent_cfg = get_agent_config(project_id, target_agent_id)
                        if _agent_cfg and _agent_cfg.get("type_") == "sub":
                            try:
                                delete_session(project_id, child_sid)
                                remove_agent_config(project_id, target_agent_id)
                            except Exception:
                                pass  # 清理失败不影响主流程，仅保持界面整洁性降级
                except Exception:
                    pass
                return {"ok": True, "task_id": task_id, "status": report["status"],
                        "summary": report["summary"], "artifacts": report["artifacts"],
                        "target_agent_name": target_name}
            except asyncio.TimeoutError:
                # checkpoint-068 D-7：活性超时 → 判卡死，标记失败并中止
                _to_reason = (f"活性超时：子任务 {int(_activity_timeout)} 秒内未完成（疑似模型僵死），已中止")
                update_agent_task(project_id, task_id, status="failed", fail_reason=_to_reason)
                return {"ok": False, "task_id": task_id,
                        "error": f"子 Agent「{target_name}」{_to_reason}。请勿盲目重试同一任务。"}
            except asyncio.CancelledError:
                raise  # 由外层统一标记中断
            except Exception as e:  # 兜底：任何异常都不允许穿透到主 loop
                try:
                    update_agent_task(project_id, task_id, status="failed", fail_reason=str(e))
                except Exception:
                    pass
                return {"ok": False, "task_id": task_id,
                        "error": f"子 Agent「{target_name}」执行出错：{e}"}
    except asyncio.CancelledError:
        # 客户端停止主会话（含排队等锁期间被停止）→ 标记中断后继续上抛
        try:
            update_agent_task(project_id, task_id, status="failed",
                              fail_reason="委派被中断（用户停止或连接断开）")
        except Exception:
            pass
        raise
