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
"""0.4.30 路由连接器 + ASR 状态端点专项套件。

覆盖契约：
  T1 路由按 model 名归边（ollama 后端：包→MP、普通模型→ollama；禁用包落回活动后端）
  T2 openai 后端与模型包共存（包→MP、普通→openai）
  T3 list_models 并集 + source 标注（禁用包即时退出并集）
  T4 换装编排方向①：路由命中包、ensure_server 前卸活动后端驻留模型（顺序断言）
  T5 换装编排方向②：路由命中活动后端前先停 llama-server（顺序断言）
  T6 换装编排方向③：unload 双向分发（含已禁用包仍归 MP）+ loaded 并集（两边都卸）
  T7 model_package 旧配置兼容：退化为全走 MP（列表仅 MP、无跨引擎钩子）
  T8 GET /api/asr/status 三态（none/disabled/ready）+ 无注册表/注册表损坏容错
     + ready 不依赖 inference_backend（ASR 安装即自动可用的契约断言）

隔离：顶部先钉 VETARAI_MODEL_PACKS_DIR + VETARAI_DATA_ROOT 到临时目录，
再桩 config.store.get_config_path（test_model_packs.py / test_driver_llamacpp.py 同款）。

变异测试机制（MUTATE=1|2|3|4|5|6 python -m sidecar.ollama.test_routing_connector）：
变异模式下必须出现 FAIL；0 FAIL = 断言空转，需加强（不是"通过"）。
| 变异 | 撤掉的修复 | 应失败的断言 |
|---|---|---|
| 1 | 路由归边失效（包不再归 MP 边） | T1a~T1d/T2a/T2b/T4a/T4b（级联变红） |
| 2 | list_models 并集失效（只剩活动后端） | T3a/T3b |
| 3 | 方向①失效（装包前不卸活动后端驻留模型） | T4a/T4b |
| 4 | 方向②失效（回活动后端前不停 llama-server） | T5a/T5b |
| 5 | model_package 退化失效（不再全走 MP） | T7b/T7c |
| 6 | asr/status 禁用态判定失效（disabled 误报 none） | T8c |
"""
import asyncio
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# ── 隔离（必须先于一切 sidecar 导入）──
TMP = Path(tempfile.mkdtemp(prefix="routing_test_"))
os.environ["VETARAI_MODEL_PACKS_DIR"] = str(TMP / "packs")
os.environ.setdefault("VETARAI_DATA_ROOT", str(TMP / "data"))

import sidecar.config.store as _cs  # noqa: E402
_cs.get_config_path = lambda: TMP / "config.json"
_cs._MEM = {}

import sidecar.ollama.connector as connmod  # noqa: E402
import sidecar.ollama.routing as routmod  # noqa: E402
import sidecar.model_packs.store as mps  # noqa: E402
import sidecar.model_packs.llamacpp_driver as mpd  # noqa: E402
from sidecar.config import reload_config  # noqa: E402

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


# ══════════ 变异机制（test_driver_llamacpp.py 同款：内存备份 + finally 还原 + reload）══════════
MUTATE = int(os.environ.get("MUTATE", "0"))
_BACKUP: dict[str, tuple[Path, str]] = {}


def _mutate_file(path: Path, old: str, new: str, tag: str) -> None:
    s = path.read_text(encoding="utf-8")
    _BACKUP[tag] = (path, s)
    patched = s.replace(old, new)
    assert patched != s, f"变异 {MUTATE} 未命中 {path.name} 源码锚点，测试无效"
    path.write_text(patched, encoding="utf-8")


def _apply_mutation() -> None:
    if not MUTATE:
        return
    import importlib
    if MUTATE == 1:
        _mutate_file(Path(routmod.__file__),
                     "        return self._is_chat_pack(model)",
                     "        return False  # MUTATED-1", "routing")
    elif MUTATE == 2:
        _mutate_file(Path(routmod.__file__),
                     "        out.extend(await self._mp().list_models())",
                     "        pass  # MUTATED-2", "routing")
    elif MUTATE == 3:
        _mutate_file(Path(routmod.__file__),
                     "            try:\n                await safe_unload_model(active, str(name))",
                     "            try:\n                pass  # MUTATED-3", "routing")
    elif MUTATE == 4:
        _mutate_file(Path(routmod.__file__),
                     "            stopped = await _drv.stop_server()",
                     "            stopped = False  # MUTATED-4", "routing")
    elif MUTATE == 5:
        _mutate_file(Path(routmod.__file__),
                     '        return self._backend() == "model_package"',
                     "        return False  # MUTATED-5", "routing")
    elif MUTATE == 6:
        from sidecar import app as _appmod
        _mutate_file(Path(_appmod.__file__),
                     '            has_asr = any(ent.get("task") == "asr"',
                     '            has_asr = False and any(ent.get("task") == "asr"', "app")
        importlib.reload(_appmod)
        return
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3|4|5|6）")
    importlib.reload(routmod)
    connmod._ROUTING_SINGLETON = None


