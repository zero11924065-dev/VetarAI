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
"""0.4.30 路由连接器：模型包与 ollama/openai 推理后端**并行可用**（不再二选一）。

0.4.29 的「第三后端」形态（inference_backend=model_package 才走模型包）实测不满足
需求：模型包的本意是**补充** ollama 加载不了的模型，要与活动后端一起开启、参与
换装编排。本连接器是工厂的唯一返回形态，包装两个单例：
  * 活动后端连接器（OllamaConnector / OpenAICompatConnector，按 config 动态解析）；
  * ModelPackageConnector 单例（llama.cpp 驱动）。

路由规则（chat / chat_stream）：
  model 参数命中「已安装且启用中的 chat 模型包 pack_id」→ ModelPackageConnector；
  否则 → 活动后端连接器。
  兼容：inference_backend=model_package 旧配置继续可用——路由退化为全走模型包
  （0.4.29 行为原样保留：列表/能力表/对话全部直连 MP 侧，无跨引擎编排钩子）。

统一模型列表：list_models() = 活动后端模型（标 source=后端名）+ 已安装启用中的
chat 包（mp_connector 标 source="model_pack"）。委派选模型（delegation.py）、
模型画像过滤（app.py）等下游只读 name 字段，零改动自然可见模型包。
活动后端不可达时其异常照常上抛（/api/inference/status 的 online 判定语义不变），
不做静默降级——列表可用性以后端健康为准，与 0.4.29 口径一致。

跨引擎内存编排（换装编排，三个方向）：
  ① 路由命中模型包、MP 侧 ensure_server 之前：把活动后端已驻留内存的模型逐卸
     （复用 agent_engine/loop.py 的 safe_unload_model 双防护语义——先查
     list_loaded_models 确认在内存再卸、卸载与查 ps 各自独立超时、任何失败静默
     不阻塞主流程；0.4.7「为卸载而加载」事故的防线，不新造一套）。llamacpp_driver
     自身的「同时只跑一个对话包」语义不变。
  ② 路由命中活动后端而 llama-server 正在跑：先 stop_server 停掉子进程再放行——
     把数 GB 内存还给系统（stop_server 的名字匹配防护在驱动层已有，此处无条件停
     当前活动包；无活动进程时是一次廉价的状态查询，不增加热路径负担）。
  ③ safe_unload_model / unload_model 公开入口经本层双向分发：按 model 名归路由
     （命中 chat 包——含已禁用包，禁用后进程若仍在必须把内存还回来——走 MP 侧
     停子进程；否则走活动后端 keep_alive=0）；list_loaded_models 返回两侧并集，
     调用方逐个 unload 即「两边都卸」。

能力表：capabilities() 取活动后端能力原样透传（openai 后端 tools 语义不变）；
model_package 退化模式下透传 MP 能力表（与 0.4.29 一致）。
"""
from __future__ import annotations

import logging
from typing import Any

_log = logging.getLogger("sidecar.ollama.routing")


