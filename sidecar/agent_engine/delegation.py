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

# TS-114（3.25 委派任务停止）：取消标志注册表（同圆桌 _CANCEL_FLAGS 机制）。
# request_delegation_cancel(task_id) 置标志；执行循环在检查点（拿锁后/每轮前/追问前）
# 检测到标志即中止：任务标 failed（fail_reason 含"已停止"），不再发起新的模型调用。
_DELEGATION_CANCEL: dict[str, bool] = {}

# TS-116（3.21④）：记录上一次委派使用的模型，用于检测模型切换。
# model_parallel=false 时，切换模型需等待 5s 让 Ollama 自动 GC 旧模型（无 unload API）。
_LAST_DELEGATED_MODEL: dict[str, str] = {}  # project_id → model_name


def request_delegation_cancel(task_id: str) -> None:
    _DELEGATION_CANCEL[str(task_id)] = True


def clear_delegation_cancel(task_id: str) -> None:
    _DELEGATION_CANCEL.pop(str(task_id), None)


def _is_delegation_cancelled(task_id: str) -> bool:
    return bool(_DELEGATION_CANCEL.get(str(task_id)))


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


# ---------- 0.1.71（TS-118）：简单委派模式 ----------
# 背景（用户实测 2026-09-02）：带图委派给 OCR 专用模型（如 glm-ocr）时，
# 子模型已正确识别图片，但【交卷契约】强制要求 JSON 报告 → 小模型做不到 →
# 系统追问"重新交卷" → 小模型崩溃输出乱码，正确结果被丢弃。
# 同时任务消息无条件拼接大段模板文字，违背用户"只发图片给子 Agent"的意图。
# 简单模式三件事：不拼交卷契约、任务消息只留任务书、第一轮原文直接作为结果
# （不做 JSON 校验、不追问重交）。触发全自动：带图 / 目标为 OCR 专用模型 /
# 主模型显式传 simple_mode=true，用户无需任何操作。

def is_simple_delegation_model(model: str) -> bool:
    """OCR 专用小模型（名称含 ocr，如 glm-ocr）只输出识别文字，不适合 JSON 交卷。"""
    return "ocr" in str(model or "").lower()


def resolve_simple_mode(images: list[str] | None, model: str,
                        simple_mode: bool | None = None) -> bool:
    """判定本次委派是否走简单模式。带图 → 强制启用（识别类任务天然不需要
    交卷格式）；其余看显式参数或目标模型类型。"""
    if images:
        return True
    if simple_mode:
        return True
    return is_simple_delegation_model(model)


def _task_user_message_simple(task_id: str, task: str, expect: str,
                              image_count: int = 0) -> str:
    """简单模式任务消息：只保留任务书本身 + 最小交付要求。
    不拼执行须知/防幻觉硬约束/交卷契约提醒（这些会压垮 OCR 类小模型，
    且违背用户"只发图片不发文字"的意图）。"""
    img_hint = (f"附图 {image_count} 张已随任务书发送，请直接识别，无需 read_file。\n\n"
                if image_count > 0 else "")
    return (
        "【委派任务】\n"
        f"任务ID：{task_id}\n"
        f"任务目标与输入：\n{task}\n\n"
        f"交卷标准：\n{expect}\n\n"
        f"{img_hint}"
        "完成后直接输出结果本身（纯内容，不要包装成 JSON、不要附加格式说明）。"
    )


def _build_simple_report(full_text: str, task_id: str) -> dict | None:
    """简单模式交卷：第一轮原文直接打包为结果（不做 JSON 校验、不追问）。
    空回复返回 None（调用方标失败）。超长由 _finalize_summary 落盘+截断。"""
    body = (full_text or "").strip()
    if not body:
        return None
    return {"task_id": task_id, "status": "success",
            "summary": body, "artifacts": [], "simple": True}


# ---------- 0.1.71（TS-118）：目标模型视觉能力检测 ----------
# 背景：带图委派给纯文本模型（如 qwen3.6:35b）时，模型看不见图片却编造
# "已完成 OCR"（用户实测 2026-09-02 第一批委派全文幻觉）。检测失败不阻塞，
# 检测确认无视觉能力才拦截，并提示改派多模态模型。
_MULTIMODAL_NAME_PATTERNS = (
    "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "qwen3.5-vl",
    "llava", "minicpm-v", "glm-4v", "glm-ocr", "moondream", "bakllava",
    "gemma3", "llama3.2-vision", "mllama", "llama4", "granite-vision",
    "aya-vision", "qwen2.5-omni", "omni",
)
_VISION_METADATA_MARKERS = ("vision", "clip", "siglip", "projector", "mmproj", ".images")