def _restore() -> None:
    """还原被变异的源文件（必须在 finally：用例 sys.exit 会抛 SystemExit）。"""
    if not MUTATE or not _BACKUP:
        return
    import importlib
    try:
        for path, s in _BACKUP.values():
            path.write_text(s, encoding="utf-8")
    finally:
        tags = set(_BACKUP.keys())
        _BACKUP.clear()
        if "routing" in tags:
            importlib.reload(routmod)
            connmod._ROUTING_SINGLETON = None
        if "app" in tags:
            from sidecar import app as _appmod
            importlib.reload(_appmod)


# ══════════ 测试数据与间谍连接器 ══════════

def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _install(pack_id: str, *, task: str = "chat", enabled: bool = True) -> None:
    """造一个"已安装"包：占位权重 + manifest.json 副本 + 注册表登记（默认启用）。"""
    suffix = "model.gguf" if task == "chat" else "model_quant.onnx"
    data = b"FAKE-WEIGHTS-" + pack_id.encode()
    d = mps.pack_dir(pack_id)
    d.mkdir(parents=True, exist_ok=True)
    (d / suffix).write_bytes(data)
    pack = {"pack_id": pack_id, "name": f"测试包 {pack_id}", "task": task,
            "format": "gguf" if task == "chat" else "onnx",
            "driver": "llamacpp" if task == "chat" else "onnxruntime",
            "version": "1.0.0", "description": "routing 测试用", "size_bytes": len(data),
            "min_app_version": "", "homepage": "", "license": "MIT",
            "files": [{"path": suffix, "size_bytes": len(data),
                       "sha256": _sha(data), "sources": ["file:///x"]}]}
    (d / "manifest.json").write_text(json.dumps(pack, ensure_ascii=False), encoding="utf-8")
    mps.register_pack(pack_id, pack)   # register_pack 登记即 status=installed（默认启用）
    if not enabled:
        mps.set_enabled(pack_id, False)


class FakeOllama:
    """活动后端（ollama 形态）间谍：记录 chat/stream/unload 调用与顺序。"""

    def __init__(self, order: list) -> None:
        self.order = order
        self.chat_models: list[str] = []
        self.stream_models: list[str] = []
        self.unloaded: list[str] = []
        self.loaded: list[str] = []

    async def chat(self, model, messages, *, stream=False, images=None, read_timeout_s=None):
        self.chat_models.append(model)
        self.order.append(("ollama_chat", model))
        return f"OLLAMA-OK:{model}"

    async def chat_stream(self, model, messages, *, tools=None, images=None):
        self.stream_models.append(model)
        self.order.append(("ollama_stream", model))
        yield {"content_delta": "o"}
        yield {"done": True, "counts": {"prompt_eval_count": 1, "eval_count": 1}}

    async def list_models(self):
        return [{"name": "qwen3.8:latest", "size": 100}]

    async def list_loaded_models(self):
        return list(self.loaded)

    async def unload_model(self, name):
        self.unloaded.append(name)
        self.order.append(("ollama_unload", name))
        if name in self.loaded:
            self.loaded.remove(name)
        return True

    def capabilities(self):
        return {"backend": "ollama", "tools": True, "vision": True,
                "pull": True, "delete": True}


class FakeOpenAI(FakeOllama):
    async def list_models(self):
        return [{"name": "gpt-4o-mini"}]

    def capabilities(self):
        return {"backend": "openai_compatible", "tools": True, "vision": True,
                "pull": False, "delete": False}