class RoutingConnector:
    """按 model 名归边的路由连接器（工厂 get_inference_connector 的唯一返回形态）。

    无内部状态：活动后端按 config 每次调用动态解析（设置页切换后端即时生效，
    与 OllamaConnector._config_state 的动态读配置哲学一致）；两侧连接器本体都是
    connector.py 的模块级单例。
    """

    # ── 连接器解析（每次调用动态读 config）──
    @staticmethod
    def _backend() -> str:
        from sidecar.config import get_config
        return str(get_config().get("inference_backend", "ollama")).strip()

    def _mp(self) -> Any:
        from sidecar.ollama import connector as _conn
        return _conn._mp_singleton()

    def _active(self) -> Any:
        from sidecar.ollama import connector as _conn
        b = self._backend()
        if b == "openai_compatible":
            return _conn._openai_singleton()
        if b == "model_package":
            # 旧配置兼容：活动侧即 MP，路由退化（见 _route_to_pack）
            return self._mp()
        return _conn._ollama_singleton()

    def active_connector(self) -> Any:
        """当前活动后端连接器（测试/诊断用公开入口；能力表透传同源的解析结果）。"""
        return self._active()

    def _degraded(self) -> bool:
        """model_package 旧配置 → 路由退化为全走 MP（0.4.29 行为原样保留）。"""
        return self._backend() == "model_package"

    # ── 路由判定 ──
    def _is_chat_pack(self, model: str, *, any_status: bool = False) -> bool:
        """model 是否命中已安装的 chat 模型包。

        any_status=False（对话路由）：须启用中（status=installed）——禁用包不参与
        并行编排，落到活动后端按普通模型处理（多半报模型不存在，语义如实）。
        any_status=True（卸载路由）：含已禁用包——禁用后若进程仍在跑，卸载入口
        必须能把内存还回来（名字匹配防护在驱动 stop_server 层）。
        注册表是小 JSON 整读，每次对话读一次的开销与 llamacpp_driver 注册表门禁
        同款口径，相对一次推理调用可忽略。
        """
        if not model:
            return False
        from sidecar.model_packs import store as _store
        entry = _store.get_entry(str(model))
        if not entry or entry.get("task") != "chat":
            return False
        return any_status or entry.get("status") == "installed"

    def _route_to_pack(self, model: str) -> bool:
        if self._degraded():
            return True
        return self._is_chat_pack(model)

    # ── 跨引擎换装编排（两个前置钩子；全部失败静默，绝不阻塞对话主流程）──
    async def _pre_swap_to_pack(self) -> None:
        """方向①：即将 ensure_server 加载数 GB 权重前，先卸活动后端驻留模型。

        复用 loop.safe_unload_model（先查 ps 再卸 + 独立超时 + 失败静默），
        不新造卸载路径；openai 活动后端 list_loaded_models 是 no-op 空列表，
        天然跳过。延迟导入 loop（其模块依赖链会回引 connector，模块级 import 成环）。
        """
        active = self._active()
        if active is self._mp():
            return  # 退化模式：活动侧即 MP，驱动自己管换装
        try:
            loaded = await active.list_loaded_models()
        except Exception:
            return
        if not loaded:
            return
        from sidecar.agent_engine.loop import safe_unload_model
        for name in loaded:
            try:
                await safe_unload_model(active, str(name))
            except Exception:
                pass  # 卸载只是内存优化，失败不阻塞对话
        _log.info("换装编排：路由至模型包前已请求卸载活动后端驻留模型 %s", loaded)

    async def _pre_swap_to_active(self) -> None:
        """方向②：路由命中活动后端，llama-server 在跑则先停（还内存）再放行。

        无活动包时 active_pack() 只是一次进程 poll，开销可忽略；
        stop_server 失败（如进程卡死）如实记日志但不阻断对话——对话是主流程。
        """
        from sidecar.model_packs import llamacpp_driver as _drv
        try:
            if _drv.active_pack() is None:
                return
            stopped = await _drv.stop_server()
            if stopped:
                _log.info("换装编排：路由至活动后端前已停止 llama-server（释放内存）")
        except Exception as e:
            _log.warning("换装编排：停止 llama-server 失败（不阻断对话）: %s", e)

    # ── 对话（路由 + 编排钩子）──
    async def chat(self, model: str, messages: list[dict[str, Any]], *,
                   stream: bool = False, images: list[str] | None = None,
                   read_timeout_s: float | None = None) -> str:
        if self._route_to_pack(model):
            await self._pre_swap_to_pack()
            return await self._mp().chat(model, messages, stream=stream, images=images,
                                         read_timeout_s=read_timeout_s)
        await self._pre_swap_to_active()
        return await self._active().chat(model, messages, stream=stream, images=images,
                                         read_timeout_s=read_timeout_s)

    async def chat_stream(self, model: str, messages: list[dict[str, Any]], *,
                          tools: list[dict[str, Any]] | None = None,
                          images: list[str] | None = None) -> Any:
        if self._route_to_pack(model):
            await self._pre_swap_to_pack()
            gen = self._mp().chat_stream(model, messages, tools=tools, images=images)
        else:
            await self._pre_swap_to_active()
            gen = self._active().chat_stream(model, messages, tools=tools, images=images)
        async for ev in gen:
            yield ev

    # ── 统一模型列表（并集 + source 标注）──
    async def list_models(self) -> list[dict[str, Any]]:
        """活动后端模型（source=后端名）+ 启用中的 chat 包（source="model_pack"）。

        退化模式（model_package）只回 MP 列表——0.4.29 行为原样保留。
        活动后端异常照常上抛：/api/inference/status 的 online 判定依赖它，
        静默降级会把"后端掉线"伪装成"在线"，状态语义不许改。
        """
        if self._degraded():
            return await self._mp().list_models()
        backend = self._backend()
        out: list[dict[str, Any]] = []
        for m in await self._active().list_models():
            if isinstance(m, dict) and "source" not in m:
                m = dict(m, source=backend)
            out.append(m)
        out.extend(await self._mp().list_models())
        return out

    # ── 能力表：活动后端原样透传（退化模式=MP 能力表）──
    def capabilities(self) -> dict[str, Any]:
        return self._active().capabilities()

    # ── 生命周期（方向③：双向分发 + 并集）──
    async def unload_model(self, name: str) -> bool:
        """按 model 名归路由：chat 包（含已禁用）→ MP 停子进程；否则 → 活动后端。"""
        if self._degraded() or self._is_chat_pack(name, any_status=True):
            return await self._mp().unload_model(name)
        return await self._active().unload_model(name)

    async def list_loaded_models(self) -> list:
        """两侧驻留并集——调用方逐个 unload 即「两边都卸」（unload 全部语义）。

        单侧查询失败不拖死另一侧（卸载只是内存优化，与 safe_unload_model 的
        失败静默哲学一致）。
        """
        if self._degraded():
            return await self._mp().list_loaded_models()
        out: list = []
        for conn in (self._active(), self._mp()):
            try:
                out.extend(await conn.list_loaded_models() or [])
            except Exception:
                pass
        return out

    # ── ollama 专属操作：委托活动后端（能力表已先行拦截不支持的后端）──
    async def pull_model(self, name: str) -> Any:
        return await self._active().pull_model(name)

    async def delete_model(self, name: str) -> bool:
        return await self._active().delete_model(name)

    async def aclose_all(self) -> None:
        """应用退出时关闭全部已建单例的连接池（三侧都关，未建的跳过）。"""
        from sidecar.ollama import connector as _conn
        for conn in (_conn._SINGLETON, _conn._OPENAI_SINGLETON, _conn._MP_SINGLETON):
            if conn is None:
                continue
            try:
                await conn.aclose_all()
            except Exception:
                pass