def model_name_suggests_vision(model: str) -> bool | None:
    """按模型名快速判断视觉能力：已知多模态家族 → True；无法判断 → None
    （由调用方继续查模型元数据）。纯名称层不判 False，避免误杀自定义标签模型。"""
    ml = str(model or "").lower()
    for p in _MULTIMODAL_NAME_PATTERNS:
        if p in ml:
            return True
    return None


async def model_supports_vision(model: str, connector: Any) -> bool:
    """目标模型是否支持图片输入。名称层判不了时查 /api/show 元数据；
    查询失败/模型不存在 → 返回 True（不阻塞，宁可放过不误杀，
    模型不存在等错误由后续调用自然暴露）。"""
    hit = model_name_suggests_vision(model)
    if hit is not None:
        return hit
    try:
        client = await connector._client()
        r = await client.post(f"{connector._base}/api/show", json={"name": model}, timeout=5)
        if r.status_code != 200:
            return True
        txt = json.dumps(r.json(), ensure_ascii=False).lower()
        return any(m in txt for m in _VISION_METADATA_MARKERS)
    except Exception:
        return True


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
                        authorizer: Any, max_rounds: int, connector: Any,
                        cancel_check: Any = None,
                        first_round_images: list[str] | None = None) -> tuple[str, list[dict], str | None, int]:
    """跑一次子会话 loop，返回 (最终文本, tool_steps, 错误)。
    子任务不做压缩交互：compact 事件按跳过处理（不弹窗、不中断）。
    TS-114（3.25）：cancel_check 回调为真时，run_tool_loop 在下一轮开始前中止。
    TS-114（3.27）：first_round_images 把委派附着的图片传给子会话视觉流。"""
    from sidecar.ollama.connector import get_ollama_connector
    conn = connector or get_ollama_connector()
    full_text = ""
    steps: list[dict] = []
    _pe_max_box = [0]  # TS-116：本轮最大 prompt_eval_count（列表包装避免闭包 reassignment）
    async for ev in run_tool_loop(model, msgs, tools_spec(with_delegation=False), sandbox_root,
                                  authorizer=authorizer, max_rounds=max_rounds,
                                  context_limit=0, connector=conn,
                                  cancel_check=cancel_check,
                                  first_round_images=first_round_images):
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
            return full_text, steps, str(d.get("detail", "子任务执行出错")), _pe_max_box[0]
        elif e == "cancelled":
            # TS-114（3.25）：loop 检查点检测到取消标志 → 中止子会话
            return full_text, steps, "已停止", _pe_max_box[0]
        elif e == "state":
            # TS-116（3.20③）：收集 prompt_eval_count 回传给主会话
            pe = d.get("prompt_eval_count")
            if isinstance(pe, int) and pe > 0 and pe > _pe_max_box[0]:
                _pe_max_box[0] = pe
        # compact_auto / compact_required / thinking：跳过（子任务不压缩不交互）
    return full_text, steps, None, _pe_max_box[0]


def _task_user_message(task_id: str, task: str, expect: str, image_count: int = 0) -> str:
    # TS-114（3.27）：附图提示——图片已随任务书进入视觉流，子 Agent 直接看，无需 read_file
    img_hint = (f"附图 {image_count} 张已随任务书发送，请直接识别，无需 read_file。\n\n"
                if image_count > 0 else "")
    return (
        "【委派任务】\n"
        f"任务ID：{task_id}\n"
        "任务目标与输入：\n"
        f"{task}\n\n"
        "交卷标准：\n"
        f"{expect}\n\n"
        f"{img_hint}"
        "【执行须知】读取文件前必须先用 list_dir 列出目录确认文件真实存在，"
        "禁止凭猜测的文件名直接 read_file；找不到文件就如实说明，不要编造。\n"
        "【防幻觉硬约束】\n"
        "1. 转写/识别图片时，必须逐字如实记录图片中真实可见的文字；严禁编造图片中不存在的"
        "内容、对话、时间戳或数据。宁可少报，不可编造。\n"
        "2. 严禁伪造执行记录：不得编造“已读取/已保存/准确率xx%”等未经工具真实验证的描述；"
        "凡声称保存了文件，必须真实调用 write_file 且工具返回 ok。\n"
        "3. 图片读不到、看不清或无法转写时，必须如实交卷 status=failed 并说明原因，"
        "绝不允许输出编造内容。\n"
        "完成后请按【交卷契约】输出交卷内容。"
    )


