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
"""0.4.28（REQ-WF-015）专项：inference / 条件裁判节点的节点级读超时 timeout_s。

═══ 治的是什么 ═══
真机事故：工作流 n7 节点被非流式读超时掐断（默认 300s），大模型处理超长文本
推理耗时常超此限。全局调大 timeout_reading 会影响所有非流式调用方——故做
**节点级**覆盖：inference / 条件裁判节点可配可选 timeout_s（10~7200s），
缺省行为（全局默认 300s）完全不变。

═══ 链路 ═══
schema._node_errors 校验（strict/非 strict 都校，10~7200、拒绝非数值/bool）
→ engine._node_timeout_s（引擎侧 clamp 兜底，因 strict=False 创建可绕过校验）
→ engine._interruptible_chat(read_timeout_s=...)（None 时**不传该 kwarg**，
   保持调用形态与旧版逐字节一致——部分测试桩 connector 的 chat 不收 **kw）
→ connector.chat(read_timeout_s=...)（提供时覆盖 config timeout_reading；
   超时值参与 client 缓存 key，不同超时各自复用独立 client）
openai_compat.chat 同参（引擎可能跑在 OpenAI 兼容后端上）。

运行：.venv/bin/python -m sidecar.workflow.test_req_wf_015_timeout
"""
import asyncio
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


# ── 隔离：config 写路径钉到临时目录（不碰真实 ~/.subagent）──
_TMP = Path(tempfile.mkdtemp(prefix="wf015_"))
import json as _json                            # noqa: E402
import sidecar.config.store as cs               # noqa: E402
cs.get_config_path = lambda: _TMP / "config.json"
cs._MEM = dict(cs.DEFAULT_CONFIG)
cs._MEM["data_root"] = str(_TMP)
# C4/C5 用：openai_compat.chat 会求值 self._base() 拼 URL，未配置会直接抛
# 「推理后端地址未配置」。⛔ get_config() 每次从**磁盘**合并（不读 _MEM），
# 故必须真写隔离目录下的 config.json，不能只补丁 _MEM。
(_TMP / "config.json").write_text(
    _json.dumps({"inference_base_url": "http://127.0.0.1:1234/v1"}), encoding="utf-8")

from sidecar.workflow.schema import validate_definition  # noqa: E402
from sidecar.workflow import engine as eng_mod           # noqa: E402
from sidecar.workflow.engine import WorkflowEngine, clear_workflow_cancel  # noqa: E402


def _defn(node):
    return {"nodes": [{"id": "s", "type": "start"}, node, {"id": "e", "type": "end"}],
            "edges": [{"from": "s", "to": node["id"]}, {"from": node["id"], "to": "e"}],
            "params": {}}


def test_a_schema_timeout_s():
    """① schema 校验：接受/拒绝 timeout_s（strict 与非 strict 都校）。"""
    base = {"id": "n1", "type": "inference", "model": "m1", "prompt": "x"}

    ok_node = dict(base, timeout_s=1200)
    check("A1 合法 timeout_s=1200 → strict 通过",
          validate_definition(_defn(ok_node), strict=True) == [])
    check("A2 合法 timeout_s=1200 → 非 strict 通过",
          validate_definition(_defn(ok_node), strict=False) == [])
    check("A3 边界 10 / 7200 都接受",
          validate_definition(_defn(dict(base, timeout_s=10)), strict=False) == []
          and validate_definition(_defn(dict(base, timeout_s=7200)), strict=True) == [])
    check("A4 浮点 timeout_s=600.5 接受（数值即可）",
          validate_definition(_defn(dict(base, timeout_s=600.5)), strict=False) == [])
    check("A5 不配 timeout_s → 照旧通过（可选字段）",
          validate_definition(_defn(base), strict=True) == [])

    errs_lo = validate_definition(_defn(dict(base, timeout_s=5)), strict=False)
    check("A6 越界 timeout_s=5 → 非 strict 也拒绝且写明范围",
          any("timeout_s" in e and "10~7200" in e for e in errs_lo), str(errs_lo))
    errs_hi = validate_definition(_defn(dict(base, timeout_s=99999)), strict=True)
    check("A7 越界 timeout_s=99999 → strict 拒绝且写明范围",
          any("timeout_s" in e and "10~7200" in e for e in errs_hi), str(errs_hi))
    errs_str = validate_definition(_defn(dict(base, timeout_s="1200")), strict=False)
    check("A8 非数值 timeout_s=\"1200\" → 拒绝并说明须为数值",
          any("timeout_s" in e and "数值" in e for e in errs_str), str(errs_str))
    errs_bool = validate_definition(_defn(dict(base, timeout_s=True)), strict=False)
    check("A9 bool timeout_s=True → 拒绝（True 会变 1.0，常见误配）",
          any("timeout_s" in e for e in errs_bool), str(errs_bool))

    # 条件裁判节点同字段（动态裁判同走 connector.chat）
    # ⚠️ 既有校验：条件节点无 match 时 operator 必挂（与是否配 model 无关，本批不动）——
    #    故合法用例必须带一个合法 match。
    cond = {"id": "c1", "type": "condition", "model": "m1", "prompt": "判",
            "match": {"variable": "x", "operator": "contains", "value": "y"}}
    check("A10 条件节点合法 timeout_s=900 → 通过",
          validate_definition(_defn(dict(cond, timeout_s=900)), strict=True) == [])
    errs_c = validate_definition(_defn(dict(cond, timeout_s=1)), strict=False)
    check("A11 条件节点越界 timeout_s=1 → 非 strict 同样拒绝",
          any("timeout_s" in e for e in errs_c), str(errs_c))

    # code 节点自己的 timeout_s（1~300）不被新校验误伤（新校验只管 inference/condition）
    code_node = {"id": "k1", "type": "code", "code": "result=1", "timeout_s": 60}
    check("A12 code 节点 timeout_s=60 不受新校验影响（类型不同）",
          validate_definition(_defn(code_node), strict=False) == [])


