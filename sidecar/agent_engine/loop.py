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
def tools_spec(with_delegation: bool = True) -> list[dict[str, Any]]:
    """工具规格列表。with_delegation=False 时剔除 delegate_task（子会话防递归委派）。
    read_skill 两态均含；单个技能的启用/禁用为逐项状态（技能清单只列启用项，
    read_skill 路由对禁用项返回"已禁用"提示，见 checkpoint-047）。"""
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
                               "子 Agent 看不到当前对话历史，任务书必须自包含（目标+必要输入+预期产出）。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "target": {"type": "string", "description": "目标 Agent 的名称或 ID"},
                        "task": {"type": "string", "description": "任务书：目标、背景、输入材料，必须自包含"},
                        "expect": {"type": "string", "description": "交卷标准：期望子 Agent 产出什么"},
                        "suggested_role": {"type": "string",
                                           "description": "目标 Agent 不存在时，按此角色自动新建子 Agent 并执行"
                                                          "（如'数据分析师'）。可不填，不填时直接用 target 名称新建。"},
                    },
                    "required": ["target", "task", "expect"],
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
            "- 需要分工时用 delegate_task 委派：任务书必须自包含，子 Agent 看不到本对话历史，"
            "目标/输入/预期产出都要写进任务书。\n"
            "- 委派目标可以是项目内已有的 Agent；若目标不存在，系统会按建议角色"
            "（不填则按目标名称）自动新建子 Agent 并执行，无需先询问用户。\n"
            "- 子 Agent 交卷是固定 JSON（task_id/status/summary/artifacts），你负责整合各交卷，"
            "最终回复中标注每部分来自哪个子 Agent。\n"
            "- 交卷标记异常（ok=false）时，如实告知用户哪个子任务缺失及原因，不要虚构其产出。\n"
            "- 【强制】委派失败/交卷异常后，禁止你自己重新搜索或亲自完成该子任务来代答"
            "（那会让委派失去意义，且你已看不到子 Agent 的中间过程）。正确做法：向用户说明"
            "失败原因，建议重试该子任务或调整任务书后再委派一次。\n"
            "- 不要委派自己，也不要把整个任务原样转丢给子 Agent。"
        )
    return base


# ---------- 内部：执行一个工具（authorizer 三元组签名） ----------
async def _run_tool(name: str, args: dict, sandbox_root: str, authorizer: Authorizer | None):
    return await execute_tool(name, args or {}, sandbox_root, authorizer)


def _normalize_query(q: str) -> str:
    """搜索关键词归一化（用于去重判定）：去首尾空白、压缩连续空白、转小写。"""
    return _re.sub(r"\s+", " ", str(q)).strip().lower()


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
) -> AsyncIterator[dict]:
    """tool-calling 循环。yield 事件 dict（与 SSE event 一一对应）：
      token / tool_call / tool_result / state / done / error
    熔断双保险：轮次上限 + 连续 CONSECUTIVE_FAIL_LIMIT 轮工具全部失败。
    delegation_ctx（TS-107 M3-1）：主会话传 {"project_id","agent_id","session_id","connector"}，
    此时 delegate_task 路由到委派执行器；None 时不允许委派（子会话双保险）。
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

        # M6（TS-112）图片入流：第一轮把用户图片传给连接器；后续轮次模型已基于图片上下文。
        # checkpoint-067 R-4：工具 read_file 读到的图片（_kind="image"）也合并注入，
        # 让多模态模型真正看到工具读取的图片。
        # 无图片时不传 images 参数，保持与原调用签名一致（兼容既有 Mock 连接器）。
        _imgs: list[str] = []
        if step == 1 and first_round_images:
            _imgs.extend(first_round_images)
        if pending_tool_images:
            _imgs.extend(pending_tool_images)
            pending_tool_images = []  # 消费后清空，避免重复注入
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
                    if not _task_arg or not _expect_arg:
                        result = {"ok": False, "error": "delegate_task 需要 target/task/expect 三个参数，请补全。"}
                    else:
                        from sidecar.agent_engine.delegation import (
                            resolve_target, run_delegated_task, auto_create_agent)
                        _agent, _terr = resolve_target(
                            delegation_ctx["project_id"], _args_d.get("target", ""), delegation_ctx["agent_id"])
                        _auto_created = False
                        if _agent is None:
                            # TS-108 决策 9：目标不存在 → 按开关决定自动新建或转述用户。
                            # checkpoint-030 H14：弱模型常不填 suggested_role，
                            # 目标名本身即角色名（如"人事专员"）→ 缺省时用目标名兜底新建，不报错。
                            import sidecar.config as _cfgmod
                            _cfg_d = _cfgmod.get_config()
                            if _cfg_d.get("auto_create_sub_agents", True):
                                _role_arg = str(_args_d.get("suggested_role") or "").strip() \
                                    or str(_args_d.get("target", "")).strip()
                                _agent = auto_create_agent(
                                    delegation_ctx["project_id"], _role_arg,
                                    delegation_ctx.get("model") or "qwen3.8")
                                _auto_created = True
                            else:
                                result = {"ok": False, "error": (
                                    _terr + "（自动新建子 Agent 功能已关闭。请告知用户：可在设置面板"
                                    "“多 Agent”区开启，或先在 Agent 面板手动创建子 Agent 后再委派。）")}
                        if _agent is not None:
                            result = await run_delegated_task(
                                delegation_ctx["project_id"], delegation_ctx["agent_id"],
                                delegation_ctx["session_id"], _agent, _task_arg, _expect_arg,
                                sandbox_root=sandbox_root, authorizer=authorizer,
                                max_rounds=max_rounds,
                                connector=delegation_ctx.get("connector"))
                            # TS-108：自动新建场景标注新 Agent，供主 Agent 告知用户
                            if _auto_created and isinstance(result, dict):
                                result["created_agent"] = _agent.get("name")

            # ---- authorizer 分工（2026-08-28 权限宽松化重构）----
            # loop 层不再执行前询问（避免每个操作都弹窗骚扰用户）；
            # authorizer 仅透传给 registry 层，由 registry 自行判定：
            # 仅"敏感系统位置的删除/覆盖"才请求用户确认，其余操作默认放行。
            # TS-107/TS-110：delegate_task 与 read_skill 已在上方路由，跳过通用执行。
            if tc["name"] not in ("delegate_task", "read_skill"):
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
