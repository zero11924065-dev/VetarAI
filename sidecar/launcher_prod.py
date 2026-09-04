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
"""checkpoint-063：生产启动器（PyInstaller 打包入口）。

与 start_sidecar.py 的区别：
- 直接 import app 对象，不用字符串模块名（PyInstaller 冻结环境不支持 'sidecar.app:app' 字符串解析）
- 用 app.getPath 兼容打包后的资源路径
"""
from __future__ import annotations

import sys
import os

# 打包后确保能 import sidecar 包
if getattr(sys, 'frozen', False):
    # PyInstaller onedir/onefile：_MEIPASS 指向解压的资源目录
    base = getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    sys.path.insert(0, base)

import uvicorn
from sidecar.app import app

if __name__ == '__main__':
    host = os.environ.get('VETARAI_HOST', '127.0.0.1')
    port = int(os.environ.get('VETARAI_PORT', '8765'))
    uvicorn.run(app, host=host, port=port, log_level='info')
