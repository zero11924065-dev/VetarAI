"""Ollama HTTP API connector with timeout handling and vision auto-detection.

All outbound requests go through the network guard (P1-3). Ollama is local
(127.0.0.1 / localhost) so it is always allowed; the guard is a no-op for it.
"""
from __future__ import annotations

import base64
import json as _json
import httpx
from pathlib import Path
from typing import Any

from sidecar.network.guard import guard_request, NetworkGuardError
from sidecar.config import get_config

# 超时拆分（P1-4 回归修复）：
#   CONNECT/代理握手 10s —— 防空转卡死（guard 发起前拒绝不受影响）
#   推理/读取 300s —— 正常长回复不被掐断
# 禁止用单一全局大数糊弄。
CONNECT_TIMEOUT = 10.0
READING_TIMEOUT = 300.0

# 流式（SSE）专用超时：qwen3.8 带 thinking 时，工具调用决策/两 token 间隙
# 可能超过 300s，故流式 read 独立放大（按"两 token 间隙"语义，非单字节）。
# checkpoint-067 R-2（用户拍板"完整优先，宁慢勿断"）：律所分析大量客户材料时，
# 本地模型对超大输入的 prefill（首 token 前的处理）可能远超 600s。
# 放宽到 1800s（30 分钟），允许本地模型慢慢处理，宁可慢也不中途超时断层。
# 仍保留 connect 10s 防空转。
STREAM_READ_TIMEOUT = 1800.0


def _host_of(base_url: str) -> str:
    from urllib.parse import urlparse
    return (urlparse(base_url).hostname or "")


