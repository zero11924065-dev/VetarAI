"""TS-112 M6 推理后端抽象专项单测（mock httpx，venv 内直接跑，需 PYTHONPATH）。
覆盖：配置校验 / 能力表 / 工厂分发 / OpenAI 兼容流式解析（content/thinking/tool_calls 分块/
[DONE]/usage 映射）/ 工具不支持降级 / 图片转换与降级 / 异常语义 / 端点守卫。
只输出 PASS/FAIL 摘要。
"""
import asyncio
import json
import json as _jsonm
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

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


def sse_lines(chunks):
    """把 OpenAI SSE chunk 列表转成 aiter_lines 的文本行。"""
    return ["data: " + json.dumps(c, ensure_ascii=False) for c in chunks] + ["data: [DONE]"]


class FakeStreamResp:
    def __init__(self, lines, status=200, body=""):
        self._lines = lines
        self.status_code = status
        self._body = body
        self.url = "http://fake/chat/completions"  # 异常路径读取 r.url

    async def __aenter__(self): return self

    async def __aexit__(self, *a): return False

    async def aread(self):
        return self._body.encode("utf-8")

    async def aiter_lines(self):
        for ln in self._lines:
            yield ln


class FakeClient:
    """mock httpx.AsyncClient：记录请求 + 按脚本返回。"""

    def __init__(self, script):
        self.script = script
        self.requests = []

    async def __aenter__(self): return self

    async def __aexit__(self, *a): return False

    async def post(self, url, json=None, **kw):
        self.requests.append(("POST", url, json))
        return self.script

    async def get(self, url, **kw):
        self.requests.append(("GET", url, None))
        return self.script

    def stream(self, method, url, json=None, **kw):
        """httpx 的 stream 是同步方法，返回上下文管理器（非协程）。"""
        self.requests.append((method, url, json))
        return self.script

    async def aclose(self): pass