class FakeMP:
    """模型包连接器间谍：list_models 走真实注册表（与 mp_connector 同口径），
    其余记录调用。"""

    def __init__(self, order: list) -> None:
        self.order = order
        self.chat_models: list[str] = []
        self.stream_models: list[str] = []
        self.unloaded: list[str] = []
        self.loaded: list[str] = []

    async def chat(self, model, messages, *, stream=False, images=None, read_timeout_s=None):
        self.chat_models.append(model)
        self.order.append(("mp_chat", model))
        return f"MP-OK:{model}"

    async def chat_stream(self, model, messages, *, tools=None, images=None):
        self.stream_models.append(model)
        self.order.append(("mp_stream", model))
        yield {"content_delta": "m"}
        yield {"done": True, "counts": {"prompt_eval_count": 1, "eval_count": 1}}

    async def list_models(self):
        return [{"name": p["pack_id"], "size": int(p.get("size_bytes") or 0),
                 "source": "model_pack"}
                for p in mps.list_installed()
                if p.get("task") == "chat" and p.get("enabled")]

    async def list_loaded_models(self):
        return list(self.loaded)

    async def unload_model(self, name):
        self.unloaded.append(name)
        self.order.append(("mp_unload", name))
        if name in self.loaded:
            self.loaded.remove(name)
        return True

    def capabilities(self):
        return {"backend": "model_package", "tools": True, "vision": False,
                "pull": False, "delete": False}


ORDER: list = []
FO: FakeOllama
FOAI: FakeOpenAI
FMP: FakeMP


def _wire() -> None:
    """重建间谍并钉进 connector 单例位 + 清空路由单例（每个用例组前调用，
    间谍随用例重建，跨用例零状态残留）。"""
    global FO, FOAI, FMP
    FO = FakeOllama(ORDER)      # ollama 活动后端间谍
    FOAI = FakeOpenAI(ORDER)    # openai 活动后端间谍
    FMP = FakeMP(ORDER)         # 模型包连接器间谍
    connmod._SINGLETON = FO
    connmod._OPENAI_SINGLETON = FOAI
    connmod._MP_SINGLETON = FMP
    connmod._ROUTING_SINGLETON = None


def _routing():
    return connmod.get_inference_connector()


async def _collect(gen) -> list:
    return [ev async for ev in gen]


# ══════════ T1/T2 路由归边 ══════════

async def t1_route_ollama_backend():
    reload_config({"inference_backend": "ollama"})
    _wire()
    _install("pack-a")
    r = _routing()
    msgs = [{"role": "user", "content": "hi"}]

    out = await r.chat("pack-a", msgs)
    check("T1a chat 命中包 → MP 边",
          out == "MP-OK:pack-a" and FMP.chat_models == ["pack-a"] and FO.chat_models == [],
          f"{out} mp={FMP.chat_models} ollama={FO.chat_models}")

    out2 = await r.chat("qwen3.8", msgs)
    check("T1b chat 普通模型 → ollama 边",
          out2 == "OLLAMA-OK:qwen3.8" and FO.chat_models == ["qwen3.8"]
          and FMP.chat_models == ["pack-a"], f"{out2}")

    evs = await _collect(r.chat_stream("pack-a", msgs))
    evs2 = await _collect(r.chat_stream("qwen3.8", msgs))
    check("T1c stream 双向归边（包→MP / 普通→ollama）",
          FMP.stream_models == ["pack-a"] and FO.stream_models == ["qwen3.8"]
          and any("content_delta" in e for e in evs) and any("content_delta" in e for e in evs2))

    mps.set_enabled("pack-a", False)
    out3 = await r.chat("pack-a", msgs)
    check("T1d 禁用包不参与并行 → 落活动后端",
          out3 == "OLLAMA-OK:pack-a" and FO.chat_models[-1] == "pack-a"
          and FMP.chat_models == ["pack-a"], f"{out3}")
    mps.set_enabled("pack-a", True)


async def t2_route_openai_backend():
    reload_config({"inference_backend": "openai_compatible",
                   "inference_base_url": "http://localhost:1234/v1"})
    _wire()
    r = _routing()
    msgs = [{"role": "user", "content": "hi"}]
    out = await r.chat("pack-a", msgs)
    out2 = await r.chat("gpt-4o-mini", msgs)
    check("T2a openai 后端下包仍归 MP 边",
          out == "MP-OK:pack-a" and FMP.chat_models[-1] == "pack-a", out)
    check("T2b openai 后端下普通模型归 openai 边",
          out2 == "OLLAMA-OK:gpt-4o-mini" and FOAI.chat_models == ["gpt-4o-mini"]
          and FO.chat_models == [], f"{out2} foai={FOAI.chat_models}")
    check("T2c 能力表透传 openai 活动后端",
          r.capabilities()["backend"] == "openai_compatible", str(r.capabilities()))
    reload_config({"inference_backend": "ollama"})


# ══════════ T3 list_models 并集 ══════════

