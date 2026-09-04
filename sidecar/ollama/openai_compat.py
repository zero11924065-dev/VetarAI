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
"""M6（TS-112）：OpenAI 兼容推理后端连接器。

覆盖 LM Studio / llama.cpp server / vLLM / 任意 OpenAI 兼容服务（本地或远程中转）。
设计约束（审核一票否决项）：
- 出站 100% 过 guard（远程地址同样受网络开关管控）+ trust_env=False
- 事件协议与 OllamaConnector 完全一致（调用方零改动）：
    {"content_delta"} / {"thinking_delta"} / {"tool_calls"} / {"done", counts} / {"stream_error"}
- 异常语义一致：401/403 → NetworkGuardError；其余 4xx/5xx → OllamaAPIError
- 工具调用分块拼装（OpenAI SSE 的 tool_calls 按 index 分块到达，累积后整体产出）
"""
from __future__ import annotations

import base64
import json as _json
from pathlib import Path
from typing import Any

import httpx

from sidecar.network.guard import guard_request, NetworkGuardError
from sidecar.config import get_config
from sidecar.ollama.connector import OllamaAPIError, CONNECT_TIMEOUT, STREAM_READ_TIMEOUT


def _host_of(base_url: str) -> str:
    from urllib.parse import urlparse
    return (urlparse(base_url).hostname or "")


