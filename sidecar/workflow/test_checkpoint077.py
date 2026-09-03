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

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
