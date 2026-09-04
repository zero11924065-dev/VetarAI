#!/usr/bin/env python3
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
"""Entry point for the Python sidecar. Reads host/port from config.json."""
import sys, os
# Add parent directory to path so "sidecar.app" resolves
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import uvicorn
from sidecar.config import get_config
from sidecar.logging_setup import setup_logging

if __name__ == '__main__':
    # checkpoint-043：报错/bug 落盘日志（应用目录内 logs/，失败不阻塞启动）
    log_path = setup_logging()
    cfg = get_config()
    host = cfg["sidecar_host"]
    port = int(cfg["sidecar_port"])
    print(f'Starting SubAgent sidecar on {host}:{port} ...')
    if log_path:
        print(f'日志文件：{log_path}')
    uvicorn.run(
        'sidecar.app:app',
        host=host,
        port=port,
        log_level='info',
    )