class OpenAICompatConnector:
    """OpenAI 兼容后端连接器（/v1/chat/completions、/v1/models）。"""

    def __init__(self) -> None:
        self._clients: dict[tuple, httpx.AsyncClient] = {}
        self._state: tuple | None = None

    # ── 配置与连接管理（同款指纹重建 + guard 契约）──
    def _config_state(self) -> tuple:
        """配置指纹：后端/地址/密钥/网络开关/代理端口任一变化 → 重建连接。"""
        from sidecar.config import get_config as _gc
        cfg = _gc()
        return (str(cfg.get("inference_base_url", "")).strip(),
                str(cfg.get("inference_api_key", "")).strip(),
                str(cfg.get("network_switch", "off")).lower(),
                int(cfg.get("proxy_http_port", 0)))

    def _base(self) -> str:
        base = str(get_config().get("inference_base_url", "")).strip()
        if not base:
            raise OllamaAPIError("推理后端地址未配置（设置面板：推理后端 → 地址）", 400, "")
        return base.rstrip("/")

    def _guard(self) -> dict[str, str] | None:
        proxies, reason = guard_request(_host_of(self._base()))
        if reason is not None:
            raise NetworkGuardError(reason, _host_of(self._base()))
        return proxies

    async def _client(self, reading: float = 300.0,
                      connect: float = CONNECT_TIMEOUT) -> httpx.AsyncClient:
        """共享复用 client（调用方不得关闭）；配置指纹变化 → 关闭旧连接重建。"""
        state = self._config_state()
        if state != self._state:
            for c in self._clients.values():
                await c.aclose()
            self._clients.clear()
            self._state = state
        proxies = self._guard()
        proxy = proxies["http"] if proxies else None
        key = (proxy, reading, connect)
        client = self._clients.get(key)
        if client is None or client.is_closed:
            kwargs: dict[str, Any] = {"timeout": httpx.Timeout(reading, connect=connect),
                                      "trust_env": False}
            if proxy:
                kwargs["proxy"] = proxy
            api_key = str(get_config().get("inference_api_key", "")).strip()
            if api_key:
                kwargs["headers"] = {"Authorization": f"Bearer {api_key}"}
            client = httpx.AsyncClient(**kwargs)
            self._clients[key] = client
        return client

    async def aclose_all(self) -> None:
        for c in self._clients.values():
            await c.aclose()
        self._clients.clear()
        self._state = None

    def capabilities(self) -> dict[str, Any]:
        """后端能力表（端点守卫与前端渲染的唯一事实源）。"""
        cfg = get_config()
        return {"backend": "openai_compatible",
                "tools": bool(cfg.get("openai_compat_supports_tools", True)),
                "vision": True, "pull": False, "delete": False}

    # ── 图片处理（OpenAI content 数组格式）──
    def _image_parts(self, images: list[str]) -> list[dict]:
        """data URI / 文件路径 / 裸 base64 → OpenAI image_url content 块。超大图丢弃。"""
        parts = []
        for img in images or []:
            b64 = self._parse_image(img)
            if not b64:
                continue
            parts.append({"type": "image_url",
                          "image_url": {"url": f"data:image/png;base64,{b64}"}})
        return parts

    @staticmethod
    def _parse_image(img_src: str) -> str | None:
        """解析图片为 base64；超大图（>8MB）一律丢弃，禁止静默截断成半图。"""
        b64 = None
        if img_src.startswith('data:'):
            b64 = img_src.split(',', 1)[1] if ',' in img_src else ''
        elif Path(img_src).exists():
            try:
                b64 = base64.b64encode(Path(img_src).read_bytes()).decode('ascii')
            except Exception:
                return None
        elif len(img_src) > 50:
            b64 = img_src
        else:
            return None
        if b64 is not None and len(b64) > 8_000_000:   # ~8MB base64 上限（所有来源统一检查）
            return None
        return b64

    @staticmethod
    def _merge_images_into_messages(messages: list[dict], image_parts: list[dict]) -> list[dict]:
        """把图片块合入最后一条 user 消息（OpenAI content 数组格式）。"""
        if not image_parts or not messages:
            return messages
        msgs = list(messages)
        for i in range(len(msgs) - 1, -1, -1):
            if msgs[i].get("role") == "user":
                m = dict(msgs[i])
                content = m.get("content", "")
                text = content if isinstance(content, str) else str(content)
                m["content"] = [{"type": "text", "text": text}] + image_parts
                msgs[i] = m
                return msgs
        return messages

    # ── 非流式 chat（圆桌/总结等在用）──
    async def chat(self, model: str, messages: list[dict[str, Any]], *,
                   stream: bool = False, images: list[str] | None = None) -> str:
        payload: dict[str, Any] = {"model": model, "messages": list(messages), "stream": False}
        dropped_images = 0
        if images:
            parsed = []
            for img in images:
                b64 = self._parse_image(img)
                if b64:
                    parsed.append(b64)
                else:
                    dropped_images += 1
            if parsed:
                parts = [{"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b}"}}
                         for b in parsed]
                payload["messages"] = self._merge_images_into_messages(payload["messages"], parts)

        client = await self._client()
        r = await client.post(f"{self._base()}/chat/completions", json=payload)

        # 400/500 + 带图 → 模型不支持多模态：剥图重试一次（同款降级；
        # checkpoint-041：部分服务端图片不支持返回 500 而非 400）
        if r.status_code in (400, 500) and any(
                isinstance(m.get("content"), list) for m in payload["messages"]):
            msgs = []
            for m in payload["messages"]:
                m2 = dict(m)
                if isinstance(m2.get("content"), list):
                    m2["content"] = "".join(
                        c.get("text", "") for c in m2["content"] if c.get("type") == "text")
                msgs.append(m2)
            payload["messages"] = msgs
            r2 = await client.post(f"{self._base()}/chat/completions", json=payload)
            if r2.status_code != 200:
                self._raise_http(r2, "对话请求失败")
            content = ((r2.json().get("choices") or [{}])[0].get("message") or {}).get("content", "")
            note = "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"
            if dropped_images:
                note += f"\n\n[⚠️ {dropped_images} 张图片过大已丢弃，未参与分析。]"
            return content + note

        if r.status_code != 200:
            self._raise_http(r, "对话请求失败")
        note = (f"\n\n[⚠️ {dropped_images} 张图片过大已丢弃，未参与分析。]" if dropped_images else "")
        try:
            data = r.json()
            return ((data.get("choices") or [{}])[0].get("message") or {}).get("content", "") + note
        except Exception:
            return r.text + note

    # ── 流式（核心）──
    async def chat_stream(self, model: str, messages: list[dict[str, Any]], *,
                          tools: list[dict[str, Any]] | None = None,
                          images: list[str] | None = None) -> Any:
        """流式 /v1/chat/completions。归一化为 Ollama 同款事件协议。

        工具调用分块拼装：delta.tool_calls 按 index 累积（name/arguments 分块到达），
        finish_reason==tool_calls 或 [DONE] 时整体 yield {"tool_calls": [...]}。
        """
        payload: dict[str, Any] = {"model": model, "messages": list(messages), "stream": True,
                                   "stream_options": {"include_usage": True}}
        if tools:
            payload["tools"] = tools
        if images:
            parts = self._image_parts(images)
            if parts:
                payload["messages"] = self._merge_images_into_messages(payload["messages"], parts)

        client = await self._client(reading=STREAM_READ_TIMEOUT)
        usage_counts = {"prompt_eval_count": 0, "eval_count": 0}
        # 工具调用累积缓冲：{index: {"id":..., "name":..., "arguments":...}}
        tc_buf: dict[int, dict[str, str]] = {}
        # checkpoint-041：流式非 200（400/500 图片不支持等）→ 剥图重试 + 降级文案
        had_images = any(isinstance(m.get("content"), list) for m in payload["messages"])
        try:
            async with client.stream("POST", f"{self._base()}/chat/completions",
                                     json=payload) as r:
                if r.status_code != 200:
                    body = (await r.aread()).decode("utf-8", errors="replace")
                    if r.status_code in (400, 500) and had_images:
                        for m in payload["messages"]:
                            if isinstance(m.get("content"), list):
                                m["content"] = "".join(
                                    c.get("text", "") for c in m["content"]
                                    if c.get("type") == "text")
                        # checkpoint-042：重发必须用 stream=False，否则服务端
                        # 返回多行流式响应，一次性 .json() 抛 "Extra data"
                        retry_payload = {**payload, "stream": False}
                        r2 = await client.post(f"{self._base()}/chat/completions",
                                               json=retry_payload)
                        if r2.status_code != 200:
                            self._raise_http(r2, "对话请求失败")
                        text = r2.text
                        try:
                            content = ((r2.json().get("choices") or [{}])[0]
                                       .get("message") or {}).get("content", "")
                        except _json.JSONDecodeError:
                            # 防御：万一仍为多行 SSE → 逐行 data: 拼接
                            content = ""
                            for ln in text.splitlines():
                                ln = ln.strip()
                                if not ln.startswith("data:") or "[DONE]" in ln:
                                    continue
                                try:
                                    obj = _json.loads(ln[5:].strip())
                                    content += ((obj.get("choices") or [{}])[0]
                                                .get("delta") or {}).get("content", "")
                                except _json.JSONDecodeError:
                                    continue
                        yield {"content_delta": content +
                               "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"}
                        yield {"done": True, "counts": {
                            "prompt_eval_count": 0, "eval_count": 0}}
                        return
                    self._raise_stream_http(r, body, tools_requested=bool(tools))
                async for line in r.aiter_lines():
                    line = line.strip()
                    if not line.startswith("data:"):
                        continue
                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        obj = _json.loads(data_str)
                    except _json.JSONDecodeError:
                        continue
                    u = obj.get("usage")
                    if u:
                        usage_counts["prompt_eval_count"] = int(u.get("prompt_tokens") or 0)
                        usage_counts["eval_count"] = int(u.get("completion_tokens") or 0)
                    choices = obj.get("choices") or []
                    if not choices:
                        continue
                    ch = choices[0]
                    delta = ch.get("delta") or {}
                    # thinking（不同服务端字段：reasoning_content / reasoning）
                    th = delta.get("reasoning_content") or delta.get("reasoning")
                    if th:
                        yield {"thinking_delta": th}
                    content = delta.get("content")
                    if content:
                        yield {"content_delta": content}
                    # 工具调用分块拼装
                    for tcd in (delta.get("tool_calls") or []):
                        idx = int(tcd.get("index") or 0)
                        slot = tc_buf.setdefault(idx, {"id": "", "name": "", "arguments": ""})
                        if tcd.get("id"):
                            slot["id"] = tcd["id"]
                        fn = tcd.get("function") or {}
                        if fn.get("name"):
                            slot["name"] = fn["name"]
                        if fn.get("arguments"):
                            slot["arguments"] += fn["arguments"]
                    finish_reason = ch.get("finish_reason")
                    if finish_reason == "tool_calls" and tc_buf:
                        yield {"tool_calls": self._flush_tool_calls(tc_buf)}
                        tc_buf = {}
                # [DONE] 或流结束：残留工具调用整体产出
                if tc_buf:
                    yield {"tool_calls": self._flush_tool_calls(tc_buf)}
                yield {"done": True, "counts": usage_counts}
        except _ToolsUnsupported as e:
            yield {"stream_error": f"当前推理后端不支持工具调用（{e}）。"
                                   "可在设置面板关闭工具支持，或换用支持工具的后端/模型。"}
        except httpx.TimeoutException:
            yield {"stream_error": "模型响应超时，已停止。已完成部分见上方事件。"}

    @staticmethod
    def _flush_tool_calls(buf: dict[int, dict[str, str]]) -> list[dict]:
        """累积缓冲 → Ollama 原生工具调用结构 [{id, function:{name, arguments}}]。"""
        out = []
        for idx in sorted(buf.keys()):
            slot = buf[idx]
            out.append({"id": slot["id"] or f"call_{idx}",
                        "function": {"name": slot["name"], "arguments": slot["arguments"]}})
        return out

    @staticmethod
    def _raise_stream_http(r: httpx.Response, body: str,
                           tools_requested: bool = False) -> None:
        detail = body
        try:
            detail = _json.loads(body).get("error") or body
            if isinstance(detail, dict):
                detail = str(detail.get("message") or detail)
        except _json.JSONDecodeError:
            pass
        # 带 tools 请求返回 400 且与工具相关 → 后端不支持工具（转降级事件，非致命）
        if r.status_code == 400 and tools_requested and (
                "tool" in str(detail).lower() or "function" in str(detail).lower()):
            raise _ToolsUnsupported(str(detail))
        if r.status_code in (401, 403):
            raise NetworkGuardError(
                f"对话请求失败：服务拒绝访问（HTTP {r.status_code}）。{str(detail)[:300]}".strip(),
                _host_of(str(r.url)))
        raise OllamaAPIError(f"对话请求失败（HTTP {r.status_code}）", r.status_code, str(detail)[:300])

    @staticmethod
    def _raise_http(r: httpx.Response, prefix: str) -> None:
        detail = r.text[:300]
        if r.status_code in (401, 403):
            raise NetworkGuardError(f"{prefix}：服务拒绝访问（HTTP {r.status_code}）。{detail}".strip(),
                                    _host_of(str(r.url)))
        raise OllamaAPIError(f"{prefix}（HTTP {r.status_code}）", r.status_code, detail)

    async def list_models(self) -> list[dict[str, Any]]:
        client = await self._client()
        r = await client.get(f"{self._base()}/models")
        r.raise_for_status()
        data = r.json().get("data", [])
        return [{"name": m.get("id", "")} for m in data if m.get("id")]


class _ToolsUnsupported(Exception):
    """带 tools 请求被 400 拒绝且判定为工具不支持 → 转降级事件（非致命）。"""
