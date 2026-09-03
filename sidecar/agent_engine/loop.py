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
SEARCH_CIRCUIT_STOP = 1        # TS-105：web_search 返回 circuit_open=True → 立即停止（熔断器已确认重试无意义；任务单写 2 但实际时序导致第 1 次 False 第 2 次 True，strikes 永远到不了 2，故改为 1）
SUMMARY_MAX_CHARS = 200         # tool_result 摘要截断长度（协议常量）
HEARTBEAT_INTERVAL = 15.0       # SSE 空闲心跳间隔（M5 正式做，M1-2 占位）

Authorizer = Callable[..., Any]  # async (tool_name, target_path, action) -> bool


# ---------- 工具 spec（Ollama OpenAI 风格 tools 参数） ----------
def tools_spec(with_delegation: bool = True, with_knowledge: bool = False) -> list[dict[str, Any]]:
    """工具规格列表。with_delegation=False 时剔除 delegate_task（子会话防递归委派）。
    read_skill 两态均含；单个技能的启用/禁用为逐项状态（技能清单只列启用项，
    read_skill 路由对禁用项返回"已禁用"提示，见 checkpoint-047）。
    TS-120 阶段二：with_knowledge=True 时附加 search_knowledge（知识仓库主动检索，拉模式）。"""
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
) -> str:
    """按需求顺序拼装：红线区 → 身份 → 环境 → 工具说明（+委派纪律）。零硬编码（全从入参）。
    M4（TS-110）：新增知识/记忆/技能注入（禁止事项并入红线区，100% 拦截；优先级 记忆>知识）。"""
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
    单张失败不阻塞：部分成功即传，调用方据返回值报告 loaded / skipped。
    """
    import base64 as _b64
    from pathlib import Path as _Path
    from sidecar.tools.registry import resolve_sandboxed_path

    loaded: list[str] = []
    skipped: list[str] = []
    paths = [p for p in (image_paths or []) if isinstance(p, str) and p.strip()]
    for rel in paths[:_MAX_DELEGATION_IMAGES]:
        resolved = resolve_sandboxed_path(rel.strip(), sandbox_root)
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
) -> AsyncIterator[dict]:
    """tool-calling 循环。yield 事件 dict（与 SSE event 一一对应）：
      token / tool_call / tool_result / state / done / error
    熔断双保险：轮次上限 + 连续 CONSECUTIVE_FAIL_LIMIT 轮工具全部失败。
    delegation_ctx（TS-107 M3-1）：主会话传 {"project_id","agent_id","session_id","connector"}，
    此时 delegate_task 路由到委派执行器；None 时不允许委派（子会话双保险）。
    knowledge_ctx（TS-120 阶段二）：{"project_id": ...}，启用 search_knowledge 路由；
    None 时该工具调用直接报错（规格层本就不附加）。
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
        async for ev in conn.chat_stream(model, msgs, **_stream_kwargs):
            if "stream_error" in ev:
                # connector 兜底的流内超时 → 优雅结束（问题1）
                yield {"event": "error", "data": {"detail": ev["stream_error"]}}
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
                yield {"event": "state", "data": {"step": step, "max": max_rounds, "tokens_used": tokens_used, "prompt_eval_count": step_counts["prompt_eval_count"]}}
                yield {"event": "done", "data": {"content": full_text, "tool_calls": tool_calls_log}}
                return
            # 空回复（模型未说话也没调工具）→ 优雅报错，不无限转
            yield {"event": "error", "data": {"detail": "模型未返回任何内容（无文本且无工具调用），已停止。"}}
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
                        if _image_paths:
                            _loaded_images, _skipped_paths = _load_delegation_images(
                                _image_paths, sandbox_root)
                        _agent, _terr = resolve_target(
                            delegation_ctx["project_id"], _target_arg, delegation_ctx["agent_id"])
                        _auto_created = False
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
                                _agent = auto_create_agent(
                                    delegation_ctx["project_id"], _role_arg or _target_arg,
                                    delegation_ctx.get("model") or "qwen3.8")
                                _auto_created = True
                            else:
                                result = {"ok": False, "error": (
                                    _terr + "（自动新建子 Agent 功能已关闭。请告知用户：可在设置面板"
                                    "“多 Agent”区开启，或先在 Agent 面板手动创建子 Agent 后再委派。）")}
                        if _agent is not None:
                            # TS-117（3.31 任务2）：合并聊天附着图 + image_paths 加载图，
                            # 走 first_round_images 通道（每轮重发，禁走 pending 会中途丢图）
                            _deleg_images = (first_round_images or []) + _loaded_images
                            result = await run_delegated_task(
                                delegation_ctx["project_id"], delegation_ctx["agent_id"],
                                delegation_ctx["session_id"], _agent, _task_arg, _expect_arg,
                                sandbox_root=sandbox_root, authorizer=authorizer,
                                max_rounds=max_rounds,
                                connector=delegation_ctx.get("connector"),
                                # TS-114（3.27）+ TS-117（3.31）：主会话附着图片 + image_paths 图片
                                # 随委派传给子 Agent 视觉流
                                images=_deleg_images if _deleg_images else None,
                                # 0.1.71（TS-118）：简单委派模式（主模型显式声明；带图时执行层强制启用）
                                simple_mode=bool(_args_d.get("simple_mode") or False) or None)
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
            if tc["name"] not in ("delegate_task", "read_skill", "search_knowledge"):
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
                    pending_tool_images.append("data:image/png;base64," + result["image_base64"])
                    result = {k: v for k, v in result.items() if k != "image_base64"}
            entry = {"id": tc["id"], "name": tc["name"], "ok": ok,
                     "summary": _summarize(result)}
            if not ok:
                entry["error"] = str(result.get("error", "unknown"))
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
                        yield {"event": "error", "data": {"detail":
                            "境外搜索已被系统熔断（无代理环境下重复重试无意义）。已停止。"
                            "请开启代理或改用国内信息源后重试。"}}
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

        yield {"event": "state", "data": {"step": step, "max": max_rounds, "tokens_used": tokens_used, "prompt_eval_count": step_counts["prompt_eval_count"]}}

        # 双保险熔断之 2：连续失败
        if all_failed:
            consecutive_fail_rounds += 1
            if consecutive_fail_rounds >= CONSECUTIVE_FAIL_LIMIT:
                yield {"event": "error", "data": {"detail": "连续工具失败，已停止。请检查指令或工作目录权限后重试。"}}
                return
        else:
            consecutive_fail_rounds = 0

    # 双保险熔断之 1：轮次上限
    yield {"event": "error", "data": {"detail": "达到最大轮次，已停止。已完成部分见 tool_result 事件。"}}
