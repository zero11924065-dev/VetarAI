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
"""M1-2 tool-calling loop 引擎。

- run_tool_loop(): 模型发起 tool_call → execute(M1-1 工具) → 结果回注 → 模型继续，
  直到最终文本；max_rounds + 连续失败双保险熔断；yield SSE 事件 dict。
- build_system_prompt(): M1-3 红线区/身份/环境/工具说明，sandbox_root 与 network_switch 全从入参。
- authorizer 回调（2026-08-28 权限宽松化重构）：
      签名：await authorizer(tool_name, target_path, action) -> bool
      **loop 层不再每次调用前询问**（避免每个操作都弹窗骚扰用户）；
      authorizer 仅透传给 registry 层，由 registry 自行判定：
      仅"敏感系统位置的【删除】"才调用 authorizer 请求确认，
      读/写/建目录/列目录（含修改配置）一律默认放行。

## 异常类型 → 出口 对照表（M1-2 审核 DoD：Ollama 流中所有可抛异常必须有一处兜底转 error 事件）
| 异常来源 | 类型 | 兜底位置 | 出口 |
|---|---|---|---|
| 流中途 read/connect 超时 | httpx.TimeoutException | connector.chat_stream 内部 try/except | yield {"stream_error": ...} → loop 转 event: error |
| Ollama 业务错误(非200) | OllamaAPIError | connector._raise_stream_http | 由 app.py gen() except 捕获 → event: error |
| guard 拒绝 / 网络级 | NetworkGuardError | connector.guard / 请求发起 | app.py gen() except → event: error |
| 其他 HTTP 错误 | httpx.HTTPError | app.py gen() except | event: error |
| 客户端断开 | asyncio.CancelledError | app.py gen() except | 静默结束流（不再 yield） |
原则：connector 只兜底"流内超时"，业务/网络异常上抛；app.py gen() 是最终安全网，任何异常都转 event: error 后正常结束，禁止裸抛堆栈给客户端。
"""
from __future__ import annotations

import asyncio
import json
import re as _re
from datetime import datetime
from typing import Any, AsyncIterator, Callable

from sidecar.tools import execute as execute_tool

MAX_ROUNDS_DEFAULT = 200        # tool loop 轮次上限（默认值；实际由 config max_tool_rounds 覆盖，范围 1-1000）
CONSECUTIVE_FAIL_LIMIT = 2      # 连续 N 轮工具全部失败 → 熔断（协议常量）
COMPUTER_USE_MAX_STRIKES = 2    # 0.4.11：同一 Computer Use 动作连续失败 N 次 → 熔断该工具
                                # （真机事故：失败后模型无限重发，每次重试都弹确认窗，
                                #   用户连点十几二十个仍停不下来。截屏不计入——它只读无弹窗）
SEARCH_CIRCUIT_STOP = 1        # TS-105：web_search 返回 circuit_open=True → 立即停止（熔断器已确认重试无意义；任务单写 2 但实际时序导致第 1 次 False 第 2 次 True，strikes 永远到不了 2，故改为 1）
SUMMARY_MAX_CHARS = 200         # tool_result 摘要截断长度（协议常量）
HEARTBEAT_INTERVAL = 15.0       # SSE 空闲心跳间隔（M5 正式做，M1-2 占位）
# 0.4.9（3.47.3 委派模型换装）：⛔ 0.4.7 回退教训——卸载必须带独立超时，
# 且卸载前先查 /api/ps 确认模型确在内存（Ollama 对未加载模型会"先加载再卸载"）。
SWAP_TIMEOUT = 20.0             # 单次 unload_model 的独立超时上限（秒）；超时即放弃卸载，绝不阻塞委派
SWAP_PS_TIMEOUT = 8.0           # 卸载前查 /api/ps（已加载模型）的超时（秒）


# ── 0.4.9（3.47.1 单元归档）──────────────────────────────────────────────
ARCHIVE_MIN_MESSAGES = 4   # 防滥用：距上次归档点不足此条数则拒绝归档


def archive_work_unit(project_id: str, session_id: str, title: str, summary: str,
                      scope: str = "project") -> dict[str, Any]:
    """把一个已完成工作单元的对话打包移入知识仓库（复用 0.3.0 转移链路，不另写一套）。

    设计要点（需求文档 3.47.1）：
      - 【归档点自追踪】以"最后一条已归档消息"为上次归档点，打包其后全部未归档消息。
        无需额外状态字段——archived 标记本身就是归档点。
      - 【首条用户消息永不归档】它是任务总指令；保留它，Agent 才能始终看到总任务
        与剩余清单（批量处理多个案件时尤其关键，否则归档几次就忘了还有哪些没做）。
      - 【防滥用】候选消息 < ARCHIVE_MIN_MESSAGES 条时拒绝——避免模型每说两句就归档，
        把上下文切碎、反而丢失必要信息。
      - 【先落盘后归档】由调用方（提示词纪律）保证产出已写盘；本函数只负责搬移对话。

    返回 {"ok": True, "entry_id", "title", "archived", ...} 或 {"ok": False, "error": 原因}。
    提取为模块级纯同步函数以便单测直接覆盖（闭包不可测 = 防线盲区，见 safe_unload_model 注释）。
    """
    from sidecar.storage.store import load_messages, archive_messages
    from sidecar.knowledge import warehouse as _wh

    if not project_id or not session_id:
        return {"ok": False, "error": "缺少 project_id / session_id，无法归档"}
    title = str(title or "").strip()
    summary = str(summary or "").strip()
    if not title:
        return {"ok": False, "error": "archive_work_unit 需要 title（工作单元名称）"}

    msgs = load_messages(project_id, session_id) or []
    if not msgs:
        return {"ok": False, "error": "会话中还没有任何消息，无需归档"}

    # 首条用户消息的 id：永不归档（任务总指令）
    first_user_id = next((m.get("id") for m in msgs
                          if m.get("role") == "user" and str(m.get("content") or "").strip()),
                         None)

    # 上次归档点 = 最后一条已归档消息的位置；其后未归档的才是本次候选
    last_archived_idx = -1
    for i, m in enumerate(msgs):
        if m.get("archived"):
            last_archived_idx = i
    candidates = []
    for m in msgs[last_archived_idx + 1:]:
        if m.get("archived"):
            continue
        if first_user_id is not None and m.get("id") == first_user_id:
            continue                      # 首条用户消息永不归档
        if not str(m.get("content") or "").strip():
            continue                      # 空内容（如仅工具步骤的气泡）不进仓库
        candidates.append(m)

    if len(candidates) < ARCHIVE_MIN_MESSAGES:
        return {"ok": False, "error": (
            f"距上次归档点只有 {len(candidates)} 条消息（不足 {ARCHIVE_MIN_MESSAGES} 条），"
            "已拒绝归档。请在【一个工作单元真正完成、且产出已落盘】后再调用；"
            "频繁归档会把上下文切碎，反而丢失必要信息。")}

    # 组装正文（与 0.3.0 手动转移同构：角色: 内容）
    body_lines = [f"**单元摘要**：{summary}"] if summary else []
    for m in candidates:
        role = m.get("role", "?")
        content = str(m.get("content") or "").strip()
        if content:
            body_lines.append(f"**{role}**：{content}")
    body = "\n\n".join(body_lines)
    if not body.strip():
        return {"ok": False, "error": "候选消息无文本内容，未归档"}

    _wh.prune_missing()   # 外部删除对账（与既有端点一致，不返回幽灵条目）
    # source 复用 'chat'：warehouse 的 knowledge_entries.source 有 CHECK 约束
    # 只允许 ('chat','manual')，而该约束在建表时已固化——改 schema 需重建表迁移
    # （用户 index.db 已有数据，迁移有风险）。归档本质就是"把对话搬进仓库"，
    # 与 0.3.0 手动转移同源，故 source='chat' 语义正确；靠 category 区分来源。
    entry = _wh.add_entry(scope, project_id if scope == "project" else None,
                          title, body, category="工作单元归档",
                          keywords=[title], source="chat")
    if entry is None:
        return {"ok": False, "error": "知识条目写入失败（知识库目录不可用），本次未归档"}

    ids = [m.get("id") for m in candidates if m.get("id") is not None]
    archived = archive_messages(project_id, ids)
    return {"ok": True, "entry_id": entry.get("id"), "title": title,
            "file_path": entry.get("file_path"), "archived": archived,
            "kept_first_user_message": first_user_id is not None,
            "note": "本单元对话已移入知识仓库并脱离上下文；需要时可用 search_knowledge 搜回。"}


async def safe_unload_model(conn: Any, model: str) -> bool:
    """0.4.9（3.47.3）安全卸载模型——⛔ 0.4.7 回退教训的两条防护都在这里。

    防护①：卸载与查 ps 各自带独立超时（SWAP_TIMEOUT / SWAP_PS_TIMEOUT）。超时即放弃卸载
            继续走，绝不阻塞委派主流程（0.4.7 两处 unload 在活性超时守卫之外，
            一旦变慢无人能中断 → 批量委派无限期挂住）。
    防护②：卸载前先查 /api/ps 确认模型【确在内存】。Ollama 的 keep_alive=0 对未加载模型
            会"先加载再卸载"，盲卸等于白白触发一次完整加载（0.4.7 批量委派卡顿主因之一）。
    兼容带/不带 tag 的模型名（"glm-ocr" 命中 "glm-ocr:latest"）。
    任何失败一律静默返回 False（卸载只是内存优化，不得影响委派成败）。
    提取为模块级函数以便单测直接覆盖（闭包无法测 = 防线上的测试盲区）。
    """
    if not model or conn is None:
        return False
    try:
        loaded = await asyncio.wait_for(conn.list_loaded_models(), timeout=SWAP_PS_TIMEOUT)
    except Exception:
        return False
    if model not in loaded and not any(
            x == model or str(x).split(":")[0] == model.split(":")[0] for x in loaded):
        return False   # 防护②：不在内存 → 跳过，不触发加载
    try:
        return bool(await asyncio.wait_for(conn.unload_model(model), timeout=SWAP_TIMEOUT))
    except Exception:
        return False   # 防护①：超时/异常即放弃，不阻塞

Authorizer = Callable[..., Any]  # async (tool_name, target_path, action) -> bool