async def t3_union_list_models():
    reload_config({"inference_backend": "ollama"})
    _wire()
    r = _routing()
    models = await r.list_models()
    by_name = {m.get("name"): m for m in models}
    check("T3a 并集含活动后端模型与包",
          "qwen3.8:latest" in by_name and "pack-a" in by_name, str(list(by_name)))
    check("T3b 两侧各带 source 标注",
          by_name.get("qwen3.8:latest", {}).get("source") == "ollama"
          and by_name.get("pack-a", {}).get("source") == "model_pack", str(models))
    mps.set_enabled("pack-a", False)
    names2 = [m.get("name") for m in await r.list_models()]
    check("T3c 禁用包即时退出并集", "pack-a" not in names2, str(names2))
    mps.set_enabled("pack-a", True)


# ══════════ T4/T5/T6 换装编排 ══════════

async def t4_swap_to_pack_unloads_active():
    reload_config({"inference_backend": "ollama"})
    _wire()
    ORDER.clear()
    FO.loaded = ["qwen3.8:latest"]
    r = _routing()
    await r.chat("pack-a", [{"role": "user", "content": "hi"}])
    kinds = [k for k, _ in ORDER]
    check("T4a 装包前活动后端驻留模型被卸载",
          ("ollama_unload", "qwen3.8:latest") in ORDER, str(ORDER))
    check("T4b 卸载先于 MP 对话（ensure_server 前腾内存）",
          "ollama_unload" in kinds and "mp_chat" in kinds
          and kinds.index("ollama_unload") < kinds.index("mp_chat"), str(ORDER))


async def t5_swap_to_active_stops_llama_server():
    reload_config({"inference_backend": "ollama"})
    _wire()
    ORDER.clear()
    calls = []
    orig_active, orig_stop = mpd.active_pack, mpd.stop_server

    async def _fake_stop(pack_id=None):
        calls.append(pack_id)
        ORDER.append(("driver_stop", pack_id))
        return True

    mpd.active_pack = lambda: "pack-a"
    mpd.stop_server = _fake_stop
    try:
        r = _routing()
        await r.chat("qwen3.8", [{"role": "user", "content": "hi"}])
        kinds = [k for k, _ in ORDER]
        check("T5a 回活动后端前 llama-server 被停掉",
              calls == [None], str(calls))
        check("T5b 停服先于 ollama 对话",
              "driver_stop" in kinds and "ollama_chat" in kinds
              and kinds.index("driver_stop") < kinds.index("ollama_chat"), str(ORDER))
        # 无活动包时不再停（热路径零代价）
        calls.clear()
        ORDER.clear()
        mpd.active_pack = lambda: None
        await r.chat("qwen3.8", [{"role": "user", "content": "hi"}])
        check("T5c llama-server 未跑时跳过停服",
              calls == [] and ("ollama_chat", "qwen3.8") in ORDER, str(ORDER))
    finally:
        mpd.active_pack, mpd.stop_server = orig_active, orig_stop


async def t6_bidirectional_unload():
    reload_config({"inference_backend": "ollama"})
    _wire()
    r = _routing()
    await r.unload_model("pack-a")
    check("T6a unload 包名 → MP 边（停 llama-server 语义）",
          FMP.unloaded == ["pack-a"] and FO.unloaded == [],
          f"mp={FMP.unloaded} ollama={FO.unloaded}")
    await r.unload_model("qwen3.8")
    check("T6b unload 普通模型 → ollama 边",
          FO.unloaded == ["qwen3.8"] and FMP.unloaded == ["pack-a"],
          f"mp={FMP.unloaded} ollama={FO.unloaded}")
    # 已禁用包仍归 MP 边（禁用后进程若仍在，必须把内存还回来）
    mps.set_enabled("pack-a", False)
    await r.unload_model("pack-a")
    check("T6c 禁用包 unload 仍归 MP 边",
          FMP.unloaded == ["pack-a", "pack-a"] and FO.unloaded == ["qwen3.8"],
          f"mp={FMP.unloaded}")
    mps.set_enabled("pack-a", True)
    # loaded 并集：调用方逐个 unload 即两边都卸
    FO.loaded = ["qwen3.8:latest"]
    FMP.loaded = ["pack-a"]
    loaded = await r.list_loaded_models()
    check("T6d loaded 并集（unload 全部=两边都卸的事实源）",
          sorted(loaded) == ["pack-a", "qwen3.8:latest"], str(loaded))
    FO.loaded, FMP.loaded = [], []


# ══════════ T7 model_package 旧配置兼容 ══════════

