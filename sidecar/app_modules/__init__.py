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
"""0.4.9（3.48.2）：应用内模块控制包——Agent 自主调动应用内模块。

新模块接入方式：在 registry.APP_MODULE_REGISTRY 登记一条即可，
Agent 立刻获得调用能力（无需改 loop.py 或前端）。
"""
from sidecar.app_modules.registry import (
    APP_MODULE_REGISTRY,
    dispatch,
    list_actions,
    action_needs_confirm,
    build_module_catalog_text,
)

__all__ = ["APP_MODULE_REGISTRY", "dispatch", "list_actions",
           "action_needs_confirm", "build_module_catalog_text"]
