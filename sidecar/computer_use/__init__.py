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
"""0.4.9（3.48.1）：Computer Use 一期 MVP——Agent 看屏幕、点鼠标、敲键盘。

⚠️ 直接操作用户真实电脑，风险高。五道安全防线（总开关默认关 / 每步确认 /
白名单 / 权限探测 / 全程日志）缺一不可，详见 executor.py 文件头。
一期只支持 macOS（screencapture + JXA/CoreGraphics，零第三方依赖）。
"""
from sidecar.computer_use.executor import (
    take_screenshot, mouse_click, keyboard_type, keyboard_hotkey,
    check_capabilities, frontmost_app, check_whitelist, check_permission_for,
)

__all__ = ["take_screenshot", "mouse_click", "keyboard_type", "keyboard_hotkey",
           "check_capabilities", "frontmost_app", "check_whitelist",
           "check_permission_for"]