class OllamaAPIError(RuntimeError):
    """Ollama 业务错误（模型不存在/参数非法/超限等）→ app.py 映射 400。

    与 NetworkGuardError 分离：网络/guard 拒绝 → 403；业务错误 → 400。
    """
    def __init__(self, message: str, status_code: int = 400, detail: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        self.detail = detail


class OllamaConnector:
    def __init__(self, base_url: str | None = None) -> None:
        if base_url is None:
            base_url = get_config()["ollama_base_url"]
        self._base = base_url.rstrip("/")
        self._host = _host_of(self._base)
        # TS-103 B09：实例级 client 复用。key=(proxy, reading, connect) → 共享 client。
        # 配置指纹（Ollama 地址/网络开关/代理端口）变化 → 关闭旧 client 重建（见 _client）。
        self._clients: dict[tuple, httpx.AsyncClient] = {}
        self._state: tuple | None = None

    def _config_state(self) -> tuple:
        """配置指纹：决定出站路径的全部配置项（B09 重建判据）。

        延迟导入（与 guard._cfg 同款）：每次调用读最新 config，
        设置面板改 ollama_base_url/network_switch/代理端口后即时生效。
        """
        from sidecar.config import get_config as _gc
        cfg = _gc()
        return (cfg.get("ollama_base_url", ""),
                str(cfg.get("network_switch", "off")).lower(),
                int(cfg.get("proxy_http_port", 0)))

    async def aclose_all(self) -> None:
        """关闭全部共享 client（应用退出时调用）。"""
        for c in self._clients.values():
            await c.aclose()
        self._clients.clear()
        self._state = None

    def capabilities(self) -> dict[str, Any]:
        """M6（TS-112）：后端能力表（端点守卫与前端渲染的唯一事实源）。"""
        return {"backend": "ollama", "tools": True, "vision": True,
                "pull": True, "delete": True}

    def _guard(self) -> dict[str, str] | None:
        """Run this connector's host through the guard; return proxies or raise."""
        proxies, reason = guard_request(self._host)
        if reason is not None:
            raise NetworkGuardError(reason, self._host)
        return proxies

    async def _client(self, reading: float = READING_TIMEOUT,
                      connect: float = CONNECT_TIMEOUT) -> httpx.AsyncClient:
        """TS-103 B09：返回共享复用的 client（调用方不得关闭）。

        每次调用先比对配置指纹：Ollama 地址/网络开关/代理端口任一变化 →
        关闭旧 client 并按新 base/host 重建（设置面板改配置即时生效，无需重启）。
        """
        state = self._config_state()
        if state != self._state:
            self._base = state[0].rstrip("/")
            self._host = _host_of(self._base)
            for c in self._clients.values():
                await c.aclose()
            self._clients.clear()
            self._state = state
        proxies = self._guard()
        proxy = proxies["http"] if proxies else None
        key = (proxy, reading, connect)
        client = self._clients.get(key)
        if client is None or client.is_closed:
            # trust_env=False（2026-08-28 修复）：禁止 httpx 拾取环境变量代理
            # （HTTP_PROXY 等）——出站路径必须 100% 由守卫决定，否则环境变量
            # 会绕过守卫的"唯一漏斗"契约，把境内流量也劫持到未监听的代理端口。
            kwargs: dict[str, Any] = {"timeout": httpx.Timeout(reading, connect=connect),
                                      "trust_env": False}
            if proxy:
                kwargs["proxy"] = proxy
            client = httpx.AsyncClient(**kwargs)
            self._clients[key] = client
        return client

    async def list_models(self) -> list[dict[str, Any]]:
        client = await self._client()
        r = await client.get(f"{self._base}/api/tags")
        r.raise_for_status()
        return r.json().get("models", [])

    async def chat(
        self,
        model: str,
        messages: list[dict[str, Any]],
        *,
        stream: bool = False,
        images: list[str] | None = None,
    ) -> str:
        """Send a non-streaming chat request with vision support auto-detection.

        Timeout: connect 10s (防空转) + reading 300s (长回复不中断). 非 2xx 不重试;
        we raise a NetworkGuardError with a clear Chinese message (403 included).
        """
        payload: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "stream": False,
        }

        dropped_images = 0
        if images:
            parsed_images = []
            for img in images:
                parsed = self._parse_image(img)
                if parsed:
                    parsed_images.append(parsed)
                else:
                    dropped_images += 1
            if parsed_images:
                last_msg = payload["messages"][-1] if payload["messages"] else {}
                merged = {**last_msg, "images": parsed_images}
                if payload["messages"]:
                    payload["messages"] = payload["messages"][:-1] + [merged]

        client = await self._client()
        r = await client.post(f"{self._base}/api/chat", json=payload)

        # 400/500 + 带图 → 模型不支持图片，剥图重试一次（M6 checkpoint-041：
        # Ollama 对部分模型的图片不支持返回 500 server_error，而非 400）
        if r.status_code in (400, 500) and "images" in (payload.get("messages") or [])[-1]:
            msgs = list(payload["messages"])
            del msgs[-1]["images"]
            payload["messages"] = msgs
            r2 = await client.post(f"{self._base}/api/chat", json=payload)
            if r2.status_code != 200:
                self._raise_http(r2, "对话请求失败")
            data = r2.json()
            content = (data.get("message") or {}).get("content", "")
            note = "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"
            if dropped_images:
                note += f"\n\n[⚠️ {dropped_images} 张图片过大已丢弃，未参与分析。]"
            return content + note

        if r.status_code != 200:
            self._raise_http(r, "对话请求失败")

        note = (f"\n\n[⚠️ {dropped_images} 张图片过大已丢弃，未参与分析。]" if dropped_images else "")
        try:
            data = r.json()
            return (data.get("message") or {}).get("content", "") + note
        except Exception:
            text = r.text
            if text.strip().startswith('{'):
                try:
                    return _json.loads(text).get("message", {}).get("content", "") + note
                except Exception:
                    pass
            return text + note

    async def chat_stream(
        self,
        model: str,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        images: list[str] | None = None,
    ) -> Any:
        """流式 /api/chat（M1-2）：stream:true，逐行解析 SSE，yield 结构化事件。

        yield 事件（dict）：
          {"content_delta": "..."}            模型文本增量
          {"thinking_delta": "..."}           模型思考增量（TS-102 B13：不再丢弃）
          {"tool_calls": [{id,name,arguments}]}  工具调用（Ollama 原生结构）
          {"done": True, "counts": {"prompt_eval_count": int, "eval_count": int}}
          {"stream_error": "..."}            流中途超时兜底（不裸抛异常）

        超时沿用 _client()：connect 10s / read 300s；过 guard；非 200 → OllamaAPIError。
        """
        payload: dict[str, Any] = {"model": model, "messages": messages, "stream": True}
        if tools:
            payload["tools"] = tools
        # M6（TS-112）图片入流：图片合入最后一条 user 消息（Ollama 格式：images=base64 列表）
        if images:
            parsed_images = []
            for img in images:
                parsed = self._parse_image(img)
                if parsed:
                    parsed_images.append(parsed)
            if parsed_images:
                msgs = list(payload["messages"])
                for i in range(len(msgs) - 1, -1, -1):
                    if msgs[i].get("role") == "user":
                        merged = {**msgs[i], "images": parsed_images}
                        msgs[i] = merged
                        break
                payload["messages"] = msgs
        # 流式独立超时（STREAM_READ_TIMEOUT），覆盖 qwen thinking 间隙；connect 仍 10s
        client = await self._client(reading=STREAM_READ_TIMEOUT)
        # M6 checkpoint-041：流式非 200（400/500 图片不支持等）→ 剥图重试 +
        # 降级文案（与 chat() 同款），文案命中前端视觉引导卡片渲染条件。
        had_images = any("images" in m for m in payload["messages"])
        try:
            async with client.stream("POST", f"{self._base}/api/chat", json=payload) as r:
                if r.status_code != 200:
                    body = (await r.aread()).decode("utf-8", errors="replace")
                    if r.status_code in (400, 500) and had_images:
                        for m in payload["messages"]:
                            m.pop("images", None)
                        # checkpoint-042：重发必须用 stream=False——否则 Ollama
                        # 返回多行 NDJSON，一次性 .json() 抛 "Extra data"
                        retry_payload = {**payload, "stream": False}
                        r2 = await client.post(f"{self._base}/api/chat", json=retry_payload)
                        if r2.status_code != 200:
                            self._raise_http(r2, "对话请求失败")
                        text = r2.text
                        try:
                            content = (r2.json().get("message") or {}).get("content", "")
                        except _json.JSONDecodeError:
                            # 防御：万一仍为多行流式响应 → 逐行解析拼接
                            content = ""
                            for ln in text.splitlines():
                                ln = ln.strip()
                                if not ln:
                                    continue
                                try:
                                    content += (( _json.loads(ln).get("message") or {}).get("content", ""))
                                except _json.JSONDecodeError:
                                    continue
                        yield {"content_delta": content +
                               "\n\n[⚠️ 当前模型不支持多模态，图片未参与分析。建议切换到视觉模型（如 qwen2.5-vl）后重试。]"}
                        yield {"done": True, "counts": {
                            "prompt_eval_count": 0, "eval_count": 0}}
                        return
                    self._raise_stream_http(r, body)
                async for line in r.aiter_lines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = _json.loads(line)
                    except _json.JSONDecodeError:
                        continue
                    msg = obj.get("message") or {}
                    # TS-102 B13：thinking 增量透传（旧版只取 content，思考期前端全静默）
                    th = msg.get("thinking")
                    if th:
                        yield {"thinking_delta": th}
                    delta = msg.get("content")
                    if delta:
                        yield {"content_delta": delta}
                    tcs = msg.get("tool_calls")
                    if tcs:
                        yield {"tool_calls": tcs}
                    if obj.get("done"):
                        yield {"done": True, "counts": {
                            "prompt_eval_count": int(obj.get("prompt_eval_count") or 0),
                            "eval_count": int(obj.get("eval_count") or 0),
                        }}
        except httpx.TimeoutException:
            # 兜底：流中途超时不裸抛，转为结构化 error 事件（loop/app 层转 SSE error）
            yield {"stream_error": "模型响应超时，已停止。已完成部分见上方事件。"}

    @staticmethod
    def _raise_stream_http(r: httpx.Response, body: str) -> None:
        """流式请求非 2xx 统一错误出口（不重试，语义分离沿用 P1-3）。"""
        detail = ""
        try:
            detail = _json.loads(body).get("error") or body
        except _json.JSONDecodeError:
            detail = body
        if r.status_code in (400, 404):
            raise OllamaAPIError(f"对话请求失败: {detail}", status_code=r.status_code, detail=detail)
        raise NetworkGuardError(f"对话请求失败(HTTP {r.status_code}): {detail}", _host_of(get_config()["ollama_base_url"]))

    @staticmethod
    def _raise_http(r: httpx.Response, prefix: str) -> None:
        """非 2xx 统一错误出口（不重试）。

        - 401/403 → NetworkGuardError（连接/鉴权级，app.py 映射 403）
        - 其余 4xx/5xx → OllamaAPIError（业务错误，app.py 映射 400 + 原始 detail）
        """
        detail = r.text[:300]
        if r.status_code in (401, 403):
            raise NetworkGuardError(
                f"{prefix}：服务拒绝访问（HTTP {r.status_code}）。{detail}".strip(),
                _host_of(r.url),
            )
        # Ollama 业务错误（模型不存在=404、参数非法=400 等）
        raise OllamaAPIError(f"{prefix}（HTTP {r.status_code}）", r.status_code, detail)

    def _parse_image(self, img_src: str) -> str | None:
        if img_src.startswith('data:'):
            b64 = img_src.split(',', 1)[1] if ',' in img_src else ''
            return b64
        elif Path(img_src).exists():
            return base64.b64encode(Path(img_src).read_bytes()).decode('ascii')
        elif len(img_src) > 50:
            # 视为已编码 base64/大图；若超大则丢弃（返回 None），禁止静默截断成半图
            if len(img_src) > 8_000_000:   # ~8MB base64 上限
                return None
            return img_src
        return None

    async def pull_model(self, name: str) -> list[str]:
        events = []
        client = await self._client(reading=60.0)
        async with client.stream("POST", f"{self._base}/api/pull", json={"name": name}) as r:
            r.raise_for_status()
            async for line in r.aiter_lines():
                if line.strip():
                    events.append(line)
        return events

    async def delete_model(self, name: str) -> bool:
        client = await self._client()
        r = await client.delete(f"{self._base}/api/delete", json={"name": name})
        return r.status_code == 200

    async def unload_model(self, name: str) -> bool:
        """0.2.1（TS-119）：立即卸载指定模型，释放显存/内存。

        机制：Ollama 官方语义——发送 keep_alive=0 的请求即令模型立即从内存卸载
        （用空消息 /api/chat 触发，Ollama 会应用 keep_alive 并卸载）。
        工作流引擎在"下一节点模型不同"时调用；相同模型连续节点不卸载。
        失败（Ollama 未运行/模型未加载）静默返回 False，不阻塞流程。
        """
        try:
            client = await self._client()
            r = await client.post(f"{self._base}/api/chat",
                                  json={"model": name, "messages": [], "stream": False,
                                        "keep_alive": 0}, timeout=15)
            return r.status_code == 200
        except Exception:
            return False


