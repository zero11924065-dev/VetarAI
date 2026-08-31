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