# checkpoint-068（3.22 D-7）：用活性超时包住一次子会话执行。
# timeout>0 时整个执行超过该秒数即抛 asyncio.TimeoutError（由调用方判卡死）；0=不限制。
async def _run_pass_with_timeout(model: str, msgs: list[dict], sandbox_root: str,
                               authorizer: Any, max_rounds: int, connector: Any,
                               timeout: float, cancel_check: Any = None,
                               first_round_images: list[str] | None = None) -> tuple[str, list[dict], str | None, int]:
    if timeout and timeout > 0:
        return await asyncio.wait_for(
            _run_one_pass(model, msgs, sandbox_root, authorizer, max_rounds, connector,
                          cancel_check=cancel_check, first_round_images=first_round_images),
            timeout=timeout)
    return await _run_one_pass(model, msgs, sandbox_root, authorizer, max_rounds, connector,
                               cancel_check=cancel_check, first_round_images=first_round_images)


async def run_delegated_task(
    project_id: str, parent_agent_id: str, parent_session_id: str,
    target_agent: dict, task: str, expect: str,
    sandbox_root: str, authorizer: Any = None, max_rounds: int = 200,
    connector: Any = None,
    images: list[str] | None = None,
    simple_mode: bool | None = None,
) -> dict:
    """执行一次委派（默认串行锁内；task_concurrency 开启时并行）。
    TS-114（3.27）：images=委派附着图片（base64 列表），传入子会话视觉流。
    0.1.71（TS-118）：simple_mode=简单委派模式（带图自动启用，见
    resolve_simple_mode）；带图委派遇无视觉能力模型直接拦截报错。

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

    # 0.1.71（TS-118）：简单模式判定（带图强制启用 / 显式传参 / OCR 专用模型）
    _simple = resolve_simple_mode(images, model, simple_mode)

    # 0.1.71（TS-118）：带图委派的视觉能力守卫——目标模型不支持图片输入时
    # 直接拦截，避免纯文本模型看不见图片却编造"已完成识别"（用户实测幻觉重灾区）
    if images and not await model_supports_vision(model, connector):
        return {"ok": False,
                "error": (f"「{target_name}」的模型 {model} 不支持图片输入，无法完成带图任务。"
                          f"请改派多模态模型（如 qwen-vl / glm-ocr / llava 等）后再委派。")}

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
            # TS-114（3.25）检查点1：排队期间被请求停止 → 直接标失败，不再发起模型调用
            if _is_delegation_cancelled(task_id):
                clear_delegation_cancel(task_id)
                update_agent_task(project_id, task_id, status="failed",
                                  fail_reason="用户已停止该委派任务（已停止，未执行）")
                return {"ok": False, "task_id": task_id,
                        "error": f"子 Agent「{target_name}」任务已被用户停止。"}
            # TS-116（3.21④）：model_parallel=false + 模型切换 → 等待 5s 让 Ollama GC 旧模型
            try:
                import sidecar.config as _cfg_mp
                _mp = bool(_cfg_mp.get_config().get("model_parallel", False))
            except Exception:
                _mp = False
            if not _mp:
                _last_model = _LAST_DELEGATED_MODEL.get(project_id)
                if _last_model and _last_model != model:
                    await asyncio.sleep(5)  # 等待 Ollama 自动 GC 旧模型
            _LAST_DELEGATED_MODEL[project_id] = model
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
            ) + ("" if _simple else _REPORT_CONTRACT_PROMPT)

            # 0.1.71（TS-118）：简单模式任务消息只留任务书本身（不拼执行须知/
            # 防幻觉约束/契约提醒），符合用户"只发图片不发文字"的委派意图
            user_msg = (_task_user_message_simple(task_id, task, expect,
                                                  image_count=len(images) if images else 0)
                        if _simple else
                        _task_user_message(task_id, task, expect,
                                           image_count=len(images) if images else 0))
            # 0.1.71（TS-118）：委派附着的图片落库存档，子会话回看可见
            save_message(project_id, child_sid, target_agent_id, "user", user_msg,
                         images=images or None)

            # TS-114（3.25）：本任务取消检查回调（loop 每轮开始前调用）
            _cc = (lambda: _is_delegation_cancelled(task_id))
            _pe_final_box = [0]  # TS-116：交卷报告 prompt_eval_count（追问路径可能不赋值）
            try:
                # 第一轮：任务书 → 子 Agent 执行 → 交卷
                msgs = [{"role": "system", "content": sys_prompt},
                        {"role": "user", "content": user_msg}]
                full_text, steps, err, pe1 = await _run_pass_with_timeout(
                    model, msgs, sandbox_root, authorizer, max_rounds, connector,
                    _activity_timeout, cancel_check=_cc, first_round_images=images)
                if pe1: _pe_final_box[0] = pe1
                # TS-114（3.25）检查点2：第一轮结束后、交卷解析前
                if _is_delegation_cancelled(task_id):
                    clear_delegation_cancel(task_id)
                    update_agent_task(project_id, task_id, status="failed",
                                      fail_reason="用户已停止该委派任务（已停止）")
                    return {"ok": False, "task_id": task_id,
                            "error": f"子 Agent「{target_name}」任务已被用户停止。"}
                save_message(project_id, child_sid, target_agent_id, "assistant", full_text,
                             model_used=model, tool_steps=steps or None)
                if err:
                    update_agent_task(project_id, task_id, status="failed", fail_reason=err)
                    return {"ok": False, "task_id": task_id,
                            "error": f"子 Agent「{target_name}」执行出错：{err}"}

                # 0.1.71（TS-118）：简单模式交卷——第一轮原文直接作为结果，
                # 不做 JSON 校验、不追问重交（追问会压垮 OCR 类小模型致乱码）
                if _simple:
                    report = _build_simple_report(full_text, task_id)
                    _final_text = full_text
                    if report is None:
                        reason = "子 Agent 未返回任何内容"
                        update_agent_task(project_id, task_id, status="failed",
                                          fail_reason=reason)
                        return {"ok": False, "task_id": task_id,
                                "error": (f"子 Agent「{target_name}」{reason}，"
                                          f"请检查图片可读性后重试。")}
                else:
                    report = parse_report(full_text, task_id)
                    _final_text = full_text
                if report is None:
                    # TS-114（3.25）检查点3：追问前
                    if _is_delegation_cancelled(task_id):
                        clear_delegation_cancel(task_id)
                        update_agent_task(project_id, task_id, status="failed",
                                          fail_reason="用户已停止该委派任务（已停止）")
                        return {"ok": False, "task_id": task_id,
                                "error": f"子 Agent「{target_name}」任务已被用户停止。"}
                    # 追问 1 次（决策 3）：子会话完整历史 + 固定追问文案
                    retry_msg = _RETRY_PROMPT_TMPL.format(task_id=task_id)
                    save_message(project_id, child_sid, target_agent_id, "user", retry_msg)
                    msgs2 = msgs + [{"role": "assistant", "content": full_text},
                                    {"role": "user", "content": retry_msg}]
                    full_text2, steps2, err2, pe2 = await _run_pass_with_timeout(
                        model, msgs2, sandbox_root, authorizer, max_rounds, connector,
                        _activity_timeout, cancel_check=_cc)
                    if pe2: _pe_final_box[0] = pe2
                    # TS-114（3.25）检查点4：追问结束后
                    if _is_delegation_cancelled(task_id):
                        clear_delegation_cancel(task_id)
                        update_agent_task(project_id, task_id, status="failed",
                                          fail_reason="用户已停止该委派任务（已停止）")
                        return {"ok": False, "task_id": task_id,
                                "error": f"子 Agent「{target_name}」任务已被用户停止。"}
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
                # TS-116（3.20③）：交卷报告回传 prompt_eval_count（主会话可显示"委派上下文用量"）
                _pe_final = _pe_final_box[0]
                if _pe_final:
                    report["prompt_eval_count"] = _pe_final
                report = _finalize_summary(project_id, task_id, report, _final_text)
                clear_delegation_cancel(task_id)  # TS-114：标志残留清理（防误伤后续重试）
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
