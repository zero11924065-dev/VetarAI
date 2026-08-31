#!/usr/bin/env python3
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
