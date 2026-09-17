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
"""0.4.29（P2）模型包推理后端连接器（计划 D1 方案①新 backend）。

协议零改动继承 OpenAICompatConnector（SSE 分块 / 工具调用拼装 / 异常语义一字不动——
协议一致是审核一票否决项，openai_compat.py:22-26），只替换三件事：
  ① base_url 来源：config inference_base_url → 活动 llama-server 的 127.0.0.1 动态端口；
  ② 生命周期：chat/chat_stream 前确保目标包在跑（未跑 → llamacpp_driver 启动；
    换装 → 驱动停旧启新）；unload_model/list_loaded_models 覆盖父类 no-op 为真实实现
    （兑现 openai_compat.py:407 的留痕：llama.cpp 后端在子类覆盖为杀子进程）；
  ③ 模型清单：注册表里已安装且启用的 chat 包——不是问 llama-server /v1/models
    （那是单模型服务，只报当前加载的那一个，无法回答"我有哪些包可用"）。

model 参数＝pack_id。llama-server 是单模型服务，对请求里的 model 字段不做匹配校验，
转发无碍；真正起约束作用的是 ensure_server(model) 之前的注册表/清单检查。
"""
from __future__ import annotations

from typing import Any

from sidecar.model_packs import llamacpp_driver as _driver
from sidecar.model_packs import store as _store
from sidecar.ollama.connector import OllamaAPIError
from sidecar.ollama.openai_compat import OpenAICompatConnector


class ModelPackageConnector(OpenAICompatConnector):
    """模型包后端连接器（inference_backend="model_package" 时由工厂分发）。"""

    # ── ① 连接基础：地址来自驱动（动态端口），不读 config inference_base_url ──
    def _base(self) -> str:
        url = _driver.active_base_url()
        if not url:
            raise OllamaAPIError(
                "模型包服务未在运行（对话时会自动启动；看到本条多半意味着启动刚失败），"
                "请到「模型包」面板确认目标包已安装并启用", 400, "")
        return url

    def _config_state(self) -> tuple:
        """配置指纹：活动服务地址变化（换装换端口）→ 关闭旧连接重建。
        回环地址无代理/密钥语义，指纹只需地址本身。"""
        return (_driver.active_base_url() or "",)

    # ── ② 生命周期：对话前确保目标包在跑 ──
    async def _ensure_running(self, model: str) -> None:
        try:
            await _driver.ensure_server(model)
        except _driver.LlamaServerError as e:
            # 统一到后端业务错误语义（app.py 映射 400，中文明细直达用户）
            raise OllamaAPIError(str(e), 400, "") from e

    async def chat(self, model: str, messages: list[dict[str, Any]], *,
                   stream: bool = False, images: list[str] | None = None,
                   read_timeout_s: float | None = None) -> str:
        await self._ensure_running(model)
        return await super().chat(model, messages, stream=stream, images=images,
                                  read_timeout_s=read_timeout_s)

    async def chat_stream(self, model: str, messages: list[dict[str, Any]], *,
                          tools: list[dict[str, Any]] | None = None,
                          images: list[str] | None = None) -> Any:
        await self._ensure_running(model)
        async for ev in super().chat_stream(model, messages, tools=tools, images=images):
            yield ev

    # ── ③ 模型清单：注册表聚合（不问 llama-server /v1/models）──
    async def list_models(self) -> list[dict[str, Any]]:
        """已安装且启用的 chat 任务包。asr/embedding 包与已禁用包不出现在列表。"""
        out: list[dict[str, Any]] = []
        for p in _store.list_installed():
            if p.get("task") != "chat" or not p.get("enabled"):
                continue
            entry: dict[str, Any] = {"name": p["pack_id"],
                                     "size": int(p.get("size_bytes") or 0),
                                     "source": "model_pack"}
            if p.get("context_length"):
                entry["context_length"] = int(p["context_length"])
            out.append(entry)
        return out

    def capabilities(self) -> dict[str, Any]:
        """后端能力表（端点守卫与前端渲染的唯一事实源）。

        tools=True 依据 llama-server 的 OpenAI 兼容工具调用能力（官方支持 function
        calling）；若实测某版本有坑，再降为 False 并更新本注释。
        vision=False：多模态 GGUF（mmproj 双文件挂载）本批不接，保守声明。
        pull/delete=False：模型安装/卸载在「模型包」面板，不走 Ollama 语义。
        """
        return {"backend": "model_package", "tools": True, "vision": False,
                "pull": False, "delete": False}

    # ── 生命周期覆盖：父类 no-op → 真实的停子进程 ──
    async def unload_model(self, name: str) -> bool:
        """停止活动 llama-server 子进程（换装/工作流节点结束释放内存语义）。"""
        return await _driver.stop_server(name)

    async def list_loaded_models(self) -> list:
        """活动包列表（0 或 1 个）。safe_unload_model 据此决定要不要卸载——
        与 Ollama /api/ps 的"确在内存再卸"防护同构。"""
        active = _driver.active_pack()
        return [active] if active else []
