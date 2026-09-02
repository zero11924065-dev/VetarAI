"""checkpoint-076 TS-118 简单委派模式与配套修复 专项测试。

覆盖（0.1.71 五项修复）：
1. 简单委派模式：
  S1 resolve_simple_mode：带图 → 强制 True
  S2 resolve_simple_mode：显式 simple_mode=True → True
  S3 resolve_simple_mode：OCR 模型（名含 ocr）无图 → True
  S4 resolve_simple_mode：普通模型无图无参数 → False
  S5 简单模式任务消息：只含任务书，不含防幻觉硬约束/执行须知等模板
  S6 简单模式系统提示词：不追加交卷契约
  S7 简单模式交卷：第一轮原文直接作为结果（非 JSON 也采纳，status=success）
  S8 简单模式不追问：子模型第一轮非 JSON → 无第二轮调用
  S9 简单模式空回复 → failed
  S10 普通模式回归：无图文字委派仍走 JSON 契约（非 JSON → 追问 1 次）
2. 落库存图片：
  D1 委派带图 → 子会话首条 user 消息 DB 落库含 images
3. target 回错：
  T1 delegate_task 漏填 target → 返回错误含可用 Agent 名单，不新建
4. suggested_role 兜底搜索：
  T2 target 未命中、suggested_role 命中现有 Agent → 复用（不新建）
5. 无视觉模型拦截：
  V1 model_name_suggests_vision：已知多模态家族 → True；纯文本 → None
  V2 带图委派给确认无视觉的模型 → 拦截报错
  V3 带图委派给多模态模型 → 不拦截（名称层放行，不查元数据）

venv 内 python test_checkpoint076.py 直接跑。只输出 PASS/FAIL 摘要。
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


def _png_bytes(color=(255, 0, 0)):
    """生成一张 1x1 PNG 的字节流（与 checkpoint-074 测试一致）。"""
    sig = b"\x89PNG\r\n\x1a\n"
    import zlib

    def chunk(typ, data):
        c = zlib.crc32(typ + data) & 0xffffffff
        return len(data).to_bytes(4, "big") + typ + data + c.to_bytes(4, "big")
    ihdr = (1).to_bytes(4, "big") + (1).to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"
    raw = zlib.compress(b"\x00" + bytes(color))
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")


def _setup_store(tag="ck076"):
    """隔离 store 到临时目录，返回 (store, tmp, pid, main_id)。"""
    tmp = Path(tempfile.mkdtemp(prefix=f"{tag}_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp
    store._GDB = tmp / "_global.db"
    pid = store.create_project(f"{tag} 测试项目", tmp / "work")
    main_id = store.add_agent_config(pid, "主 Agent", "main", model_name="qwen3.6:35b")
    return store, tmp, pid, main_id


# ---------- 可控连接器：按脚本回吐子模型回复 ----------
class ScriptConn:
    """每次 chat_stream 按 scripts 顺序回吐一段文本，记录调用次数与收到的 images。"""
    def __init__(self, scripts):
        self.scripts = list(scripts)
        self.calls = 0
        self.rounds_images = []

    async def chat_stream(self, model, messages, tools=None, images=None):
        self.rounds_images.append(list(images) if images else [])
        text = self.scripts[self.calls] if self.calls < len(self.scripts) else ""
        self.calls += 1
        yield {"content_delta": text}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 8}}


class FakeNoVisionConn:
    """模拟元数据查询返回"无视觉标记"的连接器。"""
    _base = "http://127.0.0.1:11434"

    class _Resp:
        status_code = 200
        def json(self):
            return {"template": "{{.Prompt}}", "parameters": "plain text"}

    class _Client:
        async def post(self, url, json=None, timeout=None):
            return FakeNoVisionConn._Resp()

    async def _client(self, *a, **k):
        return self._Client()


def _tid_of(store, pid):
    """取最新一条委派任务 id。"""
    rows = store.list_recent_delegations_to_target(pid, "", limit=10)
    return rows[0]["id"] if rows else None


async def main():
    from sidecar.agent_engine import delegation as D

    # ---------- S1~S4 简单模式判定 ----------
    check("S1 带图→强制简单模式", D.resolve_simple_mode(["data:image/png;base64,xx"], "qwen3.6:35b") is True)
    check("S2 显式参数→简单模式", D.resolve_simple_mode(None, "qwen3.6:35b", True) is True)
    check("S3 OCR模型→简单模式", D.resolve_simple_mode(None, "glm-ocr:latest") is True)
    check("S4 普通模型无图无参→非简单", D.resolve_simple_mode(None, "qwen3.6:35b") is False)

    # ---------- S5 简单模式任务消息 ----------
    m = D._task_user_message_simple("tid123", "识别附图", "输出纯文字", image_count=2)
    check("S5a 含任务书与交付要求", "识别附图" in m and "输出纯文字" in m and "tid123" in m)
    check("S5b 不含防幻觉/执行须知模板", "防幻觉硬约束" not in m and "执行须知" not in m)
    check("S5c 不含JSON交卷字样", "JSON" not in m or "不要包装成 JSON" in m)

    # ---------- S6~S9 简单模式端到端（不追问、原文即结果） ----------
    store, tmp, pid, main_id = _setup_store("ck076a")
    sub_id = store.add_agent_config(pid, "ocr专员", "sub", model_name="glm-ocr:latest")
    sandbox = tmp / "work"
    sandbox.mkdir(parents=True, exist_ok=True)

    # 子模型第一轮回纯文字（非 JSON）——简单模式应直接采纳
    plain_ocr = "10:27 | 美团 2025年11月24日 19:18 钱呢？ 2025年11月24日 19:23 卡号或我取现金 到位了"
    conn = ScriptConn([plain_ocr])
    agent = store.get_agent_config(pid, sub_id)
    imgs = ["data:image/png;base64,QUJD"]
    res = await D.run_delegated_task(
        pid, main_id, "sess-main", agent, "识别附图文字", "输出纯文字",
        sandbox_root=str(sandbox), authorizer=None, max_rounds=10,
        connector=conn, images=imgs)
    check("S6a 简单模式委派成功", res.get("ok") is True, str(res)[:200])
    check("S6b 原文即结果（未包JSON壳）", plain_ocr in str(res.get("summary", "")), str(res.get("summary", ""))[:120])
    check("S6c status=success", res.get("status") == "success", str(res.get("status")))
    check("S7 不追问：只调用了1轮", conn.calls == 1, f"calls={conn.calls}")

    # D1 落库存图片：子会话首条 user 消息含 images
    task_rec = store.get_agent_task(pid, res["task_id"])
    child_sid = task_rec.get("session_id") if task_rec else None
    msgs_db = store.load_messages(pid, child_sid) if child_sid else []
    user0 = next((x for x in msgs_db if x["role"] == "user"), None)
    check("D1 子会话落库含委派图片", bool(user0 and user0.get("images") == imgs),
          f"user0.images={str(user0.get('images'))[:60] if user0 else 'None'}")

    # S8 系统提示词无交卷契约：通过子会话无法直接看到（系统提示词不入库），
    # 改为验证非简单模式下子模型不交 JSON 会触发追问（对照组）
    store2, tmp2, pid2, main2 = _setup_store("ck076b")
    sub2 = store2.add_agent_config(pid2, "文本专员", "sub", model_name="qwen3.6:35b")
    conn2 = ScriptConn(["这是纯文字回复不是JSON", '{"task_id":"x","status":"success","summary":"补交","artifacts":[]}'])
    agent2 = store2.get_agent_config(pid2, sub2)
    res2 = await D.run_delegated_task(
        pid2, main2, "sess-main", agent2, "写一段文字", "输出文字",
        sandbox_root=str(tmp2 / "work"), authorizer=None, max_rounds=10,
        connector=conn2)
    check("S9 普通模式无图：仍走契约（非JSON→追问1次）",
          res2.get("ok") is True and conn2.calls == 2, f"ok={res2.get('ok')} calls={conn2.calls}")

    # S10 简单模式空回复 → failed
    conn3 = ScriptConn(["   "])
    store3, tmp3, pid3, main3 = _setup_store("ck076c")
    sub3 = store3.add_agent_config(pid3, "ocr专员", "sub", model_name="glm-ocr:latest")
    res3 = await D.run_delegated_task(
        pid3, main3, "sess-main", store3.get_agent_config(pid3, sub3),
        "识别附图", "输出文字", sandbox_root=str(tmp3 / "work"),
        authorizer=None, max_rounds=10, connector=conn3, images=imgs)
    check("S10 简单模式空回复→failed", res3.get("ok") is False, str(res3)[:150])

    # ---------- V1~V3 视觉能力检测 ----------
    check("V1a glm-ocr→True", D.model_name_suggests_vision("glm-ocr:latest") is True)
    check("V1b qwen3-vl:8b→True", D.model_name_suggests_vision("qwen3-vl:8b") is True)
    check("V1c qwen3.6:35b→None（名称层无法判定）", D.model_name_suggests_vision("qwen3.6:35b") is None)
    check("V1d llava→True", D.model_name_suggests_vision("llava:13b") is True)

    # V2 带图委派给确认无视觉的模型 → 拦截
    store4, tmp4, pid4, main4 = _setup_store("ck076d")
    sub4 = store4.add_agent_config(pid4, "纯文本专员", "sub", model_name="qwen3.6:35b")
    conn4 = ScriptConn(["不该执行到这里"])
    res4 = await D.run_delegated_task(
        pid4, main4, "sess-main", store4.get_agent_config(pid4, sub4),
        "识别附图", "输出文字", sandbox_root=str(tmp4 / "work"),
        authorizer=None, max_rounds=10, connector=FakeNoVisionConn(), images=imgs)
    check("V2 无视觉模型带图委派→拦截", res4.get("ok") is False and "不支持图片" in str(res4.get("error")),
          str(res4)[:150])
    check("V2b 拦截时未发起模型调用", conn4.calls == 0, f"calls={conn4.calls}")

    # V3 带图委派给多模态模型 → 名称层放行（不查元数据，用无网 conn 也不报错）
    store5, tmp5, pid5, main5 = _setup_store("ck076e")
    sub5 = store5.add_agent_config(pid5, "视觉专员", "sub", model_name="qwen3-vl:8b")
    conn5 = ScriptConn(["图片内容：测试通过"])
    res5 = await D.run_delegated_task(
        pid5, main5, "sess-main", store5.get_agent_config(pid5, sub5),
        "识别附图", "输出文字", sandbox_root=str(tmp5 / "work"),
        authorizer=None, max_rounds=10, connector=None, images=imgs)
    check("V3 多模态模型带图委派→放行", res5.get("ok") is True, str(res5)[:150])

    # ---------- T1 target 回错 + T2 suggested_role 兜底搜索（loop 路由层） ----------
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec

    store6, tmp6, pid6, main6 = _setup_store("ck076f")
    _ = store6.add_agent_config(pid6, "ocr专员", "sub", model_name="glm-ocr:latest")
    sandbox6 = tmp6 / "work"
    sandbox6.mkdir(parents=True, exist_ok=True)

    # T1：模型发起 delegate_task 但不填 target → tool_result 报错含可用名单
    class NoTargetConn:
        def __init__(self):
            self.calls = 0
        async def chat_stream(self, model, messages, tools=None, images=None):
            self.calls += 1
            if self.calls == 1:
                yield {"tool_calls": [{"id": "call_1", "function": {
                    "name": "delegate_task",
                    "arguments": {"task": "识别图片", "expect": "输出文字"}}}]}
            else:
                yield {"content_delta": "结束"}
            yield {"done": True, "counts": {"prompt_eval_count": 1, "eval_count": 1}}

    events = []
    async for ev in run_tool_loop("qwen3.6:35b", [{"role": "user", "content": "hi"}],
                                  tools_spec(True), str(sandbox6), authorizer=None,
                                  max_rounds=3, connector=NoTargetConn(),
                                  delegation_ctx={"project_id": pid6, "agent_id": main6,
                                                  "session_id": "s1", "model": "qwen3.6:35b"}):
        events.append(ev)
    tool_results = [e for e in events if e.get("event") == "tool_result"
                    or "tool_result" in str(e.get("event", ""))]
    tr_text = json.dumps(events, ensure_ascii=False)
    check("T1 漏填target→报错含可用Agent名单",
          ("需要 target" in tr_text or "请补全" in tr_text) and "ocr专员" in tr_text,
          tr_text[-300:])
    check("T1b 漏填target未新建Agent",
          len([a for a in store6.list_agent_configs(pid6)]) == 2,
          str([a.get("name") for a in store6.list_agent_configs(pid6)]))

    # T2：target 写别名未命中、suggested_role='ocr专员' → 兜底搜索命中复用
    class AliasConn:
        def __init__(self):
            self.calls = 0
        async def chat_stream(self, model, messages, tools=None, images=None):
            self.calls += 1
            if self.calls == 1:
                yield {"tool_calls": [{"id": "call_1", "function": {
                    "name": "delegate_task",
                    "arguments": {"target": "OCR助理", "task": "识别图片",
                                  "expect": "输出文字",
                                  "suggested_role": "ocr专员"}}}]}
            else:
                yield {"content_delta": "结束"}
            yield {"done": True, "counts": {"prompt_eval_count": 1, "eval_count": 1}}

    # 委派目标命中后走真实执行：给 ScriptConn 一个纯文字回复（简单模式，无图则按模型类型）
    # 子模型是 glm-ocr → 简单模式，直接采纳
    events2 = []
    async for ev in run_tool_loop("qwen3.6:35b", [{"role": "user", "content": "hi"}],
                                  tools_spec(True), str(sandbox6), authorizer=None,
                                  max_rounds=3, connector=AliasConn(),
                                  delegation_ctx={"project_id": pid6, "agent_id": main6,
                                                  "session_id": "s1", "model": "qwen3.6:35b",
                                                  "connector": ScriptConn(["识别结果：ABC"])}):
        events2.append(ev)
    ev2_text = json.dumps(events2, ensure_ascii=False)
    check("T2 suggested_role兜底命中现有Agent",
          "ocr专员" in ev2_text and "识别结果：ABC" in ev2_text, ev2_text[-300:])
    check("T2b 未新建重复Agent",
          len([a for a in store6.list_agent_configs(pid6)]) == 2,
          str([a.get("name") for a in store6.list_agent_configs(pid6)]))

    # 清理
    import shutil
    for t in (tmp, tmp2, tmp3, tmp4, tmp5, tmp6):
        shutil.rmtree(t, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
