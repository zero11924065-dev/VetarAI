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
"""0.4.29 批 P0（D1 前置）两个现存缺口修复专项：

① compactor 摘要走 get_inference_connector() 工厂——原实现 raw httpx 直连
   ollama_base_url + /api/chat，openai_compatible 后端下智能压缩必坏。
② OpenAICompatConnector 补 unload_model / list_loaded_models 生命周期 no-op——
   工作流引擎 engine.py 在相邻节点换模型时裸调 unload_model（无 try/except），
   openai_compatible 后端下抛 AttributeError。
③ 回归验证：工作流引擎在 openai_compatible 后端（OpenAICompatConnector 实例）
   下相邻节点换模型全程不抛 AttributeError。

只读确认（不动）：roundtable.py / delegation.py 无同类裸调（grep 核实）；
delegation 路径与 loop.py safe_unload_model 已有 try/except 防护。

venv 内直接跑：python test_0429_infer_gaps.py（须走 scripts/run_backend_tests.py，
勿裸跑——见 ENV-AND-CONFIG §11.3 隔离纪律；本文件自身也做了 store 重定向）。
"""
import asyncio
import importlib
import inspect
import os
import shutil
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


# ══════════ 变异测试机制（照 test_loop.py / test_office_io.py 既有惯例）══════════
#
# 运行：MUTATE=1|2 .venv/bin/python -m sidecar.test_0429_infer_gaps
# 变异模式下必须出现 FAIL；0 FAIL = 断言空转，需加强（不是"通过"）。
#
# | 变异 | 撤掉的修复 | 应失败的断言 |
# |---|---|---|
# | 1 | compactor 回退缺陷态：绕过工厂直接 new OllamaConnector | 1a/1b/1c/1d/1e |
# | 2 | 删掉 OpenAICompatConnector.unload_model / list_loaded_models | 2a/2b/2c + 3b/3c/3d |
# 实测备注：变异2 下 3a 仍 PASS——引擎 run 循环的通用 except 把 AttributeError 转成
# workflow_failed 事件而非上抛，缺陷表现为 n2 未执行/无卸载调用（3b/3c/3d 抓到）。
MUTATE = int(os.environ.get("MUTATE", "0"))

# 还原用内存备份而非 git checkout（变异期间工作区可能有未提交改动；既有纪律沿用）。
_BACKUP: dict[str, str] = {}
_MUTATED_ATTRS: dict[str, object] = {}


def _apply_mutation() -> None:
    """把两处修复改回缺陷态。锚点未命中必须 assert 报错——否则"变异没抓到"
    可能只是根本没注入成功（0.4.18 B10/C8 变异静默失败过的教训）。"""
    if not MUTATE:
        return
    if MUTATE == 1:
        import sidecar.compactor as comp
        src_path = Path(comp.__file__)
        src = src_path.read_text(encoding="utf-8")
        _BACKUP[str(src_path)] = src
        anchor = "connector = get_inference_connector()"
        assert anchor in src, f"变异1 锚点未命中：{anchor}"
        mutant = src.replace(
            anchor,
            "from sidecar.ollama.connector import OllamaConnector as _MutO; "
            "connector = _MutO()  # 变异1：绕过工厂直连 ollama")
        assert mutant != src
        src_path.write_text(mutant, encoding="utf-8")
        importlib.reload(comp)
    elif MUTATE == 2:
        from sidecar.ollama.openai_compat import OpenAICompatConnector
        for attr in ("unload_model", "list_loaded_models"):
            assert hasattr(OpenAICompatConnector, attr), f"变异2 锚点未命中：{attr}"
            _MUTATED_ATTRS[attr] = getattr(OpenAICompatConnector, attr)
            delattr(OpenAICompatConnector, attr)


def _restore_mutation() -> None:
    for path, src in _BACKUP.items():
        Path(path).write_text(src, encoding="utf-8")
    if _BACKUP:
        import sidecar.compactor as comp
        importlib.reload(comp)
    if _MUTATED_ATTRS:
        from sidecar.ollama.openai_compat import OpenAICompatConnector
        for attr, fn in _MUTATED_ATTRS.items():
            setattr(OpenAICompatConnector, attr, fn)


# ---------- 假连接器 ----------
class RecordingConnector:
    """记录 chat 调用参数；返回固定摘要。"""

    def __init__(self, reply="摘要：关键决策X，待办Y。"):
        self.reply = reply
        self.calls = []

    async def chat(self, model, messages, *, stream=False, images=None, read_timeout_s=None):
        self.calls.append({"model": model, "messages": messages,
                           "stream": stream, "read_timeout_s": read_timeout_s})
        return self.reply


class _HttpxTripwire:
    """httpx.AsyncClient 绊线：compactor 若仍直连 ollama_base_url 必然实例化它。"""

    triggered = False

    def __init__(self, *a, **kw):
        _HttpxTripwire.triggered = True
        raise AssertionError("compactor 仍在直连 httpx（应走 get_inference_connector 工厂）")


