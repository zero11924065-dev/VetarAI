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
"""0.4.29（P1 可扩展模型包）：模型包后端子系统。

模块划分：
  * manifest.py   —— catalog.json / PACK 条目的规范校验（纯函数，无 IO）
  * store.py      —— 安装根解析（env > config > data_root()/models/packs）+
                     registry.json 注册表（tmp+os.replace 原子写，plugins_state.json 先例）
  * downloader.py —— httpx 流式下载器（guard 三段式 + Range 断点续传 + SHA256 校验
                     + 多源回退 + file:// 本地源），进度经 app_events 推 SSE
  * llamacpp_driver.py（P2）—— llama-server 子进程生命周期（spawn/健康探测/换装/停止）
  * mp_connector.py（P2）—— ModelPackageConnector：工厂第三分支的推理连接器
                     （协议零改动继承 OpenAICompatConnector）

安全边界（D7）：模型包只含权重 + manifest，不含可执行代码；
files[].path 一律相对路径校验，拒绝对路径 / .. / 分隔符开头（防路径穿越）。
"""
from sidecar.model_packs.manifest import (
    TASKS, FORMATS, DRIVERS,
    valid_pack_id, validate_rel_path, validate_pack, validate_catalog,
)
from sidecar.model_packs.store import (
    packs_root, pack_dir, partial_dir,
    read_registry, is_installed, get_entry, list_installed, read_manifest,
    register_pack, unregister_pack, set_enabled, remove_pack,
)
from sidecar.model_packs.downloader import (
    PackDownloadError, ModelPackDownloadManager, pack_download_manager,
    download_pack, fetch_catalog,
)