class CaptureConn:
    """捕获引擎传给 connector.chat 的全部 kwargs（mock connector）。"""

    def __init__(self, raise_exc: BaseException | None = None):
        self.calls: list[dict] = []
        self.raise_exc = raise_exc
        self.unloads: list[str] = []

    async def chat(self, model, messages, images=None, **kw):
        self.calls.append({"model": model, "images": images, "kw": kw})
        if self.raise_exc is not None:
            raise self.raise_exc
        return "模型输出"

    async def unload_model(self, model):
        self.unloads.append(model)
        return True


def _mk_engine(node, conn):
    defn = _defn(node)
    return WorkflowEngine(f"wf015-{node['id']}-{id(node)}", defn, conn,
                          tempfile.mkdtemp())


def test_b_engine_passthrough():
    """② engine：读节点 timeout_s（clamp 兜底）→ 经 _interruptible_chat 传给 connector。"""

    async def go():
        # B1：inference 配 timeout_s=1200 → connector 收到 read_timeout_s=1200.0
        conn = CaptureConn()
        eng = _mk_engine({"id": "n1", "type": "inference", "model": "m1",
                          "prompt": "x", "timeout_s": 1200}, conn)
        r = await eng._run_inference(eng.nodes["n1"])
        check("B1 inference timeout_s=1200 → 透传 read_timeout_s=1200.0",
              r.ok and conn.calls and conn.calls[0]["kw"].get("read_timeout_s") == 1200.0,
              str(conn.calls))
        clear_workflow_cancel(eng.run_id)

        # B2：不配 timeout_s → **不传该 kwarg**（缺省行为与旧版逐字节一致；
        #     部分测试桩 chat 不收 **kw，无条件传参会 TypeError）
        conn2 = CaptureConn()
        eng2 = _mk_engine({"id": "n2", "type": "inference", "model": "m1", "prompt": "x"}, conn2)
        r2 = await eng2._run_inference(eng2.nodes["n2"])
        check("B2 未配 timeout_s → 调用不含 read_timeout_s 键（缺省形态不变）",
              r2.ok and conn2.calls and "read_timeout_s" not in conn2.calls[0]["kw"],
              str(conn2.calls))
        clear_workflow_cancel(eng2.run_id)

        # B3/B4：引擎侧 clamp 兜底（strict=False 创建可绕过 schema 校验）
        conn3 = CaptureConn()
        eng3 = _mk_engine({"id": "n3", "type": "inference", "model": "m1",
                           "timeout_s": 5}, conn3)
        await eng3._run_inference(eng3.nodes["n3"])
        check("B3 timeout_s=5（绕过校验）→ 引擎 clamp 到 10",
              conn3.calls[0]["kw"].get("read_timeout_s") == 10.0, str(conn3.calls))
        clear_workflow_cancel(eng3.run_id)

        conn4 = CaptureConn()
        eng4 = _mk_engine({"id": "n4", "type": "inference", "model": "m1",
                           "timeout_s": 99999}, conn4)
        await eng4._run_inference(eng4.nodes["n4"])
        check("B4 timeout_s=99999 → 引擎 clamp 到 7200",
              conn4.calls[0]["kw"].get("read_timeout_s") == 7200.0, str(conn4.calls))
        clear_workflow_cancel(eng4.run_id)

        # B5：非法值（字符串）→ None（回落全局默认，不传 kwarg）
        conn5 = CaptureConn()
        eng5 = _mk_engine({"id": "n5", "type": "inference", "model": "m1",
                           "timeout_s": "abc"}, conn5)
        r5 = await eng5._run_inference(eng5.nodes["n5"])
        check("B5 timeout_s=\"abc\" → 视为未配（不传 kwarg，不崩）",
              r5.ok and "read_timeout_s" not in conn5.calls[0]["kw"], str(conn5.calls))
        clear_workflow_cancel(eng5.run_id)

        # B6：bool 拒绝（True 会变 1.0）
        check("B6 _node_timeout_s(True) → None",
              WorkflowEngine._node_timeout_s({"timeout_s": True}) is None)
        check("B6b _node_timeout_s(None/缺键/NaN) → None",
              WorkflowEngine._node_timeout_s({}) is None
              and WorkflowEngine._node_timeout_s({"timeout_s": None}) is None
              and WorkflowEngine._node_timeout_s({"timeout_s": float("nan")}) is None)

        # B7：条件裁判节点同字段 → 透传
        conn7 = CaptureConn()
        eng7 = _mk_engine({"id": "c1", "type": "condition", "model": "m1",
                           "prompt": "判", "timeout_s": 900}, conn7)
        res7, _when = await eng7._run_condition(eng7.nodes["c1"])
        check("B7 条件裁判 timeout_s=900 → 透传 read_timeout_s=900.0",
              res7.ok and conn7.calls
              and conn7.calls[0]["kw"].get("read_timeout_s") == 900.0, str(conn7.calls))
        clear_workflow_cancel(eng7.run_id)

        # B8：超时错误提示写**实际生效**秒数（节点覆盖时写 1200，而非全局 300）
        conn8 = CaptureConn(raise_exc=asyncio.TimeoutError())
        eng8 = _mk_engine({"id": "n8", "type": "inference", "model": "m1",
                           "timeout_s": 1200}, conn8)
        r8 = await eng8._run_inference(eng8.nodes["n8"])
        check("B8 节点超时 → 错误含实际生效的 1200s（不写全局 300 误导）",
              (not r8.ok) and "1200" in str(r8.error) and "timeout_s" in str(r8.error),
              str(r8.error)[:260])
        clear_workflow_cancel(eng8.run_id)

        conn9 = CaptureConn(raise_exc=asyncio.TimeoutError())
        eng9 = _mk_engine({"id": "n9", "type": "inference", "model": "m1"}, conn9)
        r9 = await eng9._run_inference(eng9.nodes["n9"])
        check("B9 未配节点超时 → 错误仍写全局默认 300s（旧行为不变）",
              (not r9.ok) and "300" in str(r9.error), str(r9.error)[:260])
        clear_workflow_cancel(eng9.run_id)

    asyncio.run(go())