# ---------- 工具 spec（Ollama OpenAI 风格 tools 参数） ----------
def tools_spec(with_delegation: bool = True, with_knowledge: bool = False,
               with_install: bool = True, with_archive: bool = False,
               with_app_control: bool = False,
               with_computer_use: bool = False) -> list[dict[str, Any]]:
    """工具规格列表。with_delegation=False 时剔除 delegate_task（子会话防递归委派）。
    read_skill 两态均含；单个技能的启用/禁用为逐项状态（技能清单只列启用项，
    read_skill 路由对禁用项返回"已禁用"提示，见 checkpoint-047）。
    TS-120 阶段二：with_knowledge=True 时附加 search_knowledge（知识仓库主动检索，拉模式）。
    0.4.9 F2：with_install=False 时剔除 install_plugin/install_skill——子 Agent 不得有联网
    安装权（用户实测事故：子 Agent 拿到"使用某技能"的任务书后擅自调 install_skill 去 GitHub
    拉取，触发 git 凭据弹窗并装入两个无关插件目录）。安装权只留主 Agent，且调用时需用户确认。"""
    spec = [
        {
            "type": "function",
            "function": {
                "name": "list_dir",
                "description": "列出目录下的文件与目录。",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "目录路径（相对工作目录或绝对路径），缺省为工作目录本身"}},
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "读取文件的文本内容（超过 1MB 会截断并标记）。"
                               "读取图片文件（.png/.jpg/.jpeg/.gif/.webp/.bmp/.heic 等）时，"
                               "图片会自动转换为图像输入注入你的视觉上下文，你可以直接描述/识别图片内容（无需 OCR 工具）。",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "文件路径（相对工作目录或绝对路径）"}},
                    "required": ["path"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "write_file",
                "description": "把文本内容写入文件（自动创建父目录，覆盖已有文件）。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "文件路径（相对工作目录或绝对路径）"},
                        "content": {"type": "string", "description": "要写入的文本内容"},
                    },
                    "required": ["path", "content"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "create_dir",
                "description": "创建目录（自动创建父目录）。",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "目录路径（相对工作目录或绝对路径）"}},
                    "required": ["path"],
                },
            },
        },
        {
            # 0.4.6：Office 文档生成（内置）。生成真实的 Word/Excel/PPT/Markdown 文件。
            "type": "function",
            "function": {
                "name": "create_document",
                "description": "生成 Word(.docx) / Excel(.xlsx) / PowerPoint(.pptx) / Markdown(.md) 文档文件。"
                               "当用户要求输出报告、表格、幻灯片等正式文档时使用本工具（而非 write_file 纯文本）。"
                               "docx 默认 A4 竖版、宋体、页脚自动页码「第X页 共Y页」（page_number 默认开启）。"
                               "content 必须是结构化 JSON："
                               "docx/md 用 {title, blocks:[{type:'heading',level,text}|{type:'paragraph',text}|{type:'bullets',items:[..]}|{type:'table',rows:[[..],..]}|{type:'page_break'}|{type:'image',layout:'single'|'grid',paths:[..],width_cm,caption}]}；"
                               "image 块：layout='single' 单图/多张原文居中（身份证/合同等），"
                               "layout='grid' 一行3列网格（聊天截图等并排）；"
                               "page_break 表示分页（证据文档每份证据独立起页时用）；"
                               "xlsx 用 {sheets:[{name, rows:[[单元格,..],..]}]}；"
                               "pptx 用 {slides:[{title, bullets:[..], notes}]}.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "保存路径含扩展名（如 报告.docx / 数据.xlsx / 幻灯片.pptx / 总结.md）"},
                        "doc_type": {"type": "string", "description": "文档类型 docx/xlsx/pptx/md（默认从扩展名推断，可省略）"},
                        "content": {"type": "object", "description": "结构化内容（按上方契约填写，对象而非字符串）"},
                    },
                    "required": ["path", "content"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "delete_path",
                "description": "删除文件或目录（目录会递归删除）。涉及系统敏感位置时会请求用户确认。",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "要删除的文件或目录路径（相对工作目录或绝对路径）"}},
                    "required": ["path"],
                },
            },
        },
        {
            # TS-104 R01：联网搜索（实时信息：天气/新闻/价格等；出站过网络开关）
            "type": "function",
            "function": {
                "name": "web_search",
                "description": "联网搜索实时信息（天气、新闻、价格、事实查询等）。"
                               "网络开关关闭且域名未放行时会返回拒绝，此时应如实告知用户。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "搜索关键词"},
                        "max_results": {"type": "integer", "description": "返回条数（默认5，上限10）"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            # TS-110 M4：按需读取技能指令（清单在系统提示，正文按需读取，不全量注入）
            "type": "function",
            "function": {
                "name": "read_skill",
                "description": "读取指定技能（Skill）的完整指令内容。仅当【可用技能】清单中的某个技能"
                               "与当前任务相关、且你需要其详细执行指令时调用。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "技能名（见【可用技能】清单）"},
                    },
                    "required": ["name"],
                },
            },
        },
        {
            # checkpoint-066：对话内安装插件（装完在 设置→插件管理 可见）
            "type": "function",
            "function": {
                "name": "install_plugin",
                "description": "安装一个插件（Plugin）到应用中。用户要求安装插件时使用。"
                               "插件仓库需含 manifest.json；安装成功后可在 设置→插件管理 中查看与管理。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "source": {"type": "string",
                                   "description": "GitHub 仓库 URL（如 https://github.com/owner/repo）"
                                                  "或本地插件目录的绝对路径"},
                    },
                    "required": ["source"],
                },
            },
        },
        {
            # checkpoint-066：对话内安装技能（装完在 设置→技能 可见）
            "type": "function",
            "function": {
                "name": "install_skill",
                "description": "安装一个技能（Skill）到应用中。用户要求安装技能时使用。"
                               "技能目录需含 SKILL.md；安装成功后可在 设置→技能 中查看与管理。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "source": {"type": "string",
                                   "description": "git 仓库 URL 或含 SKILL.md 的本地目录绝对路径"},
                    },
                    "required": ["source"],
                },
            },
        },
    ]
    if with_delegation:
        spec.append({
            # TS-107 M3-1：主-子委派（决策 8）。子会话通过 with_delegation=False 拿不到此工具
            "type": "function",
            "function": {
                "name": "delegate_task",
                "description": "把一个子任务委派给项目内的另一个 Agent 独立完成。只在你判断任务需要分工时使用。"
                               "子 Agent 看不到当前对话历史，任务书必须自包含（目标+必要输入+预期产出）。"
                               "你本条消息附着的图片会自动随委派传给子 Agent，无需自己读取或描述图片内容；"
                               "任务书直接写“识别附图”即可。若图片在文件夹中，用 image_paths 传入路径列表。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "target": {"type": "string", "description": "目标 Agent 的名称或 ID"},
                        "task": {"type": "string", "description": "任务书：目标、背景、输入材料，必须自包含"},
                        "expect": {"type": "string", "description": "交卷标准：期望子 Agent 产出什么"},
                        "suggested_role": {"type": "string",
                                           "description": "目标 Agent 不存在时，按此角色自动新建子 Agent 并执行"
                                                          "（如'数据分析师'）。可不填，不填时直接用 target 名称新建。"},
                        "image_paths": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "要随委派传给子 Agent 的图片文件路径列表（相对沙盒根或绝对路径，如 'images/a.png'）。"
                                           "适用场景：批量图片识别/转写等。不填时仅传聊天附着图。",
                        },
                        "simple_mode": {
                            "type": "boolean",
                            "description": "简单委派模式：子 Agent 直接输出结果本身，不要求 JSON 交卷、不追问重交。"
                                           "带图委派会自动启用，无需填写；仅当无图但任务属于纯产出型"
                                           "（如逐字转写、摘录，目标为不擅长 JSON 的小模型）时可显式传 true。",
                        },
                        "model": {
                            "type": "string",
                            "description": "3.47.2 委派模型自选：指定子任务用哪个本地模型运行"
                                           "（如图片识别选视觉/OCR 专用小模型，长文推理选大模型）。"
                                           "参考系统提示词【可用模型及特长】段落按特长选择；未列出或不填时，"
                                           "自动新建的子 Agent 用你的当前模型，复用已有子 Agent 时则沿用其自身模型。"
                                           "填了不存在的模型名会被拒绝并列出可用模型。",
                        },
                    },
                    "required": ["target", "task", "expect"],
                },
            },
        })
    if with_knowledge:
        spec.append({
            # TS-120 阶段二：知识仓库主动检索（拉模式）。仅当用户明确要求检索
            # 或任务必须引用历史知识时才调用；检索结果作为工具返回，本轮用完即弃，
            # 不写入会话上下文（读完即忘），不自动注入。
            "type": "function",
            "function": {
                "name": "search_knowledge",
                "description": "检索本地知识仓库（拉模式）。仅当用户明确要求你检索知识库，"
                               "或当前任务必须引用此前沉淀的知识/对话时才调用。"
                               "支持关键词与语义（理解近义/换述）混合检索。"
                               "检索结果仅本轮可见，不会持久写入对话上下文。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "检索词或自然语言描述（支持换述）"},
                        "scope": {"type": "string",
                                  "description": "检索范围：project=仅本项目 / global=仅全局 / 留空=两者",
                                  "enum": ["project", "global", "all"]},
                        "mode": {"type": "string",
                                 "description": "检索模式：hybrid=关键词+语义融合(默认) / keyword=仅关键词 / semantic=仅语义",
                                 "enum": ["hybrid", "keyword", "semantic"]},
                        "limit": {"type": "integer", "description": "返回条数上限，默认 5", "default": 5},
                    },
                    "required": ["query"],
                },
            },
        })
    if with_archive:
        spec.append({
            # 0.4.9（3.47.1 单元归档）：仅当会话窗开关开启时才暴露本工具（关闭时零开销）。
            "type": "function",
            "function": {
                "name": "archive_work_unit",
                "description": "把【已完成的一个工作单元】的对话移入知识仓库，脱离后续上下文"
                               "（用于批量任务：每完成一个单元就归档一次，防止上下文无限膨胀）。"
                               "调用前提（必须全部满足）：①该单元的任务确实已完成；"
                               "②该单元的产出文件已真实落盘（先用 list_dir 确认）。"
                               "系统会自动打包【上次归档点之后】的消息，并保留会话第一条用户消息"
                               "（任务总指令）永不归档，因此你始终能看到总任务与剩余清单。"
                               "距上次归档不足 4 条消息时会被拒绝（防滥用）。"
                               "归档后内容仍可用 search_knowledge 搜回。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string",
                                  "description": "该工作单元的名称（如'《赵兴柱诉刘禄九》案情分析'），"
                                                 "会作为知识条目标题，便于日后检索"},
                        "summary": {"type": "string",
                                    "description": "一句话说明本单元完成了什么、产出在哪个文件"},
                    },
                    "required": ["title", "summary"],
                },
            },
        })
    if with_app_control:
        spec.append({
            # 0.4.9（3.48.2 应用内模块控制）：仅当开关开启时暴露。
            # 注册表在 sidecar/app_modules/registry.py——新模块登记一条即自动可调。
            "type": "function",
            "function": {
                "name": "app_control",
                "description": "调用应用内模块完成结构化任务（工作流 / 知识仓库 / 圆桌）。"
                               "适用场景：需要跑一个确定性流程（如批量识图用工作流，比逐个委派更快更稳）、"
                               "查历史沉淀的知识、发起多 Agent 圆桌会诊。"
                               "调用前先看系统提示词【可用应用模块动作】清单确认模块与动作名。"
                               "低成本动作（查询/检索）直接执行；高成本动作（运行工作流、创建圆桌）"
                               "会先弹窗请用户确认。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "module": {"type": "string",
                                   "description": "模块名，见【可用应用模块动作】清单（如 workflow / knowledge / roundtable）"},
                        "action": {"type": "string",
                                   "description": "动作名（如 list / run / get_runs / search / inject / groups / create）"},
                        "params": {"type": "object",
                                   "description": "该动作的参数对象，字段见清单中各动作说明"},
                    },
                    "required": ["module", "action"],
                },
            },
        })
    if with_computer_use:
        # 0.4.9（3.48.1 Computer Use 一期 MVP）：仅当总开关开启时暴露。
        # ⚠️ 这些工具直接操作用户真实电脑，误操作后果可见（删文件/发消息/点支付），
        # 故路由层强制：白名单校验 + 每步确认（见 computer_use_ctx 分支）。
        spec.extend([
            {
                "type": "function",
                "function": {
                    "name": "screen_view",
                    "description": "截取当前屏幕，图片会进入你的视觉上下文，你可以直接看到屏幕内容。"
                                   "每次要点击或输入之前，都应先截屏看清当前界面（界面会变，别凭记忆操作）。"
                                   "返回结果含 coord_factor：你从图上看到的坐标是【图片像素坐标】，"
                                   "调用 mouse_click 时必须先乘以 coord_factor 换算成屏幕坐标，否则会点偏。",
                    "parameters": {"type": "object", "properties": {}},
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "mouse_click",
                    "description": "在屏幕坐标点击。坐标必须是【逻辑点】——即用 screen_view 看到的像素坐标"
                                   "乘以 coord_factor 换算后的值。执行前会请用户确认。",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "x": {"type": "number", "description": "横坐标（逻辑点，已乘 coord_factor）"},
                            "y": {"type": "number", "description": "纵坐标（逻辑点，已乘 coord_factor）"},
                            "button": {"type": "string", "enum": ["left", "right"],
                                       "description": "鼠标键，默认 left"},
                            "clicks": {"type": "integer", "enum": [1, 2],
                                       "description": "1=单击（默认），2=双击"},
                        },
                        "required": ["x", "y"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "keyboard_type",
                    "description": "在当前焦点处输入文本（支持中文与符号，单次上限 2000 字符）。"
                                   "执行前会请用户确认。输入前请确保目标输入框已获得焦点（先点击它）。",
                    "parameters": {
                        "type": "object",
                        "properties": {"text": {"type": "string", "description": "要输入的文本"}},
                        "required": ["text"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "keyboard_hotkey",
                    "description": "按下按键或组合键，如 'return'、'cmd+c'、'cmd+shift+4'、'esc'。"
                                   "执行前会请用户确认。",
                    "parameters": {
                        "type": "object",
                        "properties": {"keys": {"type": "string",
                                                "description": "按键名，组合键用 + 连接（如 cmd+c）"}},
                        "required": ["keys"],
                    },
                },
            },
        ])
    # 0.4.9 F2：子 Agent（with_install=False）剔除联网安装工具，杜绝擅自 git clone。
    # 默认 True 保持主 Agent 行为不变（现有测试断言主会话共 10 工具仍成立）。
    if not with_install:
        spec = [s for s in spec
                if s.get("function", {}).get("name") not in ("install_plugin", "install_skill")]
    return spec


# ---------- M1-3 system prompt ----------
def build_system_prompt(
    agent_name: str,
    agent_role: str | None,
    sandbox_root: str,
    network_switch: str,
    current_time: str | None = None,
    system_prompt: str | None = None,
    can_delegate: bool = False,
    knowledge_text: str = "",
    memory_text: str = "",
    prohibitions: list[str] | None = None,
    skills_list_text: str = "",
    model_strengths_text: str = "",
    archive_enabled: bool = False,
    module_catalog_text: str = "",
) -> str:
    """按需求顺序拼装：红线区 → 身份 → 环境 → 工具说明（+委派纪律）。零硬编码（全从入参）。
    M4（TS-110）：新增知识/记忆/技能注入（禁止事项并入红线区，100% 拦截；优先级 记忆>知识）。
    0.4.9（3.47.2）：model_strengths_text 非空时注入【可用模型及特长】，供委派时按画像自选模型。"""
    ts = current_time or datetime.now().strftime("%Y-%m-%d %H:%M")
    # 2026-08-28 融合方案：三态网络模式（auto/proxy，旧值 on→proxy / off→auto）
    raw = str(network_switch).upper()
    mode = "proxy" if raw in ("ON", "PROXY", "1", "TRUE") else "auto"
    if mode == "proxy":
        net = "走代理模式：境内直连，境外经代理访问"
    else:
        net = "自动探测模式：境内直连；境外访问失败时系统会自动切换策略并提示"
    role_part = f"角色：{agent_role}。" if agent_role else ""
    sp_part = f"\n补充设定：{system_prompt}" if system_prompt else ""
    # M4：用户禁止事项并入红线区（3.14：禁止事项 100% 拦截）
    redline = "【禁止事项】不得执行未授权操作。"
    if prohibitions:
        redline += "\n用户设定的禁止事项（必须严格遵守，违反即错误）：\n" + \
            "\n".join(f"- {p}" for p in prohibitions[:20])
    base = (
        f"{redline}\n"
        f"你是 {agent_name}，{role_part}{sp_part}\n"
        f"工作目录：{sandbox_root}。当前时间：{ts}。网络模式：{net}。\n"
        "你可通过工具读写文件（list_dir/read_file/write_file/create_dir/delete_path）。"
        "工作目录是默认的读写锚点，但你可以在用户需要时操作其他目录或修改配置文件，无需预先询问；"
        "对系统敏感位置（系统目录、~/.ssh、应用数据目录等）的写入/删除，系统会向你请求确认；其余位置操作不受限。\n"
        "需要实时信息（天气/新闻/价格等）时使用 web_search 工具（内置多源自动降级，会自行切换搜索源）。\n"
        "【搜索纪律】每个问题最多搜索 1-2 次，且不得用相同/近似关键词重复搜索；"
        "拿到搜索结果后立即整理回答，不要反复调用工具；"
        '若工具返回含“已熔断”字样，表示境外源已被系统熔断，禁止再次调用 web_search，'
        "直接向用户说明原因与恢复方法（启动代理 + 切走代理模式）；"
        "搜索结果不理想时，换个不同角度的关键词再搜一次，仍不理想就直接基于已有信息回答并说明局限。\n"
        "【重要】不要根据网络状态预判拒绝——用户询问实时信息时直接调用 web_search，以工具返回为准。"
        "工具返回结构化 JSON，ok=false 时按 error 字段处理。"
    )
    # M4：记忆（优先级高于知识）→ 知识库 → 技能清单（仅启用项；正文按需 read_skill）
    if memory_text:
        base += "\n【长期记忆】（用户沉淀的持久信息，请牢记并遵循）\n" + memory_text
    if knowledge_text:
        base += ("\n【项目知识库】（本项目的参考资料；与【长期记忆】冲突时，以记忆为准）\n"
                 + knowledge_text)
    if skills_list_text:
        base += ("\n【可用技能】（以下技能可按需使用；需要某技能的详细指令时，"
                 "调用 read_skill 工具，参数 name 填技能名）\n" + skills_list_text)
    # 0.4.9（3.48.2）：应用内模块动作清单——仅当设置开关开启时注入（关闭时零开销）
    if module_catalog_text:
        base += ("\n【可用应用模块动作】（用 app_control 工具调用：module=模块名, action=动作名, "
                 "params=参数对象。低成本查询类直接执行；运行工作流、创建圆桌等高成本动作"
                 "会先请用户确认，被拒绝时不要重试）\n" + module_catalog_text)
    # 0.4.9（3.47.1）：单元归档纪律——仅当会话窗开关开启时注入（关闭时工具不存在，零开销）
    if archive_enabled:
        base += (
            "\n【单元归档纪律】（本会话已开启「单元归档」）\n"
            "- 批量任务（如一次处理多个案件/多个文件夹）中，每【真正完成一个工作单元】、"
            "且该单元的产出文件【已确认真实落盘】（先用 list_dir 核对）后，"
            "调用 archive_work_unit(title=单元名, summary=一句话说明产出与文件位置)，"
            "把这段对话移入知识仓库，防止上下文无限膨胀拖慢后续推理。\n"
            "- 【禁止】单元未完成、产出未落盘、或只是中间步骤时就归档——"
            "归档会脱离上下文，过早归档会丢失必要信息导致后续出错。\n"
            "- 会话第一条用户消息（任务总指令）系统会自动保留、永不归档，"
            "因此你始终能看到总任务与剩余清单；距上次归档不足 4 条消息时系统会拒绝归档。\n"
            "- 归档后如需回看，用 search_knowledge 搜回（拉模式，不会自动注入）。\n"
            "- 单个任务（非批量）无需归档，正常完成即可。"
        )
    # 0.4.9（3.47.2）：模型特长画像——仅当用户配置了画像且可委派时注入。
    # 放在委派纪律之前，让模型先知道"有哪些模型、各自擅长什么"，再看委派规则。
    if can_delegate and model_strengths_text:
        base += ("\n【可用模型及特长】（委派子任务时可用 delegate_task 的 model 参数按特长选择；"
                 "未列出的模型也可用，但无特长说明）\n" + model_strengths_text)
    if can_delegate:
        base += (
            "\n【委派纪律】\n"
            "- 【强制】用户消息含\"让XX/请XX/派XX/叫XX/安排XX 做某事\"（XX 为任意名称或角色，"
            "如'人事专员'）时，必须先调用 delegate_task 委派给 XX（不存在时系统会自动新建），"
            "不得自己直接做该事、不得自己搜索后代答、更不得在未调用 delegate_task 的情况下"
            "把回答描述成'已派XX查询'。\n"
            "- 【串行约束】同一时间只委派一个子任务，等前一个交卷后再委派下一个"
            "（本机性能受限，同时只跑 1 个大模型）。\n"
            "- 需要分工时用 delegate_task 委派：任务书必须自包含，子 Agent 看不到本对话历史，"
            "目标/输入/预期产出都要写进任务书。\n"
            "- 【target 必填】委派必须写明 target（目标 Agent 名称）。调用失败提示缺参时，"
            "按返回的可用 Agent 名单补填 target 后重新调用，不要凭空编造目标。\n"
            "- 委派目标可以是项目内已有的 Agent；若目标不存在，系统会按建议角色"
            "（不填则按目标名称）自动新建子 Agent 并执行，无需先询问用户。\n"
            "- 子 Agent 交卷一般是固定 JSON（task_id/status/summary/artifacts）；"
            "但带图委派（识别/转写）自动启用简单模式：子 Agent 直接返回内容本身，"
            "没有 JSON 外壳，你直接采用其返回内容即可。你负责整合各交卷，"
            "最终回复中标注每部分来自哪个子 Agent。\n"
            "- 交卷标记异常（ok=false）时，如实告知用户哪个子任务缺失及原因，不要虚构其产出。\n"
            "- 【强制】委派失败/交卷异常后，禁止你自己重新搜索或亲自完成该子任务来代答"
            "（那会让委派失去意义，且你已看不到子 Agent 的中间过程）。正确做法：向用户说明"
            "失败原因，建议重试该子任务或调整任务书后再委派一次。\n"
            "- 【图片传递】你附着在消息里的图片会自动随 delegate_task 传给子 Agent（每轮都在），"
            "不要声称“无法把图片发给子 Agent”；任务书里直接引用附图（如“将附图逐张转写为文字”）。"
            "若图片在文件夹中（不在聊天里），先用 list_dir 拿到清单，再通过 image_paths 参数"
            "把图片路径列表传入，子 Agent 将直接看到图片，无需自己逐张 read_file。\n"
            "- 不要委派自己，也不要把整个任务原样转丢给子 Agent。"
        )
    return base


# ---------- 内部：执行一个工具（authorizer 三元组签名） ----------
async def _run_tool(name: str, args: dict, sandbox_root: str, authorizer: Authorizer | None):
    return await execute_tool(name, args or {}, sandbox_root, authorizer)


def _normalize_query(q: str) -> str:
    """搜索关键词归一化（用于去重判定）：去首尾空白、压缩连续空白、转小写。"""
    return _re.sub(r"\s+", " ", str(q)).strip().lower()


# TS-117（3.31 任务2）：委派图片直传——读取 image_paths 图片转 base64 data URI。
_MIME_BY_EXT = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".webp": "image/webp", ".gif": "image/gif", ".bmp": "image/bmp"}
_MAX_DELEGATION_IMAGES = 50      # 上限：最多 50 张（任务单 2.2）
_MAX_DELEGATION_IMAGE_MB = 10    # 单张 ≤10MB（与聊天附件上限一致，需求文档 3.20②）


def _load_delegation_images(image_paths: list, sandbox_root: str) -> tuple[list[str], list[str]]:
    """读取图片路径列表 → (data URI 列表, 跳过的路径列表)。

    复用 sidecar/tools/registry.py 的路径自纠正逻辑（resolve_sandboxed_path，
    checkpoint-069 F-1），不新写一套。规则：
    - 路径解析失败/不存在/非图片扩展名 → 跳过该张（不阻塞整体）
    - 单张 >10MB → 跳过；总数 >50 → 只取前 50
    - 读文件 → data:image/<mime>;base64, URI
    - 0.4.9 F3：裸文件名在工作目录下唯一命中时自动采用（见下方注释）
    单张失败不阻塞：部分成功即传，调用方据返回值报告 loaded / skipped。
    """
    import base64 as _b64
    from pathlib import Path as _Path
    from sidecar.tools.registry import resolve_sandboxed_path

    loaded: list[str] = []
    skipped: list[str] = []
    paths = [p for p in (image_paths or []) if isinstance(p, str) and p.strip()]

    # 0.4.9 F3：裸文件名自纠正索引（basename → 命中路径列表）。
    # 模型常只写 "1.jpg"，而图片实际在子目录（如 <案件目录>/证据/1.jpg）；按 sandbox_root
    # 直接解析必然落空 → 整批被跳过 → 子 Agent 一张图都收不到 → 只能编造识别结果
    # （用户实测事故：编造出根本不存在的金额、日期与法条）。
    # 索引一次性构建、全批复用——避免每个文件名都触发一次全盘 rglob
    # （用户场景：单案件目录可达上百 MB / 数十文件，逐个扫描会显著拖慢）。
    _name_index: dict[str, list] = {}
    _index_built = False

    def _build_index() -> None:
        nonlocal _index_built
        if _index_built:
            return
        _index_built = True
        try:
            for h in _Path(sandbox_root).expanduser().rglob("*"):
                try:
                    if h.is_file():
                        _name_index.setdefault(h.name, []).append(h)
                except OSError:
                    continue
        except (OSError, RuntimeError):
            pass

    for rel in paths[:_MAX_DELEGATION_IMAGES]:
        resolved = resolve_sandboxed_path(rel.strip(), sandbox_root)
        if (resolved is None or not resolved.is_file()) and not _Path(rel.strip()).is_absolute():
            _build_index()
            # 唯一命中才采用；多处同名不猜（避免拿错图），仍标记跳过
            _hits = _name_index.get(_Path(rel.strip()).name) or []
            if len(_hits) == 1:
                resolved = _hits[0]
        if resolved is None or not resolved.exists() or not resolved.is_file():
            skipped.append(rel)
            continue
        ext = resolved.suffix.lower()
        mime = _MIME_BY_EXT.get(ext)
        if mime is None:
            skipped.append(rel)  # 非图片扩展名
            continue
        if resolved.stat().st_size > _MAX_DELEGATION_IMAGE_MB * 1024 * 1024:
            skipped.append(rel)  # 超限
            continue
        try:
            b64 = _b64.b64encode(resolved.read_bytes()).decode("ascii")
            loaded.append(f"data:{mime};base64,{b64}")
        except (OSError, RuntimeError):
            skipped.append(rel)
    if len(paths) > _MAX_DELEGATION_IMAGES:
        skipped.extend(paths[_MAX_DELEGATION_IMAGES:])  # 超 50 张的部分标记跳过
    return loaded, skipped


def _real_images_hint(sandbox_root: str, limit: int = 30) -> str:
    """0.4.9 F1：列出工作目录下真实存在的图片（绝对路径），供报错时给模型自纠正。

    模型常编造/写错 image_paths（如只写裸文件名、或臆造 1.jpg 这类不存在的名字）。
    把真实清单直接塞进错误文本，模型下一轮就能照抄正确路径，无需再猜。
    上限 limit 张，超出只提示总数（避免错误文本本身撑爆上下文）。
    """
    from pathlib import Path as _P
    try:
        root = _P(sandbox_root).expanduser()
        hits = sorted(
            (h for h in root.rglob("*")
             if h.is_file() and h.suffix.lower() in _MIME_BY_EXT),
            key=lambda x: str(x))
    except (OSError, RuntimeError):
        return "（无法列出工作目录）"
    if not hits:
        return f"（工作目录 {root} 下未找到任何图片文件）"
    shown = hits[:limit]
    lines = "\n".join(f"  - {h}" for h in shown)
    more = f"\n  …（另有 {len(hits) - len(shown)} 张未列出，可 list_dir 查看）" if len(hits) > limit else ""
    return f"\n共 {len(hits)} 张：\n{lines}{more}"


# ── 0.4.9 任务161：报错必带原因 + 低等模型自动切默认模型做报错分析 ──────────
# 用户实测痛点：错误只说"连续工具失败，已停止。请检查指令或工作目录权限"，
# 不说【哪个工具】【什么参数】【真实错误是什么】，用户无从判断；而低等/专用小模型
# （如 OCR 模型）本身不具备分析能力，更说不清。故：
#   1) 所有终止性错误必须附【失败明细】：工具名 + 关键参数 + 真实错误文本
#   2) 再交由用户在设置里指定的【报错分析模型】给出一句话人话诊断
#      （分析失败/未配置/超时 → 静默降级，只给失败明细，绝不因分析失败而丢原始错误）
_ERROR_ANALYSIS_TIMEOUT = 60.0


def _collect_failure_detail(tool_calls_log: list[dict], max_items: int = 6) -> str:
    """汇总本次运行中失败的工具调用明细（工具名 + 参数 + 真实错误），按时间倒序取最近 N 条。"""
    fails = [e for e in (tool_calls_log or []) if not e.get("ok")]
    if not fails:
        return ""
    out = []
    for e in fails[-max_items:]:
        args = e.get("args") or {}
        # 参数摘要：只取关键标识字段，避免超长（如 content 全文）
        brief = ", ".join(f"{k}={str(v)[:60]}" for k, v in list(args.items())[:4]) or "（无参数）"
        out.append(f"  · {e.get('name','?')}({brief}) → {str(e.get('error','未知错误'))[:300]}")
    total = f"（共 {len(fails)} 次失败，列出最近 {min(len(fails), max_items)} 次）" if len(fails) > max_items else ""
    return "\n".join(out) + total


async def _analyze_error(reason: str, failure_detail: str, model: str,
                         connector: Any = None) -> str:
    """调用【报错分析模型】把技术性错误翻译成人话诊断 + 下一步建议。

    - model 为空 → 返回空串（未配置，不分析）
    - 任何异常/超时 → 返回空串（静默降级；绝不因分析失败影响原始错误呈现）
    - 与出错模型解耦：出错的是低等/专用小模型时，这里用用户指定的更强模型分析
    """
    if not model or not connector:
        return ""
    if not (reason or failure_detail):
        return ""
    prompt = (
        "你是错误诊断助手。下面是本地 AI 应用运行时的一次失败，请用【不超过 3 句话】的简体中文，"
        "先说最可能的根本原因，再给用户一条最该做的下一步动作。"
        "不要复述错误原文，不要编造不存在的信息，不确定就说不确定。\n\n"
        f"【失败原因】\n{reason}\n\n【失败明细】\n{failure_detail or '（无工具调用记录）'}"
    )
    try:
        import asyncio as _aio
        text = await _aio.wait_for(
            connector.chat(model, [{"role": "user", "content": prompt}]),
            timeout=_ERROR_ANALYSIS_TIMEOUT)
        return (text or "").strip()[:600]
    except Exception:
        return ""


def _resolve_error_analysis_model() -> str:
    """读取用户设置的报错分析模型；未配置时回落到默认模型（而非当前出错模型）。"""
    try:
        import sidecar.config as _cfg
        c = _cfg.get_config()
        m = str(c.get("error_analysis_model") or "").strip()
        if m:
            return m
        return str(c.get("default_model") or "").strip()
    except Exception:
        return ""


async def _build_error_payload(reason: str, tool_calls_log: list[dict],
                               connector: Any = None) -> dict:
    """组装终止性 error 事件的 data：detail（原因+失败明细）+ analysis（人话诊断）。

    前端据 analysis 是否存在决定是否渲染"诊断"块。detail 永远含真实原因，
    保证即使分析未配置/失败，用户也看得到"为什么错"。
    """
    detail_part = _collect_failure_detail(tool_calls_log)
    detail = reason + (f"\n\n【失败明细】\n{detail_part}" if detail_part else "")
    analysis = await _analyze_error(reason, detail_part,
                                    _resolve_error_analysis_model(), connector)
    payload: dict[str, Any] = {"detail": detail}
    if analysis:
        payload["analysis"] = analysis
        payload["analysis_model"] = _resolve_error_analysis_model()
    return payload


def _summarize(result: dict) -> str:
    """tool_result 摘要：截断 200 字，非完整 content。"""
    if result.get("ok"):
        if result.get("_kind") == "read_skill":
            # TS-110 M4：技能读取 → 摘要显示描述（正文太长不进摘要，完整内容已回注模型）
            body = f"已加载技能「{result.get('name', '')}」：{result.get('description', '')}"
        elif result.get("_kind") == "image":
            # checkpoint-067 R-4：图片 → 已转为图像输入（前端显示更直观）
            body = f"已读取图片 {result.get('size', 0)} 字节，已转为图像输入"
        elif "content" in result:
            body = f"已读取 {result.get('size', 0)} 字节" + ("（已截断）" if result.get("truncated") else "")
        elif "entries" in result:
            body = f"{len(result['entries'])} 个条目"
        elif "summary" in result:
            # TS-107 M3-1：委派结果展示子任务摘要与状态
            body = f"[{result.get('status', 'done')}] {result.get('summary', '')}"
        else:
            body = str(result.get("path") or result.get("bytes") or "ok")
    else:
        body = str(result.get("error", "unknown"))
    s = str(body)
    return s if len(s) <= SUMMARY_MAX_CHARS else s[:SUMMARY_MAX_CHARS] + "…"


# ---------- tool loop 主引擎 ----------
async def run_tool_loop(
    model: str,
    messages: list[dict[str, Any]],
    tools_spec_list: list[dict[str, Any]],
    sandbox_root: str,
    authorizer: Authorizer | None = None,
    max_rounds: int = MAX_ROUNDS_DEFAULT,
    context_limit: int = 0,
    connector: Any = None,
    delegation_ctx: dict | None = None,
    first_round_images: list[str] | None = None,
    cancel_check: Callable[[], bool] | None = None,
    knowledge_ctx: dict | None = None,
    archive_ctx: dict | None = None,
    app_control_ctx: dict | None = None,
    computer_use_ctx: dict | None = None,
) -> AsyncIterator[dict]:
    """tool-calling 循环。yield 事件 dict（与 SSE event 一一对应）：
      token / tool_call / tool_result / state / done / error
    熔断双保险：轮次上限 + 连续 CONSECUTIVE_FAIL_LIMIT 轮工具全部失败。
    delegation_ctx（TS-107 M3-1）：主会话传 {"project_id","agent_id","session_id","connector"}，
    此时 delegate_task 路由到委派执行器；None 时不允许委派（子会话双保险）。
    knowledge_ctx（TS-120 阶段二）：{"project_id": ...}，启用 search_knowledge 路由；
    None 时该工具调用直接报错（规格层本就不附加）。
    archive_ctx（0.4.9 3.47.1）：{"project_id", "session_id"}，启用 archive_work_unit 路由；
    仅当会话窗"单元归档"开关开启时由调用方传入（关闭时规格层不附加该工具，零开销）。
    app_control_ctx（0.4.9 3.48.2）：{"project_id", "session_id", "sandbox_root", "authorizer"}，
    启用 app_control 路由；None 时该工具调用直接报错（规格层本就不附加）。
    副作用动作（needs_confirm）经 authorizer 弹窗确认，用户拒绝则不执行。
    computer_use_ctx（0.4.9 3.48.1）：{"authorizer"}，启用 screen_view/mouse_click/
    keyboard_type/keyboard_hotkey 路由；None 时这些工具调用直接报错（规格层本就不附加）。
    ⚠️ 这些工具直接操作用户真实电脑，路由层强制两道防线：应用白名单校验（越界拒绝）
    + 每步动作确认（computer_use_confirm_each，经 authorizer 弹窗，拒绝则不执行）。
    cancel_check（TS-114 3.25）：回调为真时，本轮开始前（未发起模型调用）yield cancelled 事件并返回。
    """
    from sidecar.ollama.connector import get_ollama_connector
    conn = connector or get_ollama_connector()  # TS-103 B18：默认走单例，连接池复用

    msgs = [m for m in (messages or [])]
    if not any(m.get("role") == "system" for m in msgs):
        # M1-3：调用方未注入 system prompt 时兜底（调用方一般已注入，见 app.py）
        pass
    tokens_used = 0
    consecutive_fail_rounds = 0
    search_circuit_strikes = 0  # TS-105：web_search 熔断计数（连续 circuit_open 次数）
    # 0.4.11：Computer Use 连败熔断计数（工具名 → 连续失败次数）。
    # 真机事故（2026-09-07）：动作失败后模型反复重发同一动作，每次重试都触发
    # 每步确认弹窗 → 用户连点十几二十个确认仍停不下来。连败 COMPUTER_USE_MAX_STRIKES
    # 次即熔断该工具，直接报错终止而非继续弹窗。
    computer_use_strikes: dict[str, int] = {}
    tool_calls_log: list[dict[str, Any]] = []
    # 2026-08-28 问题2：搜索去重缓存 —— 记录本会话已执行成功的搜索关键词（归一化），
    # 模型用相同/已成功的关键词再搜时直接拦截并引导作答，避免空转重复搜索。
    executed_searches: dict[str, int] = {}   # 归一化 query → 命中次数
    # M2 上下文预警：记录每轮 prompt_eval_count（用于 est_rounds_left 倒推）
    prompt_eval_history: list[int] = []
    # checkpoint-067 R-4：read_file 读到的图片 base64 收集，下一轮经 images 参数注入视觉流，
    # 让多模态模型真正"看到"图片（而非把乱码当文本，导致自称无 OCR 能力）。
    pending_tool_images: list[str] = []

    for step in range(1, max_rounds + 1):
        # TS-114（3.25 委派停止）检查点：每轮开始前（发起模型调用之前）检测取消标志
        if cancel_check is not None:
            try:
                _cancelled = bool(cancel_check())
            except Exception:
                _cancelled = False
            if _cancelled:
                yield {"event": "cancelled", "data": {"detail": "已停止"}}
                return
        # M2 溢出预警（每轮开始前判定）
        if prompt_eval_history:
            last_pe = prompt_eval_history[-1]
            if context_limit and last_pe / context_limit >= 0.90:
                # 计算 est_rounds_left：最近 5 轮增量倒推
                recent = prompt_eval_history[-5:]
                if len(recent) >= 2:
                    deltas = [recent[i+1] - recent[i] for i in range(len(recent)-1)]
                    avg_delta = sum(deltas) / len(deltas)
                    remaining = context_limit - last_pe
                    est = int(remaining / avg_delta) if avg_delta > 0 else -1
                else:
                    est = -1
                import sidecar.config as _cfgmod
                _allow_auto = _cfgmod.get_config().get("allow_auto_compact", False)
                if _allow_auto:
                    # 打回修复（2026-08-29）：compact_auto = "通知服务端该压缩了"。
                    # 服务端（app.py）收到后真正执行 compact_session，完成后前端重发
                    # 最后一条 user 消息开新一轮。loop 此处发事件即返回（不 continue，
                    # 否则 history 清空后 prompt 仍超限会二次触发死循环烧 token）。
                    yield {"event": "compact_auto", "data": {"used": last_pe, "limit": context_limit, "est_rounds_left": est}}
                    return
                else:
                    yield {"event": "compact_required", "data": {"used": last_pe, "limit": context_limit, "est_rounds_left": est}}
                    return
        full_text = ""
        pending_tcs: list[dict[str, Any]] = []
        step_counts = {"prompt_eval_count": 0, "eval_count": 0}
        had_done = False

        # M6（TS-112）图片入流；checkpoint-067 R-4：工具 read_file 读到的图片合并注入。
        # checkpoint-070（修复附着图片丢失导致转写错误）：用户附着的图片【每轮都重发】，
        # 不能只发第一轮。否则模型在第二轮及以后只能看到 read_file 从磁盘读的图，
        # 会把"磁盘上的图"当成"用户要转写的图"而转写错误对象（用户实测：附着聊天截图
        # 却转写了磁盘上的营业执照）。
        _imgs: list[str] = []
        if first_round_images:
            _imgs.extend(first_round_images)   # 用户附着图片：每轮重发
        if pending_tool_images:
            _imgs.extend(pending_tool_images)  # 工具读到的图片：注入后即清空
            pending_tool_images = []
        _stream_kwargs: dict[str, Any] = {"tools": tools_spec_list}
        if _imgs:
            _stream_kwargs["images"] = _imgs
        # B3（0.4.8）：本轮送入模型的真实上下文字数。
        # 前端此前只按 user/assistant 消息估算，未计入工具结果（tool_report）与
        # system prompt，导致顶栏"上下文 ≈17"严重低估（实际数万 token）。
        # 这里统计 msgs 全部角色与全部字段（含 tools 声明），经 state 事件回传，
        # 前端指示器改用该真实值——不受 KV 缓存增量影响。
        _ctx_chars = 0
        for _m in msgs:
            if isinstance(_m, dict):
                for _k, _v in _m.items():
                    if isinstance(_v, str):
                        _ctx_chars += len(_v)
        if tools_spec_list:
            try:
                _ctx_chars += len(json.dumps(tools_spec_list, ensure_ascii=False))
            except (TypeError, ValueError):
                pass
        # B3：_ctx_chars 随本轮【已有】的 state 事件回传（见下方两处 yield），不新增事件——
        # 新增会破坏 test_loop 对 state 事件数量/步数序列的断言契约。
        async for ev in conn.chat_stream(model, msgs, **_stream_kwargs):
            if "stream_error" in ev:
                # connector 兜底的流内超时 → 优雅结束（问题1）
                # 0.4.9 任务161：带失败明细 + 用户指定的报错分析模型诊断
                yield {"event": "error", "data": await _build_error_payload(
                    f"流式推理中断：{ev['stream_error']}", tool_calls_log, conn)}
                return
            if "content_delta" in ev:
                full_text += ev["content_delta"]
                yield {"event": "token", "data": {"delta": ev["content_delta"]}}
            elif "thinking_delta" in ev:
                # TS-102 B13：思考增量透传给前端（仅作"思考中"指示，不计入正文/上下文）
                yield {"event": "thinking", "data": {"delta": ev["thinking_delta"]}}
            elif "tool_calls" in ev:
                for tc in ev["tool_calls"]:
                    fn = (tc or {}).get("function") or {}
                    args = fn.get("arguments")
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {}
                    pending_tcs.append({
                        "id": (tc or {}).get("id") or f"call_{len(pending_tcs) + 1}",
                        "name": fn.get("name", ""),
                        "args": args if isinstance(args, dict) else {},
                    })
            elif ev.get("done"):
                had_done = True
                c = ev.get("counts") or {}
                step_counts["prompt_eval_count"] = int(c.get("prompt_eval_count") or 0)
                step_counts["eval_count"] = int(c.get("eval_count") or 0)

        tokens_used += step_counts["prompt_eval_count"] + step_counts["eval_count"]
        if step_counts["prompt_eval_count"] > 0:
            prompt_eval_history.append(step_counts["prompt_eval_count"])

        # 本轮无工具调用
        if not pending_tcs:
            if full_text.strip():
                yield {"event": "state", "data": {"step": step, "max": max_rounds, "tokens_used": tokens_used, "prompt_eval_count": step_counts["prompt_eval_count"], "ctx_chars": _ctx_chars}}
                yield {"event": "done", "data": {"content": full_text, "tool_calls": tool_calls_log}}
                return
            # 空回复（模型未说话也没调工具）→ 优雅报错，不无限转
            # 0.4.9 任务161：空回复是模型层问题，附诊断帮助用户判断是否该换模型
            yield {"event": "error", "data": await _build_error_payload(
                f"模型未返回任何内容（无文本且无工具调用），已停止。当前模型：{model}。"
                "常见原因：该模型在工具结果回注后直接输出空（立即结束），属模型层稳定性问题。",
                tool_calls_log, conn)}
            return

        # 有工具调用：逐个执行，结果回注
        all_failed = True
        for tc in pending_tcs:
            yield {"event": "tool_call", "data": {
                "id": tc["id"], "name": tc["name"], "args": tc["args"], "status": "running"}}

            # ---- 2026-08-28 问题2：web_search 去重拦截 ----
            # 模型用"已成功搜索过"的相同关键词重复搜索时，不再真实执行（结果不会变，
            # 只会空耗轮次/token），直接返回提示引导其基于已有结果作答。
            if tc["name"] == "web_search":
                _q = _normalize_query((tc["args"] or {}).get("query", ""))
                if _q and _q in executed_searches:
                    executed_searches[_q] += 1
                    result = {"ok": False, "error": (
                        f"duplicate_search: 关键词「{(tc['args'] or {}).get('query', _q)}」"
                        f"已在本会话搜索过（第 {executed_searches[_q]} 次重复）。"
                        "请勿重复搜索同一/相近关键词，直接基于之前返回的搜索结果整理回答；"
                        "若信息不足，请换一个明显不同的角度重新拟定关键词。")}
                    ok = False  # 重复搜索视为未获得新信息，计入失败（连续重复会触发熔断防死循环）
                    entry = {"id": tc["id"], "name": tc["name"], "ok": ok,
                             "summary": "重复搜索已拦截"}
                    entry["error"] = str(result.get("error"))
                    tool_calls_log.append(entry)
                    yield {"event": "tool_result", "data": {
                        "id": tc["id"], "name": tc["name"], "ok": ok,
                        "summary": entry["summary"], "error": entry.get("error")}}
                    msgs.append({"role": "user", "content": json.dumps(
                        {"tool_report": {"id": tc["id"], "name": tc["name"],
                                         "args": tc["args"], "result": result}},
                        ensure_ascii=False)})
                    continue  # 不执行真实搜索

            # ---- TS-110 M4：read_skill 路由（按需读取技能指令；只读，不执行任何指令）----
            if tc["name"] == "read_skill":
                from sidecar.skills_mgr.manager import read_skill as _read_skill, list_skills as _list_skills
                _sname = str((tc["args"] or {}).get("name") or "").strip()
                _sk = _read_skill(_sname) if _sname else None
                if _sk is None:
                    _names = "、".join(s["dir_name"] for s in _list_skills()) or "（暂无技能）"
                    result = {"ok": False, "error": f"技能不存在：{_sname}。当前可用技能：{_names}"}
                elif not _sk.get("enabled"):
                    # checkpoint-047：逐项开关——该技能被用户禁用
                    result = {"ok": False, "error": f"技能「{_sname}」已被禁用（设置 → 插件与技能），无法调用。"}
                else:
                    result = {"ok": True, "_kind": "read_skill", "name": _sk["dir_name"],
                              "description": _sk.get("description", ""),
                              "content": _sk.get("content", "")}

            # ---- TS-120 阶段二：search_knowledge 路由（拉模式知识检索；读完即忘）----
            # 检索结果作为工具返回只活在本次请求的 msgs 里；落库仅最终回复文本，
            # 因此检索内容不会进入下一轮上下文——"读完即忘"由架构天然保证。
            # ---- 0.4.9（3.48.2）：app_control 路由（应用内模块控制）----
            # 按注册表分发到模块执行器。范式对齐 search_knowledge / archive_work_unit：
            # 不经 registry.execute（不是文件路径语义），也不自调 HTTP（省网络栈、避免长任务死锁）。
            if tc["name"] == "app_control":
                _args_c = tc["args"] or {}
                _module = str(_args_c.get("module") or "").strip()
                _action = str(_args_c.get("action") or "").strip()
                _params = _args_c.get("params") if isinstance(_args_c.get("params"), dict) else {}
                if not _module or not _action:
                    result = {"ok": False, "error": (
                        "app_control 需要 module 与 action 两个参数"
                        "（见系统提示词【可用应用模块动作】清单）。")}
                elif app_control_ctx is None:
                    result = {"ok": False, "error": (
                        "当前会话未启用应用内模块控制（工具不应出现在列表中）。"
                        "请如实告知用户：需在 设置 → 应用内模块控制 开启后才能调用。")}
                else:
                    from sidecar.app_modules import dispatch as _ac_dispatch, action_needs_confirm
                    try:
                        import sidecar.config as _cfg_ac
                        _confirm_list = _cfg_ac.get_config().get("app_control_confirm")
                        if not isinstance(_confirm_list, list):
                            _confirm_list = None
                    except Exception:
                        _confirm_list = None
                    _need_confirm = action_needs_confirm(_module, _action, _confirm_list)
                    _ac_authorizer = app_control_ctx.get("authorizer")
                    _denied = False
                    if _need_confirm:
                        # 副作用动作（运行工作流 / 创建圆桌）：先弹窗请用户确认。
                        # 复用敏感操作授权通道（action="app_module"），前端展示模块/动作/参数。
                        if _ac_authorizer is None:
                            result = {"ok": False, "error": (
                                f"app_module_denied: 「{_module}.{_action}」属高成本操作需用户确认，"
                                "但当前无授权通道，已拒绝执行（不擅自运行工作流/创建圆桌）。")}
                            _denied = True
                        else:
                            _ok = await _ac_authorizer(
                                f"app_control:{_module}.{_action}",
                                json.dumps(_params, ensure_ascii=False)[:400],
                                "app_module",
                                {"kind": "app_module", "module": _module, "action": _action,
                                 "params": _params})
                            _allowed = _ok.get("allowed") if isinstance(_ok, dict) else bool(_ok)
                            if not _allowed:
                                result = {"ok": False, "error": (
                                    f"denied_by_user: 用户拒绝了「{_module}.{_action}」。"
                                    "不要再重试该动作，请如实告知用户已取消，并询问下一步怎么做。")}
                                _denied = True
                    if not _denied:
                        result = await _ac_dispatch(_module, _action, _params, {
                            "project_id": app_control_ctx.get("project_id") or "",
                            "session_id": app_control_ctx.get("session_id") or "",
                            "sandbox_root": app_control_ctx.get("sandbox_root") or sandbox_root,
                        })

            # ---- 0.4.9（3.48.1）：Computer Use 路由（截屏 / 点击 / 输入）----
            # ⚠️ 直接操作用户真实电脑。两道防线在执行前强制把关：
            #   防线4 应用白名单：白名单非空时，前台应用不在其中 → 拒绝（防跑到别的应用乱点）
            #   防线3 每步确认：点击/输入执行前经 authorizer 弹窗，用户拒绝 → 不执行
            # 截屏（screen_view）只读不操作，无需确认；但仍受总开关与白名单约束。
            if tc["name"] in ("screen_view", "mouse_click", "keyboard_type", "keyboard_hotkey"):
                _args_u = tc["args"] or {}
                if computer_use_ctx is None:
                    result = {"ok": False, "error": (
                        "当前会话未启用 Computer Use（工具不应出现在列表中）。"
                        "请如实告知用户：需在 设置 → Computer Use 开启总开关后才能操作电脑。")}
                else:
                    # 0.4.11 连败熔断：⛔ 必须在【白名单 / 权限 / 确认弹窗】之前判断，
                    # 否则被熔断的那一次仍会弹窗，用户还得白点一下。
                    # 真机事故（2026-09-07）：动作失败后模型反复重发同一动作，
                    # 每次重试都触发每步确认弹窗 → 用户连点十几二十个仍停不下来。
                    _cu_strikes = computer_use_strikes.get(tc["name"], 0)
                    if _cu_strikes >= COMPUTER_USE_MAX_STRIKES:
                        result = {"ok": False, "error": (
                            f"computer_use_circuit_open: 「{tc['name']}」已连续失败 "
                            f"{_cu_strikes} 次，本轮已熔断该动作，不再重试、也不再弹确认窗。\n"
                            "⛔ 不要换参数重试同一动作，也不要改用其他 Computer Use 动作绕过。"
                            "请如实告知用户：该动作连续失败、需人工介入排查"
                            "（最常见根因是辅助功能/屏幕录制权限未授予【侧车二进制】——"
                            "让用户到 设置 → Computer Use 点「检测权限」查看确切路径与逐步指引）。")}
                        computer_use_strikes[tc["name"]] = _cu_strikes + 1
                    else:
                        try:
                            from sidecar.computer_use import (take_screenshot, mouse_click,
                                                              keyboard_type, keyboard_hotkey,
                                                              check_whitelist, check_permission_for)
                            import sidecar.config as _cfg_cu
                            _cfg_c = _cfg_cu.get_config()
                            _wl = _cfg_c.get("computer_use_app_whitelist") or []
                            _confirm_each = bool(_cfg_c.get("computer_use_confirm_each", True))
                        except Exception as e:
                            result = {"ok": False, "error": f"computer_use 模块加载失败：{e}"}
                            _wl = None
                        if _wl is not None:
                            # 防线4：白名单校验（截屏也校验——避免在不允许的应用上窥屏）
                            _wl_r = check_whitelist(_wl if isinstance(_wl, list) else [])
                            if not _wl_r.get("ok"):
                                result = {"ok": False, "error": f"app_not_allowed: {_wl_r.get('reason')}"}
                            # 0.4.11 防线1 前置：⛔ 权限检查必须在【确认弹窗之前】。
                            # 此前顺序是 弹窗 → 用户点「允许执行」→ 执行时才查权限 → 失败，
                            # 于是用户批准了一个注定失败的动作（真机事故：二十次点击全白费），
                            # 还给模型"用户同意了、再试一次"的错觉 → 无限重发 + 弹窗风暴。
                            elif not (_cu_perm := check_permission_for(tc["name"])).get("ok"):
                                result = {"ok": False,
                                          "error": _cu_perm.get("error") or "权限未授予"}
                            elif tc["name"] == "screen_view":
                                result = await asyncio.to_thread(take_screenshot)
                            else:
                                # 防线3：每步确认（副作用动作）
                                _cu_authorizer = computer_use_ctx.get("authorizer")
                                _desc = {"mouse_click": "点击屏幕",
                                         "keyboard_type": "输入文本",
                                         "keyboard_hotkey": "按下按键"}[tc["name"]]
                                _detail = json.dumps(_args_u, ensure_ascii=False)[:400]
                                _allowed = True
                                if _confirm_each:
                                    if _cu_authorizer is None:
                                        result = {"ok": False, "error": (
                                            f"computer_use_denied: 「{_desc}」需用户逐步确认，"
                                            "但当前无授权通道，已拒绝执行（不擅自操作你的电脑）。")}
                                        _allowed = False
                                    else:
                                        _ok_u = await _cu_authorizer(
                                            f"computer_use:{tc['name']}", _detail, "computer_use",
                                            {"kind": "computer_use", "tool": tc["name"],
                                             "desc": _desc, "args": _args_u,
                                             "app": _wl_r.get("app") or ""})
                                        _allowed = (_ok_u.get("allowed") if isinstance(_ok_u, dict)
                                                    else bool(_ok_u))
                                        if not _allowed:
                                            result = {"ok": False, "error": (
                                                f"denied_by_user: 用户拒绝了本次「{_desc}」操作。"
                                                "不要再重试该操作，请如实告知用户已取消，并询问下一步。")}
                                if _allowed:
                                    if tc["name"] == "mouse_click":
                                        result = await asyncio.to_thread(
                                            mouse_click, _args_u.get("x"), _args_u.get("y"),
                                            str(_args_u.get("button") or "left"),
                                            _args_u.get("clicks") or 1)
                                    elif tc["name"] == "keyboard_type":
                                        result = await asyncio.to_thread(
                                            keyboard_type, str(_args_u.get("text") or ""))
                                    else:
                                        result = await asyncio.to_thread(
                                            keyboard_hotkey, str(_args_u.get("keys") or ""))
                                    # 操作后提示模型重新截屏核对（界面已变，别凭记忆继续）
                                    if result.get("ok"):
                                        result["hint"] = ("操作后界面可能已变化，"
                                                          "继续下一步前请先 screen_view 重新截屏核对结果。")
                        # 0.4.11 熔断结算：成功即清零（连败要求"连续"）；失败累加。
                        # 用户主动拒绝也计入——连拒两次说明该动作不该继续，停止骚扰用户。
                        if result.get("ok"):
                            computer_use_strikes[tc["name"]] = 0
                        else:
                            computer_use_strikes[tc["name"]] = _cu_strikes + 1

            # ---- 0.4.9（3.47.1）：archive_work_unit 路由（单元归档）----
            # 不走 registry.execute：归档是"搬移本会话消息"，需要 project_id/session_id，
            # 与文件工具的路径语义无关。范式对齐 search_knowledge（同属知识仓库拉模式配套）。
            if tc["name"] == "archive_work_unit":
                _args_a = tc["args"] or {}
                _title_a = str(_args_a.get("title") or "").strip()
                _summary_a = str(_args_a.get("summary") or "").strip()
                if not _title_a:
                    result = {"ok": False, "error": (
                        "archive_work_unit 需要 title 参数（工作单元名称，如'《某案件》案情分析'）")}
                elif archive_ctx is None:
                    result = {"ok": False, "error": (
                        "当前会话未开启「单元归档」（工具不应出现在列表中）。"
                        "请如实告知用户：需在会话窗工具栏开启该开关后才能归档。")}
                else:
                    try:
                        result = archive_work_unit(
                            archive_ctx.get("project_id") or "",
                            archive_ctx.get("session_id") or "",
                            _title_a, _summary_a,
                            scope=str(_args_a.get("scope") or "project"))
                    except Exception as e:
                        result = {"ok": False, "error": f"归档失败：{e}"}

            if tc["name"] == "search_knowledge":
                _q = str((tc["args"] or {}).get("query") or "").strip()
                if not _q:
                    result = {"ok": False, "error": "search_knowledge 需要 query 参数（检索词）"}
                elif knowledge_ctx is None:
                    result = {"ok": False, "error": "当前会话未启用知识仓库检索"}
                else:
                    _scope = str((tc["args"] or {}).get("scope") or "all").strip()
                    _mode = str((tc["args"] or {}).get("mode") or "hybrid").strip()
                    try:
                        _limit = max(1, min(int((tc["args"] or {}).get("limit") or 5), 20))
                    except (TypeError, ValueError):
                        _limit = 5
                    try:
                        from sidecar.knowledge import warehouse as _wh
                        _wh.prune_missing()  # 外部删除对账
                        _pid_k = knowledge_ctx.get("project_id") or ""
                        if _scope == "project":
                            hits = _wh.hybrid_search(_q, "project", _pid_k, _limit, mode=_mode)
                        elif _scope == "global":
                            hits = _wh.hybrid_search(_q, "global", None, _limit, mode=_mode)
                        else:  # all：两作用域合并取分高者
                            _h1 = _wh.hybrid_search(_q, "project", _pid_k, _limit, mode=_mode)
                            _h2 = _wh.hybrid_search(_q, "global", None, _limit, mode=_mode)
                            hits = sorted(_h1 + _h2, key=lambda e: -float(e.get("score") or 0))[:_limit]
                        _items = [{"title": h.get("title"), "scope": h.get("scope"),
                                   "score": h.get("score"), "body": (h.get("body") or "")[:2000]}
                                  for h in hits]
                        result = {"ok": True, "_kind": "knowledge", "count": len(_items),
                                  "items": _items,
                                  "note": "检索结果仅本轮可见，不会写入对话上下文。"}
                    except Exception as e:
                        result = {"ok": False, "error": f"知识检索失败：{e}"}

            # ---- TS-107 M3-1：delegate_task 路由（主-子委派，决策 8）----
            # 不走 registry.execute：委派是"再起一个隔离的子会话 loop"。
            # delegation_ctx 为 None（子会话/旧端点）→ 双保险拒绝（工具规格本已剔除）。
            if tc["name"] == "delegate_task":
                if delegation_ctx is None:
                    result = {"ok": False, "error": "当前会话不允许委派"}
                else:
                    _args_d = tc["args"] or {}
                    _task_arg = str(_args_d.get("task") or "").strip()
                    _expect_arg = str(_args_d.get("expect") or "").strip()
                    _target_arg = str(_args_d.get("target") or "").strip()
                    _role_arg = str(_args_d.get("suggested_role") or "").strip()
                    # 0.4.9（3.47.2）：委派模型自选——主 Agent 按【可用模型及特长】画像选模型
                    _model_arg = str(_args_d.get("model") or "").strip()
                    # 0.1.71（TS-118）：target 必填回错——漏填时列出可用 Agent 名单，
                    # 让主模型补填后重试；绝不静默新建（0.1.70 实测：漏填 target
                    # 被当作"不存在"→ 自动新建继承主模型的错误子 Agent，把用户配置好的
                    # OCR 专员晾在一边，纯文本模型幻觉全文）
                    if not _task_arg or not _expect_arg or not _target_arg:
                        from sidecar.storage.store import list_agent_configs as _lac0
                        _names0 = "、".join(str(a.get("name", "")) for a in _lac0(
                            delegation_ctx["project_id"])
                            if a.get("id") != delegation_ctx["agent_id"]) or "（暂无其他 Agent）"
                        result = {"ok": False, "error": (
                            "delegate_task 需要 target（目标 Agent 名称）/task/expect 三个参数，"
                            f"请补全后重新调用。当前可用 Agent：{_names0}。")}
                    else:
                        from sidecar.agent_engine.delegation import (
                            resolve_target, run_delegated_task, auto_create_agent)
                        # TS-117（3.31 任务2）：加载 image_paths 图片 → base64，随委派传给子 Agent
                        _image_paths = _args_d.get("image_paths") or []
                        _loaded_images = []
                        _skipped_paths = []
                        # 0.4.9 F1：图片全部加载失败 → 拦截委派（哨兵短路后续解析/新建/执行）。
                        # 此前会继续发起委派（images=None），子 Agent 完全看不到图，只能凭空
                        # 编造识别结果并标记 success（用户实测事故：编造出虚假金额/日期/法条，
                        # 且 47 张图全部 skipped 后仍照常委派）。现直接回错并附【真实图片清单】，
                        # 让主 Agent 下一轮用正确路径重试（对齐 checkpoint-069 F-2 做法）。
                        # 只设 result 并短路，事件发出与结果回注由下方统一逻辑处理。
                        _f1_blocked = False
                        if _image_paths:
                            _loaded_images, _skipped_paths = _load_delegation_images(
                                _image_paths, sandbox_root)
                            if not _loaded_images:
                                _f1_blocked = True
                                result = {"ok": False, "error": (
                                    "images_not_found: 你传入的 image_paths 一张都没找到，"
                                    f"已跳过 {len(_skipped_paths)} 个（{_skipped_paths[:5]}"
                                    f"{'…' if len(_skipped_paths) > 5 else ''}）。"
                                    "委派已中止——若继续，子 Agent 将收不到任何图片而只能编造识别结果。"
                                    "请改用【完整绝对路径】重试；以下是工作目录下真实存在的图片："
                                    + _real_images_hint(sandbox_root))}
                        _agent = None
                        _terr = ""
                        _auto_created = False
                        if not _f1_blocked:
                            _agent, _terr = resolve_target(
                                delegation_ctx["project_id"], _target_arg, delegation_ctx["agent_id"])
                            # 0.1.71（TS-118）：suggested_role 兜底搜索——弱模型常把角色名
                            # 填进 suggested_role 而 target 写错/写别名；新建前先用
                            # suggested_role 在现有 Agent 中搜一轮（如'ocr专员'命中用户配置好的
                            # OCR 专员），命中即复用，避免新建重复/错误的子 Agent
                            if _agent is None and _role_arg and _role_arg != _target_arg:
                                _agent, _ = resolve_target(
                                    delegation_ctx["project_id"], _role_arg, delegation_ctx["agent_id"])
                            if _agent is None:
                                # TS-108 决策 9：目标不存在 → 按开关决定自动新建或转述用户。
                                # checkpoint-030 H14：弱模型常不填 suggested_role，
                                # 目标名本身即角色名（如"人事专员"）→ 缺省时用目标名兜底新建，不报错。
                                import sidecar.config as _cfgmod
                                _cfg_d = _cfgmod.get_config()
                                if _cfg_d.get("auto_create_sub_agents", True):
                                    # 0.4.9（3.47.2）：指定了 model → 用该模型新建子 Agent
                                    # （如"OCR 转写专员"用 glm-ocr）；未指定 → 沿用主 Agent 模型
                                    _agent = auto_create_agent(
                                        delegation_ctx["project_id"], _role_arg or _target_arg,
                                        _model_arg or delegation_ctx.get("model") or "qwen3.8")
                                    _auto_created = True
                                else:
                                    result = {"ok": False, "error": (
                                        _terr + "（自动新建子 Agent 功能已关闭。请告知用户：可在设置面板"
                                        "“多 Agent”区开启，或先在 Agent 面板手动创建子 Agent 后再委派。）")}
                        if _agent is not None:
                            # TS-117（3.31 任务2）：合并聊天附着图 + image_paths 加载图，
                            # 走 first_round_images 通道（每轮重发，禁走 pending 会中途丢图）
                            _deleg_images = (first_round_images or []) + _loaded_images
                            # 0.4.9（3.47.2）：本次委派实际使用的子模型
                            _child_model = _model_arg or (_agent.get("model_name") or "")
                            _parent_model = delegation_ctx.get("model") or ""
                            _conn = delegation_ctx.get("connector") or get_ollama_connector()
                            # ── 0.4.9（3.47.3）委派模型换装编排 ──────────────────
                            # ⛔ 0.4.7 回退教训（三条防护，缺一不可，否则批量委派必卡死）：
                            #   ① 每处卸载加独立超时（wait_for ≤ SWAP_TIMEOUT）——超时即放弃
                            #      卸载继续走，绝不阻塞委派主流程；
                            #   ② 卸载前先查 /api/ps 确认模型确在内存——Ollama 对"未加载模型"
                            #      会先加载再卸载，盲卸等于白白触发一次完整加载；
                            #   ③ 并发开启时禁用换装（并行卸载互相冲突）。
                            _swap_enabled = False
                            try:
                                import sidecar.config as _cfg_swap
                                _cfg_s = _cfg_swap.get_config()
                                _swap_enabled = bool(_cfg_s.get("delegation_model_swap", True))
                                if bool(_cfg_s.get("task_concurrency", False)) or \
                                   bool(_cfg_s.get("model_parallel", False)):
                                    _swap_enabled = False   # 防护③：并行场景不卸载
                            except Exception:
                                _swap_enabled = False

                            # 0.4.9（3.47.3）：防护①②见模块级 safe_unload_model（可单测）
                            async def _safe_unload(_m: str) -> bool:
                                return await safe_unload_model(_conn, _m)

                            if _swap_enabled and _parent_model and _child_model \
                                    and _parent_model != _child_model:
                                await _safe_unload(_parent_model)   # 委派前：腾出内存给子模型
                            try:
                                result = await run_delegated_task(
                                    delegation_ctx["project_id"], delegation_ctx["agent_id"],
                                    delegation_ctx["session_id"], _agent, _task_arg, _expect_arg,
                                    sandbox_root=sandbox_root, authorizer=authorizer,
                                    max_rounds=max_rounds,
                                    connector=_conn,
                                    # TS-114（3.27）+ TS-117（3.31）：主会话附着图片 + image_paths 图片
                                    # 随委派传给子 Agent 视觉流
                                    images=_deleg_images if _deleg_images else None,
                                    # 0.1.71（TS-118）：简单委派模式（主模型显式声明；带图时执行层强制启用）
                                    simple_mode=bool(_args_d.get("simple_mode") or False) or None,
                                    # 0.4.9（3.47.2）：委派模型自选
                                    model_override=_model_arg or None)
                            finally:
                                # 0.4.9（3.47.3）：交卷后卸子模型（finally 兜底：失败/超时/
                                # 中断路径都清理）。主模型无需手动加载——Ollama 请求到达时自动加载。
                                if _swap_enabled and _child_model:
                                    await _safe_unload(_child_model)
                            # TS-108：自动新建场景标注新 Agent，供主 Agent 告知用户
                            if _auto_created and isinstance(result, dict):
                                result["created_agent"] = _agent.get("name")
                            # TS-117：报告图片加载结果（loaded / skipped）
                            if isinstance(result, dict) and (_loaded_images or _skipped_paths):
                                result["images_loaded"] = len(first_round_images or []) + len(_loaded_images)
                                if _skipped_paths:
                                    result["images_skipped"] = _skipped_paths

            # ---- authorizer 分工（2026-08-28 权限宽松化重构）----
            # loop 层不再执行前询问（避免每个操作都弹窗骚扰用户）；
            # authorizer 仅透传给 registry 层，由 registry 自行判定：
            # 仅"敏感系统位置的删除/覆盖"才请求用户确认，其余操作默认放行。
            # TS-107/TS-110：delegate_task 与 read_skill 已在上方路由，跳过通用执行。
            # TS-120 阶段二：search_knowledge 同理（拉模式知识检索路由）。
            if tc["name"] not in ("delegate_task", "read_skill", "search_knowledge",
                                  "archive_work_unit", "app_control",
                                  "screen_view", "mouse_click",
                                  "keyboard_type", "keyboard_hotkey"):
                result = await _run_tool(tc["name"], tc["args"], sandbox_root, authorizer)
            ok = bool(result.get("ok"))
            if ok:
                all_failed = False
                # 记录成功执行的搜索关键词（供后续去重）
                if tc["name"] == "web_search":
                    _q = _normalize_query((tc["args"] or {}).get("query", ""))
                    if _q:
                        executed_searches[_q] = executed_searches.get(_q, 0)
                # checkpoint-067 R-4：read_file 读到图片 → 收集 base64 供下一轮视觉注入，
                # 并从回注报告里剔除巨大的 base64（避免撑爆上下文；图片走 images 参数）。
                if result.get("_kind") == "image" and result.get("image_base64"):
                    # 0.4.9（3.48.1）：mime 由工具给出（截屏是 JPEG，read_file 按扩展名）。
                    # 此前写死 image/png —— 对 JPEG 数据标记错误 mime，部分视觉后端会拒绝或解码异常。
                    # 无 mime 字段时回落 png（保持 read_file 既有行为不变）。
                    _mime = str(result.get("mime") or "image/png")
                    if not _mime.startswith("image/"):
                        _mime = "image/png"
                    pending_tool_images.append(f"data:{_mime};base64," + result["image_base64"])
                    result = {k: v for k, v in result.items()
                              if k not in ("image_base64", "mime")}
            entry = {"id": tc["id"], "name": tc["name"], "ok": ok,
                     "summary": _summarize(result)}
            # 0.4.9 任务161：失败时记录参数摘要，供报错"失败明细"展示（哪个工具、什么参数）。
            # 仅失败时记（成功无需），且逐值截断 80 字——content 等长字段不得撑大落库体积。
            if not ok:
                entry["error"] = str(result.get("error", "unknown"))
                try:
                    entry["args"] = {k: (str(v)[:80] if not isinstance(v, (int, float, bool)) else v)
                                     for k, v in list((tc.get("args") or {}).items())[:6]}
                except Exception:
                    entry["args"] = {}
            tool_calls_log.append(entry)
            _tr_data = {
                "id": tc["id"], "name": tc["name"], "ok": ok,
                "summary": entry["summary"], "error": entry.get("error")}
            # TS-108：委派结果中的 created_agent（自动新建标注）透出事件流
            if tc["name"] == "delegate_task" and result.get("created_agent"):
                _tr_data["created_agent"] = result.get("created_agent")
            yield {"event": "tool_result", "data": _tr_data}
            # TS-105 熔断感知停止（核心）：web_search 返回 circuit_open=True → 立即停止。
            # 与"连续全失败"熔断并行：前者感知"境外源已被系统熔断"这一明确信号，
            # 后者是通用兜底。成功/非熔断结果清零 strikes。
            # 注意：判定放在 yield tool_result 之后，确保前端能看到最后一次工具结果。
            if tc["name"] == "web_search":
                if result.get("circuit_open") is True:
                    search_circuit_strikes += 1
                    if search_circuit_strikes >= SEARCH_CIRCUIT_STOP:
                        yield {"event": "error", "data": await _build_error_payload(
                            "境外搜索已被系统熔断（无代理环境下重复重试无意义）。已停止。"
                            "请开启代理或改用国内信息源后重试。", tool_calls_log, conn)}
                        return
                else:
                    search_circuit_strikes = 0
            # 结果回注：qwen3.8 的 Ollama 端不解析 role="tool" 消息（实测 400：
            # "Value looks like object, but can't find closing '}'"），
            # 故采用对 qwen 系最稳的兼容格式——role="user" 内嵌结构化 JSON 工具报告。
            # 仍保持"结构化契约"：内容是 json.dumps(result)，非裸文本。
            report = {
                "tool_report": {
                    "id": tc["id"],
                    "name": tc["name"],
                    "args": tc["args"],
                    "result": result,
                    "note": "以上是工具执行结果（结构化 JSON）。ok=false 时按 error 字段处理，不要重试同一错误调用。",
                }
            }
            msgs.append({"role": "user", "content": json.dumps(report, ensure_ascii=False)})

        yield {"event": "state", "data": {"step": step, "max": max_rounds, "tokens_used": tokens_used, "prompt_eval_count": step_counts["prompt_eval_count"], "ctx_chars": _ctx_chars}}

        # 双保险熔断之 2：连续失败
        if all_failed:
            consecutive_fail_rounds += 1
            if consecutive_fail_rounds >= CONSECUTIVE_FAIL_LIMIT:
                # 0.4.9 任务161：这条此前只说"请检查指令或权限"，不说哪个工具什么错——
                # 用户无从判断。现附失败明细（工具名+参数+真实错误）与模型诊断。
                yield {"event": "error", "data": await _build_error_payload(
                    # 保留"连续工具失败"短语（test_loop 用例6/15e 断言依赖的稳定契约），
                    # 其后由 _build_error_payload 追加失败明细与模型诊断（任务161）。
                    f"连续工具失败：连续 {CONSECUTIVE_FAIL_LIMIT} 轮工具调用全部失败，已停止。",
                    tool_calls_log, conn)}
                return
        else:
            consecutive_fail_rounds = 0

    # 双保险熔断之 1：轮次上限
    yield {"event": "error", "data": await _build_error_payload(
        f"达到最大轮次（{max_rounds}），已停止。已完成部分见上方 tool_result。",
        tool_calls_log, conn)}