async def collect_stream(conn, model="m", messages=None, tools=None, images=None):
    events = []
    async for ev in conn.chat_stream(model, messages or [{"role": "user", "content": "hi"}],
                                     tools=tools, images=images):
        events.append(ev)
    return events


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="m6_"))
    import sidecar.config as cfgmod
    # 隔离 data_root（工厂单例依赖配置）
    cfgmod.data_root = lambda: TMP / "dataroot"
    cfgmod._MEM = {}
    # 让 config 读写指向临时文件
    _cfg_path = TMP / "config.json"
    cfgmod.get_config_path = lambda: _cfg_path
    from sidecar.config import reload_config, get_config

    # ══ 1. 配置校验 ══
    reload_config({"inference_backend": "ollama"})
    check("1a backend 合法枚举可保存", get_config()["inference_backend"] == "ollama")
    try:
        reload_config({"inference_backend": "bad_backend"})
        check("1b 非法 backend 拒绝", False, "未抛错")
    except ValueError:
        check("1b 非法 backend 拒绝", True)
    try:
        reload_config({"inference_backend": "openai_compatible", "inference_base_url": ""})
        check("1c openai_compatible 空地址拒绝", False, "未抛错")
    except ValueError:
        check("1c openai_compatible 空地址拒绝", True)
    reload_config({"inference_backend": "openai_compatible",
                   "inference_base_url": "http://localhost:1234/v1"})
    check("1d openai_compatible + 地址可保存",
          get_config()["inference_base_url"] == "http://localhost:1234/v1")
    try:
        reload_config({"openai_compat_supports_tools": "yes"})
        check("1e tools 开关非 bool 拒绝", False, "未抛错")
    except ValueError:
        check("1e tools 开关非 bool 拒绝", True)
    reload_config({"openai_compat_supports_tools": True})

    # ══ 2. 能力表 + 工厂分发 ══
    import sidecar.ollama.connector as connmod
    from sidecar.ollama.connector import OllamaConnector
    from sidecar.ollama.openai_compat import OpenAICompatConnector

    connmod._SINGLETON = None
    connmod._OPENAI_SINGLETON = None
    reload_config({"inference_backend": "ollama", "inference_base_url": ""})
    c_ollama = connmod.get_inference_connector()
    check("2a ollama 后端 → OllamaConnector", isinstance(c_ollama, OllamaConnector))
    caps = c_ollama.capabilities()
    check("2b ollama 能力表（tools/vision/pull/delete 全 True）",
          caps == {"backend": "ollama", "tools": True, "vision": True,
                   "pull": True, "delete": True}, str(caps))

    reload_config({"inference_backend": "openai_compatible",
                   "inference_base_url": "http://localhost:1234/v1"})
    connmod._OPENAI_SINGLETON = None
    c_oai = connmod.get_inference_connector()
    check("2c openai_compatible 后端 → OpenAICompatConnector", isinstance(c_oai, OpenAICompatConnector))
    caps2 = c_oai.capabilities()
    check("2d openai 能力表（pull/delete False）",
          caps2["backend"] == "openai_compatible" and caps2["pull"] is False
          and caps2["delete"] is False and caps2["tools"] is True, str(caps2))
    check("2e 别名等价（get_ollama_connector 跟随工厂）",
          connmod.get_ollama_connector() is c_oai)
    # 关闭工具开关 → 能力表反映
    reload_config({"openai_compat_supports_tools": False})
    check("2f tools 开关关闭 → 能力表 tools=False",
          connmod.get_inference_connector().capabilities()["tools"] is False)
    reload_config({"openai_compat_supports_tools": True})

    # ══ 3. OpenAI 兼容流式解析 ══
    # 3a content 增量 + [DONE] + usage 计数
    script3a = FakeStreamResp(sse_lines([
        {"choices": [{"delta": {"content": "你"}}]},
        {"choices": [{"delta": {"content": "好"}}]},
        {"choices": [{"delta": {}, "finish_reason": "stop"}],
         "usage": {"prompt_tokens": 10, "completion_tokens": 2}},
    ]))
    fake = FakeClient(script3a)
    c_oai._clients = {}
    c_oai._state = None
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(fake))
    evs = await collect_stream(c_oai)
    deltas = [e["content_delta"] for e in evs if "content_delta" in e]
    done_ev = next((e for e in evs if e.get("done")), None)
    check("3a content 增量拼接 + usage 映射",
          "".join(deltas) == "你好" and done_ev is not None
          and done_ev["counts"]["prompt_eval_count"] == 10
          and done_ev["counts"]["eval_count"] == 2, str(evs)[:200])

    # 3b reasoning_content → thinking_delta
    script3b = FakeStreamResp(sse_lines([
        {"choices": [{"delta": {"reasoning_content": "思考中"}}]},
        {"choices": [{"delta": {"content": "答"}}]},
    ]))
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(script3b)))
    evs = await collect_stream(c_oai)
    check("3b reasoning_content → thinking_delta",
          any(e.get("thinking_delta") == "思考中" for e in evs)
          and any(e.get("content_delta") == "答" for e in evs), str(evs)[:200])

    # 3c tool_calls 跨块拼装（name 与 arguments 分三块）
    script3c = FakeStreamResp(sse_lines([
        {"choices": [{"delta": {"tool_calls": [
            {"index": 0, "id": "call_1", "function": {"name": "read_", "arguments": ""}}]}}]},
        {"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"arguments": "{\"pa"}}]}}]},
        {"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"arguments": "th\":\"a.txt\"}"}}]}}]},
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
    ]))
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(script3c)))
    evs = await collect_stream(c_oai)
    tc_ev = next((e for e in evs if "tool_calls" in e), None)
    check("3c tool_calls 跨块拼装（name+arguments 完整）",
          tc_ev is not None and len(tc_ev["tool_calls"]) == 1
          and tc_ev["tool_calls"][0]["function"]["name"] == "read_"
          and tc_ev["tool_calls"][0]["function"]["arguments"] == '{"path":"a.txt"}',
          str(tc_ev)[:200] if tc_ev else "无")

    # 3d 无 usage → 计数 0
    script3d = FakeStreamResp(sse_lines([{"choices": [{"delta": {"content": "x"}}]}]))
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(script3d)))
    evs = await collect_stream(c_oai)
    done_ev = next((e for e in evs if e.get("done")), None)
    check("3d 无 usage → 计数 0",
          done_ev is not None and done_ev["counts"]["prompt_eval_count"] == 0, str(done_ev))

    # ══ 4. 带 tools 请求 400 → stream_error 降级 ══
    script4 = FakeStreamResp([], status=400,
                             body=json.dumps({"error": "tool calling is not supported"}))
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(script4)))
    evs = await collect_stream(c_oai, tools=[{"type": "function", "function": {"name": "x"}}])
    err_ev = next((e for e in evs if "stream_error" in e), None)
    check("4 带 tools 请求 400 → stream_error 含不支持工具调用",
          err_ev is not None and "不支持工具调用" in err_ev["stream_error"], str(evs)[:200])

    # ══ 5. 图片转换与多模态降级 ══
    # 5a data URI → image_url content 结构
    parts = c_oai._image_parts(["data:image/png;base64,QUJD"])
    check("5a data URI → image_url 结构",
          len(parts) == 1 and parts[0]["type"] == "image_url"
          and parts[0]["image_url"]["url"] == "data:image/png;base64,QUJD", str(parts))
    # 5b 超大图丢弃
    big = "data:image/png;base64," + "A" * 9_000_000
    check("5b 超大图（>8MB）丢弃", c_oai._image_parts([big]) == [])
    # 5c 合并入最后一条 user 消息
    msgs = [{"role": "system", "content": "s"}, {"role": "user", "content": "看图"}]
    merged = c_oai._merge_images_into_messages(msgs, parts)
    last = merged[-1]
    check("5c 图片合入最后一条 user 消息（content 数组）",
          isinstance(last["content"], list) and last["content"][0]["type"] == "text"
          and last["content"][0]["text"] == "看图" and last["content"][1]["type"] == "image_url",
          str(last)[:200])
    # 5d chat() 400 含图 → 剥图重试 + 降级文案
    class TwoStepClient(FakeClient):
        def __init__(self, first_status=400):
            super().__init__(None)
            self.calls = 0
            self.first_status = first_status

        async def post(self, url, json=None, **kw):
            self.calls += 1
            self.requests.append(("POST", url, json))
            if self.calls == 1:
                fs = self.first_status
                class R:
                    status_code = fs
                    text = "images not supported"

                    def json(self): return {}
                return R()

            class R2:
                status_code = 200

                def json(self):
                    return {"choices": [{"message": {"content": "答案"}}]}
            return R2()
    two = TwoStepClient()
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(two))
    reply = await c_oai.chat("m", [{"role": "user", "content": "看图"}],
                             images=["data:image/png;base64,QUJD"])
    check("5d 400 含图 → 剥图重试 + 多模态降级文案",
          two.calls == 2 and "答案" in reply and "不支持多模态" in reply, reply[:150])

    # 5e chat() 500 含图 → 剥图重试 + 降级文案（checkpoint-041：Ollama 部分模型返回 500）
    two5 = TwoStepClient(first_status=500)
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(two5))
    reply5 = await c_oai.chat("m", [{"role": "user", "content": "看图"}],
                              images=["data:image/png;base64,QUJD"])
    check("5e 500 含图 → 剥图重试 + 多模态降级文案",
          two5.calls == 2 and "答案" in reply5 and "不支持多模态" in reply5, reply5[:150])

    # 5f ollama chat() 500 含图 → 剥图重试 + 降级文案（同款降级）
    c_ol = OllamaConnector(base_url="http://127.0.0.1:11434")
    class TwoStepOllama(TwoStepClient):
        async def post(self, url, json=None, **kw):
            r = await super().post(url, json=json, **kw)
            if self.calls == 2:
                class RO:
                    status_code = 200
                    def json(self): return {"message": {"content": "纯文本答案"}}
                return RO()
            return r
    tol = TwoStepOllama(first_status=500)
    c_ol._clients = {}
    c_ol._state = None
    c_ol._client = (lambda reading=300.0, connect=10.0: _aclient(tol))
    reply_ol = await c_ol.chat("m", [{"role": "user", "content": "看图"}],
                               images=["data:image/png;base64,QUJD"])
    check("5f ollama 500 含图 → 剥图重试 + 多模态降级文案",
          tol.calls == 2 and "纯文本答案" in reply_ol and "不支持多模态" in reply_ol,
          reply_ol[:150])

    # 5g openai chat_stream() 500 含图 → 降级文案入 content_delta + done
    class TwoStepStream(FakeClient):
        def __init__(self, first_status=500, ndjson_retry=False):
            super().__init__(None)
            self.calls = 0
            self.first_status = first_status
            self.ndjson_retry = ndjson_retry

        def stream(self, method, url, json=None, **kw):
            self.calls += 1
            self.requests.append((method, url, json))
            return FakeStreamResp([], status=self.first_status,
                                  body='{"error": "image input is not supported"}')

        async def post(self, url, json=None, **kw):
            self.calls += 1
            self.requests.append(("POST", url, json))
            if self.ndjson_retry:
                # 模拟服务端无视 stream 参数仍返回多行流式响应（SSE 格式）
                body = ('data: {"choices":[{"delta":{"content":"降"}}]}\n'
                        'data: {"choices":[{"delta":{"content":"级"}}]}\n'
                        'data: [DONE]\n')
                class RND:
                    status_code = 200
                    text = body
                    def json(self): raise _jsonm.JSONDecodeError("Extra data", body, 41)
                return RND()
            class R2:
                status_code = 200
                text = '{"choices": [{"message": {"content": "降级答案"}}]}'
                def json(self): return {"choices": [{"message": {"content": "降级答案"}}]}
            return R2()
    ts = TwoStepStream()
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(ts))
    evs5g = await collect_stream(c_oai, images=["data:image/png;base64,QUJD"])
    txt5g = "".join(e.get("content_delta", "") for e in evs5g)
    retry_body = ts.requests[1][2] if len(ts.requests) > 1 else {}
    check("5g openai 流式 500 含图 → 剥图降级（文案+done+重发非流式）",
          ts.calls == 2 and "不支持多模态" in txt5g
          and any(e.get("done") for e in evs5g)
          and retry_body.get("stream") is False, str(evs5g)[:200])

    # 5i openai 流式降级重发遇多行 SSE → 防御解析不抛 Extra data
    tsi = TwoStepStream(ndjson_retry=True)
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(tsi))
    evs5i = await collect_stream(c_oai, images=["data:image/png;base64,QUJD"])
    txt5i = "".join(e.get("content_delta", "") for e in evs5i)
    check("5i 重发多行响应 → 逐行解析（无 Extra data）",
          "降级" in txt5i and "不支持多模态" in txt5i
          and any(e.get("done") for e in evs5i), str(evs5i)[:200])

    # 5h ollama chat_stream() 500 含图 → 降级文案入 content_delta + done
    class TwoStepStreamOllama(TwoStepStream):
        async def post(self, url, json=None, **kw):
            self.calls += 1
            self.requests.append(("POST", url, json))
            if self.ndjson_retry:
                body = ('{"message":{"content":"降"}}\n'
                        '{"message":{"content":"级"}}\n')
                class RND:
                    status_code = 200
                    text = body
                    def json(self): raise _jsonm.JSONDecodeError("Extra data", body, 28)
                return RND()
            class RO:
                status_code = 200
                text = '{"message": {"content": "降级答案"}}'
                def json(self): return {"message": {"content": "降级答案"}}
            return RO()
    tsol = TwoStepStreamOllama()
    c_ol._client = (lambda reading=300.0, connect=10.0: _aclient(tsol))
    evs5h = await collect_stream(c_ol, images=["data:image/png;base64,QUJD"])
    txt5h = "".join(e.get("content_delta", "") for e in evs5h)
    retry_body_ol = tsol.requests[1][2] if len(tsol.requests) > 1 else {}
    check("5h ollama 流式 500 含图 → 剥图降级（文案+done+重发非流式）",
          tsol.calls == 2 and "不支持多模态" in txt5h
          and any(e.get("done") for e in evs5h)
          and retry_body_ol.get("stream") is False, str(evs5h)[:200])

    # 5j ollama 流式降级重发遇多行 NDJSON → 防御解析不抛 Extra data
    tsj = TwoStepStreamOllama(ndjson_retry=True)
    c_ol._client = (lambda reading=300.0, connect=10.0: _aclient(tsj))
    evs5j = await collect_stream(c_ol, images=["data:image/png;base64,QUJD"])
    txt5j = "".join(e.get("content_delta", "") for e in evs5j)
    check("5j 重发多行 NDJSON → 逐行解析（无 Extra data）",
          "降级" in txt5j and "不支持多模态" in txt5j
          and any(e.get("done") for e in evs5j), str(evs5j)[:200])

    # ══ 6. 异常语义 ══
    from sidecar.network.guard import NetworkGuardError
    from sidecar.ollama.connector import OllamaAPIError
    script6a = FakeStreamResp([], status=401, body="unauthorized")
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(script6a)))
    try:
        await collect_stream(c_oai)
        check("6a 401 → NetworkGuardError", False, "未抛错")
    except NetworkGuardError:
        check("6a 401 → NetworkGuardError", True)
    except Exception as e:
        check("6a 401 → NetworkGuardError", False, f"抛了 {type(e).__name__}")
    script6b = FakeStreamResp([], status=404, body=json.dumps({"error": "model not found"}))
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(script6b)))
    try:
        await collect_stream(c_oai)
        check("6b 404 → OllamaAPIError", False, "未抛错")
    except OllamaAPIError:
        check("6b 404 → OllamaAPIError", True)
    except Exception as e:
        check("6b 404 → OllamaAPIError", False, f"抛了 {type(e).__name__}")

    # ══ 7. list_models（/v1/models 归一化）══
    class ModelsResp:
        status_code = 200

        def raise_for_status(self): pass

        def json(self):
            return {"data": [{"id": "qwen2.5:7b"}, {"id": "llama3.1"}]}
    c_oai._client = (lambda reading=300.0, connect=10.0: _aclient(FakeClient(ModelsResp())))
    models = await c_oai.list_models()
    check("7 /v1/models 归一化为 [{name}]",
          models == [{"name": "qwen2.5:7b"}, {"name": "llama3.1"}], str(models))

    # ══ 8. 端点守卫（pull/delete 非 ollama → 400）══
    from fastapi.testclient import TestClient
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    from sidecar import app as appmod
    appmod.get_config = get_config  # 用临时配置
    client = TestClient(appmod.app)
    reload_config({"inference_backend": "openai_compatible",
                   "inference_base_url": "http://localhost:1234/v1"})
    connmod._OPENAI_SINGLETON = None
    r = client.post("/api/ollama/pull", json={"name": "x"})
    check("8a 非 ollama 后端 pull → 400", r.status_code == 400
          and "不支持模型拉取" in r.json().get("detail", ""), str(r.status_code) + r.text[:100])
    r = client.delete("/api/ollama/models/x")
    check("8b 非 ollama 后端 delete → 400", r.status_code == 400
          and "不支持模型删除" in r.json().get("detail", ""), str(r.status_code) + r.text[:100])
    # /api/context/limit 非 ollama → unsupported
    r = client.get("/api/context/limit", params={"model": "qwen3.8"})
    check("8c 非 ollama 后端 context/limit → unsupported",
          r.json().get("source") == "unsupported" and r.json().get("context_length") == 0,
          str(r.json()))
    # /api/inference/status
    r = client.get("/api/inference/status")
    d = r.json()
    check("8d /api/inference/status 含后端与能力表",
          d.get("backend") == "openai_compatible" and "capabilities" in d
          and d["capabilities"]["pull"] is False, str(d)[:200])

    # ══ 9. 工具能力降级（配置关闭 → stream 端点不传工具）══
    reload_config({"openai_compat_supports_tools": False,
                   "inference_backend": "openai_compatible",
                   "inference_base_url": "http://localhost:1234/v1"})
    # gen() 内 _tools_enabled 读能力表；用 TestClient 发请求验证降级提示词注入
    # （此处仅验证能力表传导，完整流式由前端测试覆盖）
    caps_now = connmod.get_inference_connector().capabilities()
    check("9 tools 开关关闭 → 能力表 tools=False（端点据此降级）",
          caps_now["tools"] is False, str(caps_now))

    # ══ 10. 配置恢复 ══
    reload_config({"inference_backend": "ollama", "inference_base_url": "",
                   "inference_api_key": "", "openai_compat_supports_tools": True})
    final = get_config()
    check("10 配置恢复默认（backend=ollama）",
          final["inference_backend"] == "ollama" and final["inference_base_url"] == ""
          and final["inference_api_key"] == "" and final["openai_compat_supports_tools"] is True)

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M6 推理后端抽象专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


async def _aclient(fake):
    return fake


def _client_factory(fake):
    """非 async 工厂：_client 是 async，但这里直接返回 fake。"""
    async def _f(reading=300.0, connect=10.0):
        return fake
    return _f


if __name__ == "__main__":
    asyncio.run(main())