# ---------- 场景 1：非 ollama 后端下压缩走工厂 ----------
async def scenario_compactor_factory() -> None:
    import httpx
    import sidecar.config.store as cfgstore
    import sidecar.storage.store as store
    import sidecar.compactor as comp
    import sidecar.ollama.connector as conn_mod

    tmpdir = Path(tempfile.mkdtemp(prefix="d1compact_"))
    archive_dir = tmpdir / "compressed"
    archive_dir.mkdir()

    orig_mem = dict(cfgstore._MEM) if cfgstore._MEM else {}
    test_cfg = {
        # 非 ollama 后端：openai_compatible；两个地址都指向不可达端口，
        # 只要代码还直连任何一个地址就必失败——只有走 mock 工厂才能成功。
        "inference_backend": "openai_compatible",
        "inference_base_url": "http://127.0.0.1:9",
        "ollama_base_url": "http://127.0.0.1:9",
        "compact_archive_dir": str(archive_dir),
        "compact_keep_recent": 3,
        "data_root": str(tmpdir),
    }
    cfgstore._MEM = dict(test_cfg)
    store.PROJECTS_ROOT = tmpdir / "projects"
    store._GDB = tmpdir / "projects" / "_global.db"
    store.PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)

    workdir = tmpdir / "work"
    workdir.mkdir()
    pid = store.create_project("D1 Test", workdir)
    aid = store.add_agent_config(pid, "Test Agent", "main")

    orig_get_config = comp.get_config
    comp.get_config = lambda: dict(test_cfg)
    orig_factory = conn_mod.get_inference_connector
    orig_httpx_client = httpx.AsyncClient

    fake = RecordingConnector()
    conn_mod.get_inference_connector = lambda: fake
    _HttpxTripwire.triggered = False
    httpx.AsyncClient = _HttpxTripwire
    try:
        sid = store.create_session(pid, aid, "S1")
        for i in range(10):
            store.save_message(pid, sid, aid, "user" if i % 2 == 0 else "assistant",
                               f"历史消息 {i + 1}")
        r = await comp.compact_session(pid, sid, keep_recent=3, model="qwen3.8")

        check("1a 非 ollama 后端下压缩成功 ok=True", r.get("ok") is True, str(r))
        calls = fake.calls
        check("1b 摘要走了工厂返回连接器的 chat（且只调一次）", len(calls) == 1, str(calls))
        if calls:
            c0 = calls[0]
            check("1c chat 参数：模型沿用入参 + 压缩提示词 + read_timeout_s=120.0（原硬编码超时语义）",
                  c0["model"] == "qwen3.8" and c0["read_timeout_s"] == 120.0
                  and isinstance(c0["messages"], list) and len(c0["messages"]) == 1
                  and "压缩为 300 字" in str(c0["messages"][0].get("content", "")),
                  str(c0)[:300])
        else:
            check("1c chat 参数：模型沿用入参 + 压缩提示词 + read_timeout_s=120.0（原硬编码超时语义）",
                  False, "chat 未被调用")
        check("1d 不再直连 ollama_base_url（httpx.AsyncClient 绊线未触发）",
              _HttpxTripwire.triggered is False)
        msgs = store.load_messages(pid, sid)
        check("1e 落库正确：保留3 + 摘要1 = 4 条，摘要 role=system",
              len(msgs) == 4 and msgs[-1]["role"] == "system"
              and "历史摘要" in msgs[-1]["content"],
              f"count={len(msgs)}")
    finally:
        httpx.AsyncClient = orig_httpx_client
        conn_mod.get_inference_connector = orig_factory
        comp.get_config = orig_get_config
        cfgstore._MEM = orig_mem
        shutil.rmtree(tmpdir, ignore_errors=True)

    check("1f 临时目录已清理", not tmpdir.exists())


# ---------- 场景 2：OpenAICompatConnector 生命周期 no-op ----------
async def scenario_openai_compat_noop() -> None:
    from sidecar.ollama.openai_compat import OpenAICompatConnector
    from sidecar.ollama.connector import OllamaConnector

    conn = OpenAICompatConnector()
    # getattr 取值：变异2（删方法）下也能走到断言报 FAIL，而不是中途崩溃。
    unload_fn = getattr(conn, "unload_model", None)
    list_fn = getattr(conn, "list_loaded_models", None)
    check("2a unload_model / list_loaded_models 存在且为 async 方法",
          inspect.iscoroutinefunction(unload_fn) and inspect.iscoroutinefunction(list_fn))

    r_unload = await unload_fn("any-model") if unload_fn else "<missing>"
    r_list = await list_fn() if list_fn else "<missing>"
    check("2b no-op 语义：unload_model 返回 False；list_loaded_models 返回 []",
          r_unload is False and r_list == [],
          f"unload={r_unload!r} list={r_list!r}")

    # 变异2 下方法已被删：签名对比直接判 FAIL（不能崩溃中断后续场景）。
    cls_unload = getattr(OpenAICompatConnector, "unload_model", None)
    cls_list = getattr(OpenAICompatConnector, "list_loaded_models", None)
    if cls_unload is None or cls_list is None:
        check("2c 与 OllamaConnector 同名方法参数签名一致（调用契约对齐）",
              False, "方法不存在（变异2 生效）")
        return
    sig_new_unload = inspect.signature(cls_unload)
    sig_old_unload = inspect.signature(OllamaConnector.unload_model)
    sig_new_list = inspect.signature(cls_list)
    sig_old_list = inspect.signature(OllamaConnector.list_loaded_models)
    # 调用契约 = 参数签名一致（engine.py 按位置裸调 unload_model(name)）。
    # 返回注解允许差异：OllamaConnector 标 list[str]，本类按 0.4.29 D1 规格标 list，
    # 两者运行时返回值语义一致（空列表/False 兜底）。
    check("2c 与 OllamaConnector 同名方法参数签名一致（调用契约对齐）",
          list(sig_new_unload.parameters) == list(sig_old_unload.parameters)
          and list(sig_new_list.parameters) == list(sig_old_list.parameters),
          f"unload {sig_new_unload} vs {sig_old_unload}；list {sig_new_list} vs {sig_old_list}")