async def t7_degraded_model_package():
    reload_config({"inference_backend": "model_package"})
    _wire()
    ORDER.clear()
    calls = []
    orig_active, orig_stop = mpd.active_pack, mpd.stop_server

    async def _fake_stop(pack_id=None):
        calls.append(pack_id)
        return True

    mpd.active_pack = lambda: "pack-a"
    mpd.stop_server = _fake_stop
    try:
        r = _routing()
        out = await r.chat("qwen3.8", [{"role": "user", "content": "hi"}])
        check("T7a 退化模式任意 model 全走 MP",
              out == "MP-OK:qwen3.8" and FMP.chat_models[-1] == "qwen3.8"
              and FO.chat_models == [] and FOAI.chat_models == [], out)
        check("T7b 退化模式无跨引擎编排钩子（不停不卸）",
              calls == [] and not any(k == "ollama_unload" for k, _ in ORDER), str(ORDER))
        models = await r.list_models()
        check("T7c 退化模式列表仅 MP（0.4.29 行为原样）",
              [m.get("name") for m in models] == ["pack-a"], str(models))
        check("T7d 退化模式能力表=MP 能力表",
              r.capabilities().get("backend") == "model_package", str(r.capabilities()))
    finally:
        mpd.active_pack, mpd.stop_server = orig_active, orig_stop
        reload_config({"inference_backend": "ollama"})


# ══════════ T8 /api/asr/status 三态 + 容错 ══════════

def t8_asr_status_endpoint():
    from fastapi.testclient import TestClient
    from sidecar import app as appmod

    reload_config({"inference_backend": "ollama"})
    with TestClient(appmod.app) as client:
        # none：注册表文件根本不存在（无注册表容错，须 200 不 5xx）
        r = client.get("/api/asr/status")
        d = r.json()
        check("T8a 无注册表 → 200 none + 未安装文案",
              r.status_code == 200 and d.get("available") is False
              and d.get("state") == "none" and d.get("pack_id") is None
              and "尚未安装语音识别模型包" in (d.get("message") or ""), r.text[:240])

        # 装了 chat 包但没有 asr 包 → 仍 none
        r2 = client.get("/api/asr/status")
        check("T8b 只有 chat 包时仍 none", r2.json().get("state") == "none", r2.text[:200])

        # disabled：装了 asr 包但全禁用
        _install("asr-a", task="asr", enabled=False)
        r3 = client.get("/api/asr/status")
        d3 = r3.json()
        check("T8c 全禁用 → disabled + 全禁用文案",
              r3.status_code == 200 and d3.get("available") is False
              and d3.get("state") == "disabled" and d3.get("pack_id") is None
              and "已安装但全部被禁用" in (d3.get("message") or ""), r3.text[:240])

        # ready：启用即就绪；ready 状态不依赖 inference_backend（ASR 独立于推理后端）
        mps.set_enabled("asr-a", True)
        r4 = client.get("/api/asr/status")
        d4 = r4.json()
        check("T8d 启用 → ready + pack_id（安装即自动可用：register 默认启用语义）",
              r4.status_code == 200 and d4.get("available") is True
              and d4.get("state") == "ready" and d4.get("pack_id") == "asr-a"
              and d4.get("message") is None, r4.text[:240])
        reload_config({"inference_backend": "openai_compatible",
                       "inference_base_url": "http://localhost:1234/v1"})
        r5 = client.get("/api/asr/status")
        check("T8e ready 不依赖 inference_backend",
              r5.json().get("state") == "ready"
              and r5.json().get("pack_id") == "asr-a", r5.text[:200])
        reload_config({"inference_backend": "ollama"})

        # 注册表损坏 → 200 none（损坏按空装口径，不 5xx）
        mps.registry_path().write_text("{损坏的 JSON", encoding="utf-8")
        r6 = client.get("/api/asr/status")
        check("T8f 注册表损坏 → 200 none 容错",
              r6.status_code == 200 and r6.json().get("state") == "none", r6.text[:200])
        mps.registry_path().unlink()


# ══════════ main ══════════

async def _async_main():
    _install("pack-a")  # T1~T7 共用（T8 自装 asr-a）
    await t1_route_ollama_backend()
    await t2_route_openai_backend()
    await t3_union_list_models()
    await t4_swap_to_pack_unloads_active()
    await t5_swap_to_active_stops_llama_server()
    await t6_bidirectional_unload()
    await t7_degraded_model_package()


def main():
    _apply_mutation()
    try:
        asyncio.run(_async_main())
        t8_asr_status_endpoint()
    finally:
        _restore()

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)

    print(f"\n===== 0.4.30 路由连接器 + ASR 状态专项: PASS={PASS} FAIL={FAIL} =====")
    if MUTATE:
        if FAIL == 0:
            print(f"变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
            sys.exit(1)
        print(f"变异 {MUTATE} 已命中（FAIL={FAIL}，符合预期）: {', '.join(FAILURES)}")
        sys.exit(0)
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