# TS-103 B18：模块级单例——app.py 各端点共用一个 connector（client 池复用）。
# 配置变化（ollama_base_url / network_switch / proxy_http_port）由 _client()
# 的配置指纹检测自动重建连接，无需重启或重建实例。
_SINGLETON: OllamaConnector | None = None
# M6（TS-112）：OpenAI 兼容后端单例（与 Ollama 各自一个实例，按配置分发）
_OPENAI_SINGLETON: Any = None


def get_inference_connector() -> Any:
    """M6（TS-112）：推理后端工厂——按配置 inference_backend 分发单例。

    返回对象事件协议一致（content_delta/thinking_delta/tool_calls/done/stream_error），
    调用方（loop/委派/圆桌/压缩）零改动自动跟随当前后端。
    """
    global _SINGLETON, _OPENAI_SINGLETON
    backend = str(get_config().get("inference_backend", "ollama")).strip()
    if backend == "openai_compatible":
        if _OPENAI_SINGLETON is None:
            from sidecar.ollama.openai_compat import OpenAICompatConnector
            _OPENAI_SINGLETON = OpenAICompatConnector()
        return _OPENAI_SINGLETON
    if _SINGLETON is None:
        _SINGLETON = OllamaConnector()
    return _SINGLETON


def get_ollama_connector() -> OllamaConnector:
    """全局 connector 单例入口（唯一合法用法；禁止端点内再 OllamaConnector()）。

    M6（TS-112）：保留为工厂别名——既有全部调用点（loop/委派/圆桌/压缩/端点）
    零改动自动跟随当前推理后端。返回类型标注维持 OllamaConnector 兼容旧代码。
    """
    return get_inference_connector()  # type: ignore[return-value]