# ---------- 场景 3：openai_compatible 后端下相邻节点换模型不抛 AttributeError ----------
async def scenario_engine_model_switch() -> None:
    import sidecar.storage.store as store
    from sidecar.ollama.openai_compat import OpenAICompatConnector
    from sidecar.workflow.engine import WorkflowEngine

    # 引擎 run 会写 workflow run/node 事件到全局库——重定向到临时目录（与 ck077 一致；
    # runner 的 VETARAI_DATA_ROOT 隔离是底线，本重定向让套件裸跑也不碰真实库）。
    tmpdb = Path(tempfile.mkdtemp(prefix="d1engdb_"))
    orig_root, orig_gdb = store.PROJECTS_ROOT, store._GDB
    store.PROJECTS_ROOT = tmpdb
    store._GDB = tmpdb / "_global.db"

    conn = OpenAICompatConnector()
    # 实例级 stub chat 避免真实网络；unload_model/list_loaded_models 用真实实现（no-op）。
    chat_models = []

    async def fake_chat(model, messages, *, stream=False, images=None, read_timeout_s=None):
        chat_models.append(model)
        return f"reply-from-{model}"

    conn.chat = fake_chat  # type: ignore[method-assign]

    unload_calls = []
    orig_unload = getattr(conn, "unload_model", None)
    if orig_unload is not None:
        async def spy_unload(name):
            unload_calls.append(name)
            return await orig_unload(name)

        conn.unload_model = spy_unload  # type: ignore[method-assign]
    # 变异2（方法被删）下不装 spy：引擎裸调抛 AttributeError，正是要抓的缺陷态。

    definition = {
        "nodes": [
            {"id": "s", "type": "start"},
            {"id": "n1", "type": "inference", "model": "model-a", "prompt": "任务一"},
            {"id": "n2", "type": "inference", "model": "model-b", "prompt": "任务二"},
            {"id": "e", "type": "end", "output": "{{n2.output}}"},
        ],
        "edges": [{"from": "s", "to": "n1"}, {"from": "n1", "to": "n2"},
                  {"from": "n2", "to": "e"}],
        "params": {},
    }
    sandbox = tempfile.mkdtemp(prefix="d1engine_")
    engine = WorkflowEngine("run-d1-test", definition, conn, sandbox, params={})
    events = []
    raised = None
    try:
        async for ev in engine.run():
            events.append(ev)
    except AttributeError as e:
        raised = e
    except Exception as e:
        raised = e
    finally:
        store.PROJECTS_ROOT, store._GDB = orig_root, orig_gdb
        shutil.rmtree(tmpdb, ignore_errors=True)
        shutil.rmtree(sandbox, ignore_errors=True)

    check("3a openai_compatible 后端下相邻节点换模型：run 全程无异常（原缺陷=AttributeError）",
          raised is None, repr(raised))
    check("3b 两个推理节点都执行了 chat（model-a → model-b）",
          chat_models == ["model-a", "model-b"], str(chat_models))
    # 换模型卸载旧 model-a 1 次 + run 结束 _release_model 卸载 model-b 1 次 = 2 次，均 no-op False
    check("3c unload_model 被调用 2 次且均为 no-op（不阻塞流程）",
          unload_calls == ["model-a", "model-b"], str(unload_calls))
    node_dones = [e for e in events if e.get("event") == "node_done"]
    done_ids = [(e.get("data") or {}).get("node_id") for e in node_dones]
    wf_done = any(e.get("event") == "workflow_done" for e in events)
    check("3d 两个推理节点均 node_done 且 workflow_done 收尾",
          "n1" in done_ids and "n2" in done_ids and wf_done,
          f"node_dones={done_ids} workflow_done={wf_done}")


async def main() -> None:
    _apply_mutation()
    try:
        await scenario_compactor_factory()
        await scenario_openai_compat_noop()
        await scenario_engine_model_switch()
    finally:
        _restore_mutation()
    print(f"\n===== 0.4.29 D1 前置缺口专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
