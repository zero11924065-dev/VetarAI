"""checkpoint-077 TS-119 工作流引擎 专项测试。

覆盖：
  L1 线性流程（start→inference→end）
  L2 条件分支（静态匹配 true/false）
  L3 条件分支（动态裁判模型）
  L4 并行节点（branches 并发）
  L5 循环节点（items 逐项 + {{item}}）
  L6 审批节点（批准继续）
  L7 审批节点（驳回失败）
  L8 工具节点（写文件）
  L9 重试（失败后重试成功）
  L10 取消（运行中停止）
  L11 模板渲染（{{node.output}} / {{params.x}} / {{item}}）
  M1 模型切换卸载：不同模型 → 先卸旧
  M2 模型切换卸载：相同模型 → 不卸
  M3 结束卸载：工作流结束卸载最后驻留模型
  M4 推理纯调用：不带 tools、无系统提示词（OCR 场景）
  V1 定义校验：缺 end / 孤岛节点 / 重复 id
  S1 存储层：工作流 + 运行记录 + 节点事件 CRUD

venv 内 python test_checkpoint077.py 直接跑。只输出 PASS/FAIL 摘要。
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


# ---------- 假连接器：记录调用与卸载 ----------
class FakeConn:
    """记录每次 chat 调用与 unload_model 调用。"""
    def __init__(self, replies=None):
        # replies: dict[model] -> list[str]（按调用顺序消费）或 str
        self.replies = replies or {}
        self.chat_calls = []      # (model, messages, images)
        self.unloads = []         # model
        self._idx = {}

    async def chat(self, model, messages, images=None, **kw):
        self.chat_calls.append((model, messages, images))
        r = self.replies.get(model, "默认回复")
        if isinstance(r, list):
            i = self._idx.get(model, 0)
            self._idx[model] = i + 1
            return r[i] if i < len(r) else r[-1]
        return r

    async def unload_model(self, model):
        self.unloads.append(model)
        return True


def _defn(nodes, edges):
    return {"nodes": nodes, "edges": edges, "params": {}}


def _n(nid, ntype, **kw):
    return {"id": nid, "type": ntype, **kw}


async def _run_engine(definition, conn, params=None, tmp=None, run_id="run-test"):
    from sidecar.workflow.engine import WorkflowEngine
    sandbox = str(tmp) if tmp else tempfile.mkdtemp()
    engine = WorkflowEngine(run_id, definition, conn, sandbox, params=params or {})
    events = []
    async for ev in engine.run():
        events.append(ev)
    return events


def _store_isolate():
    tmp = Path(tempfile.mkdtemp(prefix="ck077_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp
    store._GDB = tmp / "_global.db"
    return store, tmp


async def main():
    from sidecar.workflow.schema import validate_definition, default_start_definition
    import sidecar.storage.store as store

    # 0.2.2 修正：必须最先隔离存储——引擎测试（L1/F1~F7 等）内部的
    # update_workflow_run / append_workflow_node_event 会写 store._GDB；
    # 若延后隔离，引擎测试会污染真实全局库（~/.subagent）。
    s, stmp = _store_isolate()

    # ===== V1 定义校验 =====
    errs = validate_definition(_defn([_n("s", "start"), _n("e", "end")], [{"from": "s", "to": "e"}]))
    check("V1a 合法最简流程", errs == [], str(errs))
    errs = validate_definition(_defn([_n("s", "start")], []))
    check("V1b 缺 end → 报错", any("结束节点" in e for e in errs), str(errs))
    errs = validate_definition(_defn(
        [_n("s", "start"), _n("a", "inference", model="m"), _n("iso", "inference", model="m"), _n("e", "end")],
        [{"from": "s", "to": "a"}, {"from": "a", "to": "e"}]))
    check("V1c 孤岛节点 → 报错", any("未与开始节点连通" in e for e in errs), str(errs))
    errs = validate_definition(_defn(
        [_n("s", "start"), _n("s", "start"), _n("e", "end")],
        [{"from": "s", "to": "e"}]))
    check("V1d 重复 id / 多 start → 报错", len(errs) > 0, str(errs))

    # ===== L1 线性流程 =====
    conn = FakeConn({"glm-ocr:latest": "识别结果：你好"})
    defn = _defn(
        [_n("s", "start"), _n("n1", "inference", model="glm-ocr:latest", prompt="识别 {{params.img}}"),
         _n("e", "end", output="{{n1.output}}")],
        [{"from": "s", "to": "n1"}, {"from": "n1", "to": "e"}])
    evs = await _run_engine(defn, conn, params={"img": "1.jpg"})
    types = [e["event"] for e in evs]
    # 3 个节点（start/推理/end）各一对 start+done，最后终态
    check("L1a 线性流程事件序",
          types == ["node_start", "node_done"] * 3 + ["workflow_done"], str(types))
    done = [e for e in evs if e["event"] == "workflow_done"][0]
    check("L1b 结果透传", "识别结果" in str(done["data"].get("result_preview", "")), str(done["data"]))
    # M4 推理纯调用：无 tools、无 system 消息
    model, messages, images = conn.chat_calls[0]
    check("M4a 纯调用只有 user 消息", len(messages) == 1 and messages[0]["role"] == "user", str(messages))
    check("M4b 模板渲染参数", "识别 1.jpg" in messages[0]["content"], messages[0]["content"])

    # ===== L2 条件分支（静态） =====
    conn = FakeConn({"m": "内容包含 关键词钱 在内"})
    defn = _defn(
        [_n("s", "start"),
         _n("infer", "inference", model="m", prompt="分析"),
         _n("cond", "condition", match={"variable": "infer.output", "operator": "contains", "value": "钱"}),
         _n("hit", "end", output="命中分支"),
         _n("miss", "end", output="未命中分支")],
        [{"from": "s", "to": "infer"}, {"from": "infer", "to": "cond"},
         {"from": "cond", "to": "hit", "when": "true"},
         {"from": "cond", "to": "miss", "when": "false"}])
    evs = await _run_engine(defn, conn)
    done = [e for e in evs if e["event"] == "workflow_done"][0]
    check("L2a 条件命中走 true 分支", "命中分支" in str(done["data"].get("result_preview", "")), str(done["data"]))

    # 反向：不含关键词 → false 分支
    conn2 = FakeConn({"m": "内容里没有那个词"})
    evs = await _run_engine(defn, conn2)
    done = [e for e in evs if e["event"] == "workflow_done"][0]
    check("L2b 条件不中走 false 分支", "未命中分支" in str(done["data"].get("result_preview", "")), str(done["data"]))

    # ===== L3 条件分支（动态裁判） =====
    conn3 = FakeConn({"judge": "是"})
    defn3 = _defn(
        [_n("s", "start"),
         _n("cond", "condition", model="judge", prompt="这是图片吗？只回答是/否"),
         _n("yes", "end", output="是图片"),
         _n("no", "end", output="不是图片")],
        [{"from": "s", "to": "cond"},
         {"from": "cond", "to": "yes", "when": "是"},
         {"from": "cond", "to": "no", "when": "否"}])
    evs = await _run_engine(defn3, conn3)
    done = [e for e in evs if e["event"] == "workflow_done"][0]
    check("L3 动态裁判走对应分支", "是图片" in str(done["data"].get("result_preview", "")), str(done["data"]))

    # ===== L4 并行节点 =====
    conn4 = FakeConn({"m1": "结果A", "m2": "结果B"})
    defn4 = _defn(
        [_n("s", "start"),
         _n("p", "parallel", branches=["a", "b"]),
         _n("a", "inference", model="m1", prompt="任务A"),
         _n("b", "inference", model="m2", prompt="任务B"),
         _n("e", "end", output="{{p.output}}")],
        [{"from": "s", "to": "p"}, {"from": "p", "to": "e"}])
    evs = await _run_engine(defn4, conn4)
    done = [e for e in evs if e["event"] == "workflow_done"][0]
    rp = str(done["data"].get("result_preview", ""))
    check("L4 并行收集各分支输出", "结果A" in rp and "结果B" in rp, rp)

    # ===== L5 循环节点 =====
    conn5 = FakeConn({"m": "item-result"})
    defn5 = _defn(
        [_n("s", "start"),
         _n("loop", "loop", items="{{params.list}}", branch="body"),
         _n("body", "inference", model="m", prompt="处理 {{item}}"),
         _n("e", "end", output="{{loop.output}}")],
        [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"}])
    evs = await _run_engine(defn5, conn5, params={"list": ["a", "b", "c"]})
    # 验证循环体被调用 3 次，且 {{item}} 渲染正确
    prompts = [c[1][0]["content"] for c in conn5.chat_calls]
    check("L5a 循环逐项执行", len(conn5.chat_calls) == 3, str(len(conn5.chat_calls)))
    check("L5b item 渲染", prompts == ["处理 a", "处理 b", "处理 c"], str(prompts))

    # ===== L5c~L5d 循环分批（0.2.3）=====
    conn5c = FakeConn({"m": "batch-result"})
    defn5c = _defn(
        [_n("s", "start"),
         _n("loop", "loop", items="{{params.list}}", branch="body", batch_size=2),
         _n("body", "inference", model="m", prompt="处理 {{item}}"),
         _n("e", "end", output="{{loop.output}}")],
        [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"}])
    # 5 个元素、每批 2 个 → 3 批（2/2/1）
    evs = await _run_engine(defn5c, conn5c, params={"list": ["a", "b", "c", "d", "e"]})
    check("L5c 分批轮数", len(conn5c.chat_calls) == 3, str(len(conn5c.chat_calls)))
    # 前两批 {{item}} 为列表（渲染为 JSON），最后一批单元素
    prompts5c = [c[1][0]["content"] for c in conn5c.chat_calls]
    check("L5d 分批item为列表", '["a", "b"]' in prompts5c[0] and '["c", "d"]' in prompts5c[1]
          and prompts5c[2] == "处理 e", str(prompts5c))

    # ===== L5e 循环体逗号分隔顺序链（0.2.3）=====
    conn5e = FakeConn({"m": "step"})
    defn5e = _defn(
        [_n("s", "start"),
         _n("loop", "loop", items="{{params.list}}", branch="n1, n2"),
         _n("n1", "inference", model="m", prompt="第一步 {{item}}"),
         _n("n2", "inference", model="m", prompt="第二步 {{n1.output}}"),
         _n("e", "end", output="{{loop.output}}")],
        [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"}])
    evs = await _run_engine(defn5e, conn5e, params={"list": ["x"]})
    # 1 项 × 2 步 = 2 次调用
    check("L5e 逗号顺序链", len(conn5e.chat_calls) == 2, str(len(conn5e.chat_calls)))
    prompts5e = [c[1][0]["content"] for c in conn5e.chat_calls]
    check("L5e2 链内引用上游输出", "第一步 x" in prompts5e[0] and "第二步 step" in prompts5e[1], str(prompts5e))

    # ===== L6/L7 审批节点 =====
    from sidecar.workflow.engine import WorkflowEngine, resolve_workflow_approval

    def _approval_defn():
        return _defn(
            [_n("s", "start"), _n("ap", "approval", message="确认继续？"), _n("e", "end", output="通过")],
            [{"from": "s", "to": "ap"}, {"from": "ap", "to": "e"}])

    # L6 批准：起任务 → 等 approval_required → 批准 → 完成
    conn6 = FakeConn({})
    sandbox6 = tempfile.mkdtemp()
    engine6 = WorkflowEngine("run-ap", _approval_defn(), conn6, sandbox6)
    events6 = []
    agen6 = engine6.run().__aiter__()
    # 消费到 approval_required
    async def _consume_until(agen, target):
        while True:
            ev = await agen.__anext__()
            events6.append(ev)
            if ev["event"] == target:
                return ev
    await _consume_until(agen6, "approval_required")
    check("L6a 审批挂起事件", events6[-1]["event"] == "approval_required", str(events6[-1]))
    await asyncio.sleep(0.05)
    resolve_workflow_approval("run-ap", True, "同意")
    # 继续消费到终态
    async for ev in agen6:
        events6.append(ev)
        if ev["event"] in ("workflow_done", "workflow_failed", "workflow_stopped"):
            break
    t6 = [e["event"] for e in events6]
    check("L6b 批准后完成", "workflow_done" in t6, str(t6))

    # L7 驳回：批准为 False → 工作流失败（审批被驳回）
    conn7 = FakeConn({})
    engine7 = WorkflowEngine("run-ap2", _approval_defn(), conn7, tempfile.mkdtemp())
    events7 = []
    agen7 = engine7.run().__aiter__()
    async def _consume_until7(agen, target):
        while True:
            ev = await agen.__anext__()
            events7.append(ev)
            if ev["event"] == target:
                return ev
    await _consume_until7(agen7, "approval_required")
    await asyncio.sleep(0.05)
    resolve_workflow_approval("run-ap2", False, "不行")
    async for ev in agen7:
        events7.append(ev)
        if ev["event"] in ("workflow_done", "workflow_failed", "workflow_stopped"):
            break
    t7 = [e["event"] for e in events7]
    check("L7 驳回后失败", "workflow_failed" in t7, str(t7))

    # ===== L8 工具节点（写文件） =====
    tmp8 = Path(tempfile.mkdtemp(prefix="ck077_tool_"))
    conn8 = FakeConn({})
    defn8 = _defn(
        [_n("s", "start"),
         _n("t", "tool", tool="write_file", args={"path": "out.txt", "content": "写入内容 {{params.x}}"}),
         _n("e", "end", output="ok")],
        [{"from": "s", "to": "t"}, {"from": "t", "to": "e"}])
    evs = await _run_engine(defn8, conn8, params={"x": "XYZ"}, tmp=tmp8, run_id="run-tool")
    done8 = [e for e in evs if e["event"] == "workflow_done"]
    check("L8a 工具节点成功", len(done8) == 1, str([e["event"] for e in evs]))
    check("L8b 文件真实写入", (tmp8 / "out.txt").exists() and (tmp8 / "out.txt").read_text(encoding="utf-8") == "写入内容 XYZ",
          str(tmp8 / "out.txt"))

    # ===== L9 重试 =====
    # 假连接器：第 1 次抛错，第 2 次成功
    class FlakyConn:
        def __init__(self):
            self.calls = 0
            self.unloads = []
        async def chat(self, model, messages, images=None, **kw):
            self.calls += 1
            if self.calls == 1:
                raise RuntimeError("临时故障")
            return "重试成功"
        async def unload_model(self, model):
            self.unloads.append(model)
            return True
    conn9 = FlakyConn()
    defn9 = _defn(
        [_n("s", "start"), _n("n", "inference", model="m", prompt="x", retry=2), _n("e", "end", output="{{n.output}}")],
        [{"from": "s", "to": "n"}, {"from": "n", "to": "e"}])
    evs = await _run_engine(defn9, conn9, run_id="run-retry")
    done9 = [e for e in evs if e["event"] == "workflow_done"]
    check("L9 重试后成功", len(done9) == 1 and conn9.calls == 2, f"calls={conn9.calls}")

    # ===== M1/M2/M3 模型卸载规则 =====
    # M1 不同模型：A → B，B 执行前卸 A
    connm = FakeConn({"modelA": "resA", "modelB": "resB"})
    defn_m = _defn(
        [_n("s", "start"),
         _n("n1", "inference", model="modelA", prompt="a"),
         _n("n2", "inference", model="modelB", prompt="b"),
         _n("e", "end")],
        [{"from": "s", "to": "n1"}, {"from": "n1", "to": "n2"}, {"from": "n2", "to": "e"}])
    evs = await _run_engine(defn_m, connm, run_id="run-m1")
    # 卸载 modelA（切换时）+ 卸载 modelB（结束时）
    check("M1 切换时卸旧模型", connm.unloads[0] == "modelA", str(connm.unloads))
    check("M3 结束时卸最后模型", "modelB" in connm.unloads, str(connm.unloads))

    # M2 相同模型连续：不中途卸载，只在结束卸一次
    connm2 = FakeConn({"same": ["r1", "r2"]})
    defn_m2 = _defn(
        [_n("s", "start"),
         _n("n1", "inference", model="same", prompt="a"),
         _n("n2", "inference", model="same", prompt="b"),
         _n("e", "end")],
        [{"from": "s", "to": "n1"}, {"from": "n1", "to": "n2"}, {"from": "n2", "to": "e"}])
    evs = await _run_engine(defn_m2, connm2, run_id="run-m2")
    check("M2 相同模型不中途卸载", connm2.unloads == ["same"], str(connm2.unloads))

    # ===== L10 取消 =====
    from sidecar.workflow.engine import request_workflow_cancel, clear_workflow_cancel
    # 用一个很慢的连接器：第二次调用前取消
    class SlowConn:
        def __init__(self):
            self.calls = 0
            self.unloads = []
        async def chat(self, model, messages, images=None, **kw):
            self.calls += 1
            if self.calls == 1:
                return "第一段"
            await asyncio.sleep(5)  # 慢，给取消机会
            return "不该到达"
        async def unload_model(self, model):
            self.unloads.append(model)
            return True
    connc = SlowConn()
    defn_c = _defn(
        [_n("s", "start"),
         _n("n1", "inference", model="m", prompt="a"),
         _n("n2", "inference", model="m", prompt="b"),
         _n("e", "end")],
        [{"from": "s", "to": "n1"}, {"from": "n1", "to": "n2"}, {"from": "n2", "to": "e"}])
    engine_c = WorkflowEngine("run-cancel", defn_c, connc, tempfile.mkdtemp())
    events_c = []
    async def _consume_c():
        async for ev in engine_c.run():
            events_c.append(ev)
            if ev["event"] == "node_done" and ev["data"].get("node_id") == "n1":
                request_workflow_cancel("run-cancel")
            if ev["event"] in ("workflow_done", "workflow_failed", "workflow_stopped"):
                break
    await _consume_c()
    t_c = [e["event"] for e in events_c]
    check("L10 取消后走 stopped", "workflow_stopped" in t_c, str(t_c))
    clear_workflow_cancel("run-cancel")

    # ===== S1 存储层 =====
    s, stmp = _store_isolate()
    wid = s.create_workflow("存储测试", default_start_definition(), "desc")
    check("S1a 创建工作流", bool(wid), wid)
    check("S1b 查询工作流", s.get_workflow(wid)["name"] == "存储测试")
    s.update_workflow(wid, name="改名")
    check("S1c 更新工作流", s.get_workflow(wid)["name"] == "改名")
    check("S1d 列表含1条", len(s.list_workflows()) == 1)
    rid = s.create_workflow_run(wid, {"k": "v"})
    check("S1e 创建运行", bool(rid))
    s.update_workflow_run(rid, status="awaiting_approval", current_node="n1")
    check("S1f 更新运行状态", s.get_workflow_run(rid)["status"] == "awaiting_approval")
    s.append_workflow_node_event(rid, "n1", "inference", "done", model_used="m", duration_ms=100)
    check("S1g 节点事件落库", len(s.list_workflow_node_events(rid)) == 1)
    check("S1h 运行列表", len(s.list_workflow_runs(wid)) == 1)
    check("S1i 删除工作流", s.delete_workflow(wid) is True)

    # ===== A1 端点层：半成品工作流可创建/保存（0.2.1 用户报障修复）=====
    # 现象：新建空白工作流（只有开始节点）被"必须至少有一个结束节点"拦截，无法创建。
    # 修复：创建/保存端点不做结构校验（编辑中途的半成品必须能存），
    #       严格校验只把"运行"关（/run 返回 422）。
    import sidecar.logging_setup as _ls
    _ls.setup_logging = lambda: ""  # 隔离：不触碰真实日志目录
    from fastapi.testclient import TestClient
    import sidecar.app as app_mod
    client = TestClient(app_mod.app)

    half_def = default_start_definition()  # 只有开始节点
    r = client.post("/api/workflows", json={"name": "半成品测试", "definition": half_def})
    check("A1a 创建半成品工作流成功（0.2.1 修复）", r.status_code == 200 and r.json().get("ok"),
          f"{r.status_code} {r.text[:150]}")
    half_id = r.json().get("id", "")
    r = client.put(f"/api/workflows/{half_id}", json={"name": "半成品测试2", "definition": half_def})
    check("A1b 保存半成品工作流成功（0.2.1 修复）", r.status_code == 200 and r.json().get("ok"),
          f"{r.status_code} {r.text[:150]}")
    r = client.post(f"/api/workflows/{half_id}/run", json={"params": {}})
    check("A1c 运行半成品被校验拦截（422）", r.status_code == 422 and "结束节点" in r.text,
          f"{r.status_code} {r.text[:150]}")
    # 清理
    client.delete(f"/api/workflows/{half_id}")

    # ===== F1~F9 文件输入/输出节点（0.2.2） =====
    # F1 文件输入：单文件 → 单元素路径列表
    ftmp = Path(tempfile.mkdtemp(prefix="ck077_files_"))
    (ftmp / "a.jpg").write_text("img-a", encoding="utf-8")
    conn_f = FakeConn({})
    defn_f1 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp / "a.jpg")),
         _n("e", "end", output="{{fin.output}}")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "e"}])
    evs = await _run_engine(defn_f1, conn_f, run_id="run-f1")
    fin_out = None
    done_f1 = [e for e in evs if e["event"] == "workflow_done"]
    check("F1 文件输入单文件", len(done_f1) == 1, str([e["event"] for e in evs]))

    # F2 文件输入：文件夹 + 扩展名过滤
    (ftmp / "b.png").write_text("img-b", encoding="utf-8")
    (ftmp / "c.txt").write_text("txt-c", encoding="utf-8")
    defn_f2 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp), extensions="jpg, png"),
         _n("e", "end", output="{{fin.output}}")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "e"}])
    conn_f2 = FakeConn({})
    eng_f2 = None
    from sidecar.workflow.engine import WorkflowEngine as _WE2
    eng_f2 = _WE2("run-f2", defn_f2, conn_f2, str(ftmp))
    events_f2 = []
    async for ev in eng_f2.run():
        events_f2.append(ev)
    out_f2 = eng_f2.variables["fin"]["output"]
    check("F2 扩展名过滤", len(out_f2) == 2 and all(p.endswith((".jpg", ".png")) for p in out_f2), str(out_f2))

    # F3 文件输入：递归子目录
    sub = ftmp / "sub"
    sub.mkdir(exist_ok=True)
    (sub / "d.jpg").write_text("img-d", encoding="utf-8")
    defn_f3 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp), extensions="jpg", recursive=True),
         _n("e", "end")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "e"}])
    eng_f3 = _WE2("run-f3", defn_f3, FakeConn({}), str(ftmp))
    async for _ in eng_f3.run():
        pass
    out_f3 = eng_f3.variables["fin"]["output"]
    check("F3 递归子目录", len(out_f3) == 2, str(out_f3))

    # F4 文件输入：路径不存在 → 失败
    defn_f4 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp / "不存在")),
         _n("e", "end")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "e"}])
    evs_f4 = await _run_engine(defn_f4, FakeConn({}), run_id="run-f4")
    check("F4 路径不存在→失败", any(e["event"] == "workflow_failed" for e in evs_f4),
          str([e["event"] for e in evs_f4]))

    # F5 文件输出：写文件 + 内容模板
    out_dir = ftmp / "out"
    defn_f5 = _defn(
        [_n("s", "start"),
         _n("gen", "inference", model="m", prompt="产出"),
         _n("fout", "file_output", dir=str(out_dir), filename="result.md",
            content="# 结果\n{{gen.output}}"),
         _n("e", "end", output="{{fout.output}}")],
        [{"from": "s", "to": "gen"}, {"from": "gen", "to": "fout"}, {"from": "fout", "to": "e"}])
    conn_f5 = FakeConn({"m": "识别出的文字"})
    evs_f5 = await _run_engine(defn_f5, conn_f5, run_id="run-f5")
    fp5 = out_dir / "result.md"
    check("F5a 文件输出写入", fp5.exists(), str(fp5))
    check("F5b 内容模板渲染", fp5.exists() and "识别出的文字" in fp5.read_text(encoding="utf-8"),
          fp5.read_text(encoding="utf-8") if fp5.exists() else "")

    # F6 文件输出：filename 路径穿越防护
    defn_f6 = _defn(
        [_n("s", "start"),
         _n("fout", "file_output", dir=str(out_dir), filename="../escape.md", content="x"),
         _n("e", "end")],
        [{"from": "s", "to": "fout"}, {"from": "fout", "to": "e"}])
    evs_f6 = await _run_engine(defn_f6, FakeConn({}), run_id="run-f6")
    check("F6 文件名路径穿越被拒", any(e["event"] == "workflow_failed" for e in evs_f6),
          str([e["event"] for e in evs_f6]))

    # F7 文件输入→循环（顺序链：推理→保存）完整管线（每图一文件）
    # 注意：有依赖的步骤必须用顺序链（分支为列表），不能用 parallel（并发竞态读空）
    out_dir7 = ftmp / "out7"
    defn_f7 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp / "sub"), extensions="jpg"),
         _n("loop", "loop", items="{{fin.output}}", branch=["gen", "fout"]),
         _n("gen", "inference", model="m", prompt="识别 {{item}}"),
         _n("fout", "file_output", dir=str(out_dir7), filename="{{item_index}}.md",
            content="{{gen.output}}"),
         _n("e", "end")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "loop"}, {"from": "loop", "to": "e"}])
    conn_f7 = FakeConn({"m": "OCR结果"})
    eng_f7 = _WE2("run-f7", defn_f7, conn_f7, str(ftmp))
    evs_f7 = []
    async for ev in eng_f7.run():
        evs_f7.append(ev)
    check("F7a 管线完成", any(e["event"] == "workflow_done" for e in evs_f7),
          str([e["event"] for e in evs_f7][-3:]))
    md_files = sorted(out_dir7.glob("*.md")) if out_dir7.exists() else []
    check("F7b 每图一个md文件", len(md_files) == 1, str(md_files))
    check("F7c md内容为模型输出", md_files and "OCR结果" in md_files[0].read_text(encoding="utf-8"),
          md_files[0].read_text(encoding="utf-8") if md_files else "")

    # ===== F8 图片自动继承（0.2.3 核心修复）=====
    # 用户场景：文件输入 → 推理节点（未配 images）→ 模型应自动收到上游的图片。
    # 修复前推理节点 images 为空 → 模型收不到图 → HTTP 500 / 空转。
    conn_f8 = FakeConn({"m": "继承图片的识别结果"})
    defn_f8 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp / "sub"), extensions="jpg"),
         _n("infer", "inference", model="m", prompt="识别文字"),  # 故意不配 images
         _n("e", "end", output="{{infer.output}}")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "infer"}, {"from": "infer", "to": "e"}])
    eng_f8 = _WE2("run-f8", defn_f8, conn_f8, str(ftmp))
    evs_f8 = []
    async for ev in eng_f8.run():
        evs_f8.append(ev)
    check("F8a 自动继承完成", any(e["event"] == "workflow_done" for e in evs_f8),
          str([e["event"] for e in evs_f8][-3:]))
    # 推理节点那次调用的 images 应非空（继承自文件输入）
    infer_call = [c for c in conn_f8.chat_calls if c[0] == "m"]
    check("F8b 推理节点收到图片", infer_call and infer_call[0][2],
          str([c[2] for c in infer_call]))
    check("F8c 继承的是真实图片路径", infer_call and infer_call[0][2]
          and str(infer_call[0][2][0]).endswith("d.jpg"), str(infer_call[0][2]) if infer_call else "")

    # ===== F9 分批 + 图片继承组合（0.2.3 用户真实场景）=====
    # 文件输入(2图) → 循环(分批2) → 推理节点：每批应收到当批图片
    conn_f9 = FakeConn({"m": "批识别"})
    defn_f9 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(ftmp), extensions="jpg"),  # a.jpg + sub? 仅顶层 a.jpg
         _n("loop", "loop", items="{{fin.output}}", branch="infer", batch_size=1),
         _n("infer", "inference", model="m", prompt="识别 {{item}}"),
         _n("e", "end", output="{{loop.output}}")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "loop"}, {"from": "loop", "to": "e"}])
    eng_f9 = _WE2("run-f9", defn_f9, conn_f9, str(ftmp))
    evs_f9 = []
    async for ev in eng_f9.run():
        evs_f9.append(ev)
    check("F9a 分批继承完成", any(e["event"] == "workflow_done" for e in evs_f9),
          str([e["event"] for e in evs_f9][-3:]))
    infer_calls9 = [c for c in conn_f9.chat_calls if c[0] == "m"]
    check("F9b 循环内推理也继承图片", infer_calls9 and infer_calls9[0][2],
          str([c[2] for c in infer_calls9]))

    # ===== F10 弱模型分批喂图（0.2.3 用户实测约束）=====
    # 用户实测：glm-ocr 一次只能消化 2-3 张图。验证 batch_size=3 时，
    # 每次推理调用恰好只收到当批的 3 张图（不多不少），避免整文件夹一次性灌入。
    imgdir10 = ftmp / "imgs10"
    imgdir10.mkdir(exist_ok=True)
    for i in range(1, 8):  # 7 张图 → 每批 3 张 = 3 批（3/3/1）
        (imgdir10 / f"{i}.jpg").write_text(f"img{i}", encoding="utf-8")
    conn_f10 = FakeConn({"m": "批转写"})
    defn_f10 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(imgdir10), extensions="jpg"),
         _n("loop", "loop", items="{{fin.output}}", branch="infer", batch_size=3),
         _n("infer", "inference", model="m", prompt="识别 {{item}}"),
         _n("e", "end", output="{{loop.output}}")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "loop"}, {"from": "loop", "to": "e"}])
    eng_f10 = _WE2("run-f10", defn_f10, conn_f10, str(ftmp))
    evs_f10 = []
    async for ev in eng_f10.run():
        evs_f10.append(ev)
    check("F10a 分批3完成", any(e["event"] == "workflow_done" for e in evs_f10),
          str([e["event"] for e in evs_f10][-3:]))
    infer_calls10 = [c for c in conn_f10.chat_calls if c[0] == "m"]
    imgs_per_call = [len(c[2]) if c[2] else 0 for c in infer_calls10]
    check("F10b 每批恰3张图", len(infer_calls10) == 3 and imgs_per_call == [3, 3, 1],
          f"调用次数={len(infer_calls10)} 每批图数={imgs_per_call}")

    # ===== F11 文件读取节点（0.2.3）=====
    mddir11 = ftmp / "mds11"
    mddir11.mkdir(exist_ok=True)
    (mddir11 / "1.md").write_text("第一段内容", encoding="utf-8")
    (mddir11 / "2.md").write_text("第二段内容", encoding="utf-8")
    (mddir11 / "ignore.txt").write_text("不该被读到", encoding="utf-8")
    conn_f11 = FakeConn({})
    defn_f11 = _defn(
        [_n("s", "start"),
         _n("fr", "file_read", path=str(mddir11), extensions="md"),
         _n("e", "end", output="{{fr.output}}")],
        [{"from": "s", "to": "fr"}, {"from": "fr", "to": "e"}])
    eng_f11 = _WE2("run-f11", defn_f11, conn_f11, str(ftmp))
    evs_f11 = []
    async for ev in eng_f11.run():
        evs_f11.append(ev)
    check("F11a 文件读取完成", any(e["event"] == "workflow_done" for e in evs_f11),
          str([e["event"] for e in evs_f11][-3:]))
    fr_out = str(eng_f11.variables["fr"]["output"])
    check("F11b 内容拼接含文件名标题", "=== 1.md ===" in fr_out and "第一段内容" in fr_out
          and "第二段内容" in fr_out, fr_out[:200])
    check("F11c 扩展名过滤生效", "不该被读到" not in fr_out and "ignore.txt" not in fr_out, fr_out[:200])

    # ===== F12 用户完整场景（0.2.3）：识别→按图名存md→批量读取→分析→存终稿 =====
    # 模拟：聊天记录(2图) → qwen3-vl逐张识别存 {{item_stem}}.md
    #       → file_read 批量读md → qwen3.6 整理 → 存 整理结果.md
    imgdir12 = ftmp / "chats12"
    imgdir12.mkdir(exist_ok=True)
    (imgdir12 / "1.jpg").write_text("图1", encoding="utf-8")
    (imgdir12 / "2.jpg").write_text("图2", encoding="utf-8")
    outdir12 = ftmp / "out12"
    conn_f12 = FakeConn({"vl": "识别文字", "big": "整理后的时间线文本"})
    defn_f12 = _defn(
        [_n("s", "start"),
         _n("fin", "file_input", path=str(imgdir12), extensions="jpg"),
         _n("loop", "loop", items="{{fin.output}}", branch="ocr, save"),
         _n("ocr", "inference", model="vl", prompt="识别 {{item}}"),
         _n("save", "file_output", dir=str(outdir12), filename="{{item_stem}}.md",
            content="{{ocr.output}}"),
         _n("fr", "file_read", path=str(outdir12), extensions="md"),
         _n("merge", "inference", model="big", prompt="去重排序：{{fr.output}}"),
         _n("fout", "file_output", dir=str(outdir12), filename="整理结果.md",
            content="{{merge.output}}"),
         _n("e", "end", output="{{fout.output}}")],
        [{"from": "s", "to": "fin"}, {"from": "fin", "to": "loop"},
         {"from": "loop", "to": "fr"}, {"from": "fr", "to": "merge"},
         {"from": "merge", "to": "fout"}, {"from": "fout", "to": "e"}])
    eng_f12 = _WE2("run-f12", defn_f12, conn_f12, str(ftmp))
    evs_f12 = []
    async for ev in eng_f12.run():
        evs_f12.append(ev)
    check("F12a 完整场景跑通", any(e["event"] == "workflow_done" for e in evs_f12),
          str([e["event"] for e in evs_f12][-3:]))
    md1, md2 = outdir12 / "1.md", outdir12 / "2.md"
    check("F12b 按原图名存md", md1.exists() and md2.exists(),
          f"{[p.name for p in outdir12.glob('*')] if outdir12.exists() else '目录未生成'}")
    check("F12c md内容为识别结果", md1.exists() and md1.read_text(encoding="utf-8") == "识别文字",
          md1.read_text(encoding="utf-8") if md1.exists() else "")
    final_md = outdir12 / "整理结果.md"
    check("F12d 终稿为整理文本", final_md.exists()
          and final_md.read_text(encoding="utf-8") == "整理后的时间线文本",
          final_md.read_text(encoding="utf-8") if final_md.exists() else "")
    # 模型切换：vl 循环结束后切 big 时应卸载 vl
    check("F12e 模型切换卸载", "vl" in conn_f12.unloads, str(conn_f12.unloads))

    # 清理文件测试目录
    import shutil as _sh
    _sh.rmtree(ftmp, ignore_errors=True)

    # ===== L11 模板渲染（含嵌套/列表） =====
    from sidecar.workflow.engine import render_template, resolve_value
    v = {"params": {"dir": "/tmp"}, "n1": {"output": "hello"}, "lst": [1, 2, 3]}
    check("L11a params 渲染", render_template("目录 {{params.dir}}", v) == "目录 /tmp")
    check("L11b 节点输出渲染", render_template("{{n1.output}}!", v) == "hello!")
    check("L11c 列表渲染为JSON", render_template("{{lst}}", v) == json.dumps([1, 2, 3], ensure_ascii=False))
    check("L11d 未定义原样保留", render_template("{{nope.x}}", v) == "{{nope.x}}")
    check("L11e resolve_value 保持类型", resolve_value("{{lst}}", v) == [1, 2, 3])

    # ===== G 组：0.2.4 两大模块修复回归 =====
    # G1（W1）：所有事件带 run_id——前端据此捕获以发送停止请求
    conn_g1 = FakeConn({"m": "x"})
    defn_g1 = _defn([_n("s", "start"), _n("n1", "inference", model="m", prompt="hi"),
                     _n("e", "end", output="{{n1.output}}")],
                    [{"from": "s", "to": "n1"}, {"from": "n1", "to": "e"}])
    eng_g1 = _WE2("run-g1", defn_g1, conn_g1, str(ftmp))
    evs_g1 = []
    async for ev in eng_g1.run():
        evs_g1.append(ev)
    check("G1a 所有事件带 run_id", all(e["data"].get("run_id") == "run-g1" for e in evs_g1),
          str([(e["event"], e["data"].get("run_id")) for e in evs_g1[:4]]))
    check("G1b node_start/node_done 也带", any(e["event"] == "node_start" for e in evs_g1)
          and all(e["data"].get("run_id") for e in evs_g1 if e["event"] in ("node_start", "node_done")))

    # G2（W2）：循环失败策略——skip 跳过失败批继续，输出占位
    class FlakyConn:
        """第 2 次调用抛错。"""
        def __init__(self):
            self.calls = 0
            self.unloads = []
        async def chat(self, model, messages, images=None, **kw):
            self.calls += 1
            if self.calls == 2:
                raise RuntimeError("模拟失败")
            return f"ok{self.calls}"
        async def unload_model(self, model):
            self.unloads.append(model)
            return True
    gtmp = Path(tempfile.mkdtemp(prefix="g2_"))
    conn_g2 = FlakyConn()
    defn_g2 = _defn([_n("s", "start"),
                     _n("loop", "loop", items="{{params.list}}", branch="body", fail_policy="skip"),
                     _n("body", "inference", model="m", prompt="处理 {{item}}"),
                     _n("e", "end", output="{{loop.output}}")],
                    [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"}])
    eng_g2 = _WE2("run-g2", defn_g2, conn_g2, str(gtmp), params={"list": ["a", "b", "c"]})
    evs_g2 = []
    async for ev in eng_g2.run():
        evs_g2.append(ev)
    done_g2 = [e for e in evs_g2 if e["event"] == "workflow_done"]
    check("G2a skip策略整体成功", len(done_g2) == 1, str([e["event"] for e in evs_g2][-3:]))
    check("G2b 失败批发跳过事件", any(e["event"] == "loop_batch_skipped" for e in evs_g2),
          str([e["event"] for e in evs_g2]))
    loop_out = eng_g2.variables["loop"]["output"]
    check("G2c 失败批占位None", len(loop_out) == 3 and loop_out[1] is None, str(loop_out))

    # G3（W2）：abort 策略——遇失败立即中止
    conn_g3 = FlakyConn()
    defn_g3 = _defn([_n("s", "start"),
                     _n("loop", "loop", items="{{params.list}}", branch="body", fail_policy="abort"),
                     _n("body", "inference", model="m", prompt="处理 {{item}}"),
                     _n("e", "end")],
                    [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"}])
    eng_g3 = _WE2("run-g3", defn_g3, conn_g3, str(gtmp), params={"list": ["a", "b", "c"]})
    evs_g3 = []
    async for ev in eng_g3.run():
        evs_g3.append(ev)
    check("G3 abort策略失败即中止", any(e["event"] == "workflow_failed" for e in evs_g3),
          str([e["event"] for e in evs_g3][-3:]))

    # G4（W5）：条件节点放进循环体作为求值器，不再报错
    conn_g4 = FakeConn({"m": "内容含 钱 字"})
    defn_g4 = _defn([_n("s", "start"),
                     _n("loop", "loop", items="{{params.list}}", branch="cond"),
                     _n("cond", "condition", match={"variable": "{{item}}", "operator": "contains", "value": "钱"}),
                     _n("e", "end", output="{{loop.output}}")],
                    [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"}])
    eng_g4 = _WE2("run-g4", defn_g4, conn_g4, str(gtmp), params={"list": ["今天天气好", "有钱"]})
    evs_g4 = []
    async for ev in eng_g4.run():
        evs_g4.append(ev)
    done_g4 = [e for e in evs_g4 if e["event"] == "workflow_done"]
    check("G4 条件节点入循环体可执行", len(done_g4) == 1, str([e["event"] for e in evs_g4][-3:]))
    cond_out = eng_g4.variables["loop"]["output"]
    check("G4b 循环内条件输出判定", cond_out == [False, True], str(cond_out))

    # G5（W8）：仅图片保护——音频文件被剔除不传给视觉模型
    audio = gtmp / "a.mp3"
    audio.write_bytes(b"fake-audio")
    img = gtmp / "b.jpg"
    img.write_bytes(b"fake-img")
    conn_g5 = FakeConn({"vl": "识别"})
    defn_g5 = _defn([_n("s", "start"),
                     _n("fin", "file_input", path=str(gtmp)),  # 读到 a.mp3 + b.jpg
                     _n("infer", "inference", model="vl", prompt="识别 {{item}}"),
                     _n("e", "end", output="{{infer.output}}")],
                    [{"from": "s", "to": "fin"}, {"from": "fin", "to": "infer"}, {"from": "infer", "to": "e"}])
    eng_g5 = _WE2("run-g5", defn_g5, conn_g5, str(gtmp))
    evs_g5 = []
    async for ev in eng_g5.run():
        evs_g5.append(ev)
    vl_calls = [c for c in conn_g5.chat_calls if c[0] == "vl"]
    imgs_g5 = vl_calls[0][2] if vl_calls else None
    check("G5a 音频被剔除", imgs_g5 is None or all(str(i).endswith(".jpg") for i in imgs_g5),
          str(imgs_g5))
    check("G5b 发剔除提示事件", any(e["event"] == "images_dropped" for e in evs_g5)
          or (imgs_g5 and all(str(i).endswith(".jpg") for i in imgs_g5)),
          str([e["event"] for e in evs_g5]))

    # G6（W4）：schema 孤岛检测支持循环体逗号分隔顺序链（不误判未连通）
    defn_g6 = _defn([_n("s", "start"),
                     _n("fin", "file_input", path="/tmp/x"),
                     _n("loop", "loop", items="{{fin.output}}", branch="ocr, save"),
                     _n("ocr", "inference", model="vl", prompt="识别 {{item}}"),
                     _n("save", "file_output", dir="/tmp/out", filename="{{item_stem}}.md",
                        content="{{ocr.output}}"),
                     _n("e", "end")],
                    [{"from": "s", "to": "fin"}, {"from": "fin", "to": "loop"},
                     {"from": "loop", "to": "e"}])
    errs_g6 = validate_definition(defn_g6, strict=True)
    check("G6 循环体逗号链不误判孤岛", errs_g6 == [], str(errs_g6))

    # G7（W3）：带环定义引擎正常运行不崩溃（布局破环在前端测试覆盖）
    defn_g7 = _defn([_n("s", "start"),
                     _n("loop", "loop", items="{{params.list}}", branch="body"),
                     _n("body", "inference", model="m", prompt="x"),
                     _n("e", "end")],
                    [{"from": "s", "to": "loop"}, {"from": "loop", "to": "e"},
                     {"from": "body", "to": "loop"}])  # body→loop 构成环
    eng_g7 = _WE2("run-g7", defn_g7, FakeConn({"m": "x"}), str(gtmp), params={"list": ["a"]})
    evs_g7 = []
    async for ev in eng_g7.run():
        evs_g7.append(ev)
    check("G7 带环定义引擎不崩溃", any(e["event"] in ("workflow_done", "workflow_failed") for e in evs_g7),
          str([e["event"] for e in evs_g7][-3:]))

    import shutil as _shg
    _shg.rmtree(gtmp, ignore_errors=True)

    # ===== H 组（TS-121，0.3.1 补遗1）：文本输出/变量赋值/代码执行/消息回复 =====
    htmp = Path(tempfile.mkdtemp(prefix="ck077_h_"))
    from sidecar.workflow.engine import WorkflowEngine as _WE3

    # H1 文本输出：模板渲染上游输出
    defn_h1 = _defn([_n("s", "start"),
                     _n("a", "inference", model="m", prompt="识别"),
                     _n("t", "text_output", template="汇总：{{a.output}}"),
                     _n("e", "end", output="{{t.output}}")],
                    [{"from": "s", "to": "a"}, {"from": "a", "to": "t"}, {"from": "t", "to": "e"}])
    evs_h1 = []
    async for ev in _WE3("run-h1", defn_h1, FakeConn({"m": "原文内容"}), str(htmp)).run():
        evs_h1.append(ev)
    done_h1 = [e for e in evs_h1 if e["event"] == "node_done" and e["data"].get("node_id") == "t"]
    wf_h1 = [e for e in evs_h1 if e["event"] == "workflow_done"]
    check("H1a 文本输出渲染上游", done_h1 and "原文内容" in str(done_h1[0]["data"].get("output_preview", "")), str(evs_h1[-2:]))
    check("H1b 结束结果取文本输出", wf_h1 and "汇总：原文内容" in json.dumps(wf_h1[0]["data"], ensure_ascii=False), str(wf_h1))

    # H2 变量赋值：整串引用保持类型 + 下游可读
    defn_h2 = _defn([_n("s", "start"),
                     _n("v", "variable_set", name="total", value="{{params.num}}"),
                     _n("t", "text_output", template="总数={{total}}"),
                     _n("e", "end", output="{{t.output}}")],
                    [{"from": "s", "to": "v"}, {"from": "v", "to": "t"}, {"from": "t", "to": "e"}])
    evs_h2 = []
    async for ev in _WE3("run-h2", defn_h2, FakeConn({}), str(htmp), params={"num": 42}).run():
        evs_h2.append(ev)
    t_h2 = [e for e in evs_h2 if e["event"] == "node_done" and e["data"].get("node_id") == "t"]
    check("H2 变量赋值+文本引用", t_h2 and "总数=42" in str(t_h2[0]["data"].get("output_preview", "")), str(evs_h2[-2:]))

    # H3 代码执行：读变量、写 result
    defn_h3 = _defn([_n("s", "start"),
                     _n("v", "variable_set", name="nums", value="{{params.list}}"),
                     _n("c", "code", code="result = sum(variables['nums'])"),
                     _n("t", "text_output", template="和={{c.output}}"),
                     _n("e", "end", output="{{t.output}}")],
                    [{"from": "s", "to": "v"}, {"from": "v", "to": "c"}, {"from": "c", "to": "t"}, {"from": "t", "to": "e"}])
    evs_h3 = []
    async for ev in _WE3("run-h3", defn_h3, FakeConn({}), str(htmp), params={"list": [1, 2, 3]}).run():
        evs_h3.append(ev)
    t_h3 = [e for e in evs_h3 if e["event"] == "node_done" and e["data"].get("node_id") == "t"]
    check("H3a 代码执行求和", t_h3 and "和=6" in str(t_h3[0]["data"].get("output_preview", "")), str(evs_h3[-2:]))
    # H3b 代码异常 → 节点失败
    defn_h3b = _defn([_n("s", "start"), _n("c", "code", code="1/0"), _n("e", "end")],
                     [{"from": "s", "to": "c"}, {"from": "c", "to": "e"}])
    evs_h3b = []
    async for ev in _WE3("run-h3b", defn_h3b, FakeConn({}), str(htmp)).run():
        evs_h3b.append(ev)
    err_h3b = [e for e in evs_h3b if e["event"] == "node_error" and e["data"].get("node_id") == "c"]
    check("H3b 代码异常报节点错误", err_h3b and "ZeroDivisionError" in str(err_h3b[0]["data"].get("error", "")), str(evs_h3b[-2:]))

    # H4 消息回复：发 workflow_reply 事件
    defn_h4 = _defn([_n("s", "start"),
                     _n("r", "reply", text="你好，{{params.name}}"),
                     _n("e", "end")],
                    [{"from": "s", "to": "r"}, {"from": "r", "to": "e"}])
    evs_h4 = []
    async for ev in _WE3("run-h4", defn_h4, FakeConn({}), str(htmp), params={"name": "测试员"}).run():
        evs_h4.append(ev)
    rep_h4 = [e for e in evs_h4 if e["event"] == "workflow_reply"]
    check("H4 消息回复事件含渲染文本", rep_h4 and rep_h4[0]["data"].get("text") == "你好，测试员", str(evs_h4))

    # H5 校验：新节点必填缺失报错
    from sidecar.workflow.schema import validate_definition
    errs_h5 = validate_definition(_defn(
        [_n("s", "start"), _n("t", "text_output"), _n("v", "variable_set"),
         _n("c", "code"), _n("r", "reply"), _n("e", "end")],
        [{"from": "s", "to": "t"}, {"from": "t", "to": "v"}, {"from": "v", "to": "c"},
         {"from": "c", "to": "r"}, {"from": "r", "to": "e"}]))
    check("H5 四节点缺必填均报错", len(errs_h5) >= 4, str(errs_h5))

    import shutil as _shh
    _shh.rmtree(htmp, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
