#!/usr/bin/env python3
"""checkpoint-063 封装：侧车生产启动器（PyInstaller 打包入口）。

与开发版 start_sidecar.py 的区别：
- 直接 import app 对象（PyInstaller 静态分析友好；字符串模块引用在冻结环境不可靠）
- 通过 --host/--port 接收参数（main.js 打包模式传入，与开发模式契约一致）
"""
import argparse

import uvicorn
from sidecar.app import app

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level='info')