def test_c_connector_override():
    """③ connector.chat：read_timeout_s 覆盖生效；缺省走 config（默认 300）不变。"""

    async def go():
        import sidecar.ollama.connector as conn_mod
        import sidecar.ollama.infer_options as io

        class FakeResp:
            status_code = 200
            text = ""

            def json(self):
                return {"message": {"role": "assistant", "content": "ok"}, "done": True}

        class FakeClient:
            is_closed = False

            async def post(self, url, json=None, **kw):
                return FakeResp()

            async def aclose(self):
                pass

        seen: list[dict] = []

        async def spy_client(reading=None, connect=None):
            seen.append({"reading": reading, "connect": connect})
            return FakeClient()

        c = conn_mod.OllamaConnector()
        c._client = spy_client  # type: ignore

        # C1：显式覆盖 → _client 收到 reading=1200（不再读 config）
        await c.chat("m", [{"role": "user", "content": "hi"}], read_timeout_s=1200.0)
        check("C1 read_timeout_s=1200 → _client(reading=1200.0) 覆盖生效",
              seen and seen[-1]["reading"] == 1200.0, str(seen))

        # C2：缺省 → reading=None（由 _client 内部动态读 config，默认 300）
        await c.chat("m", [{"role": "user", "content": "hi"}])
        check("C2 缺省 → reading=None（走既有动态取值路径，行为不变）",
              seen[-1]["reading"] is None, str(seen))
        check("C3 缺省路径的动态取值仍是全局默认 300s",
              io.timeout_reading() == 300.0, str(io.timeout_reading()))

        # C4：openai_compat 后端同参（引擎可能跑在该后端上）
        from sidecar.ollama.openai_compat import OpenAICompatConnector
        oc = OpenAICompatConnector()
        seen2: list[dict] = []

        async def spy2(reading=None, connect=None):
            seen2.append({"reading": reading})
            return FakeClient()

        oc._client = spy2  # type: ignore
        await oc.chat("m", [{"role": "user", "content": "hi"}], read_timeout_s=450.0)
        check("C4 openai_compat read_timeout_s=450 → _client(reading=450.0)",
              seen2 and seen2[-1]["reading"] == 450.0, str(seen2))
        await oc.chat("m", [{"role": "user", "content": "hi"}])
        check("C5 openai_compat 缺省 → reading=None（行为不变）",
              seen2[-1]["reading"] is None, str(seen2))

    asyncio.run(go())


def main():
    print("=" * 70)
    print("0.4.28（REQ-WF-015）节点级 timeout_s 专项")
    print("=" * 70)
    test_a_schema_timeout_s()
    test_b_engine_passthrough()
    test_c_connector_override()
    print("\n" + "=" * 70)
    print(f"===== SUMMARY: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:")
        for f in FAILURES:
            print("  -", f)
    print("=" * 70)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
