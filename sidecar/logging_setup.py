"""应用日志统一初始化（checkpoint-043，用户需求二）。

目标：运行中出现的报错/bug 可落盘排查。

日志目录策略（与用户需求一致："默认保存在应用文件内的日志文件夹"）：
- 开发模式（源码可写）：<应用目录>/logs/   —— 即 subagent/logs/
- 打包模式（源码目录只读/不存在，如 asar 解包临时目录）：回退 <data_root>/logs/

格式：时间 | 级别 | 模块 | 消息；RotatingFileHandler 2MB × 3 个备份，防膨胀。
幂等：重复调用（测试多次 import）不叠加 handler；SUBAGENT_NO_FILE_LOG=1 可禁用
文件输出（单测隔离场景）。
"""
from __future__ import annotations

import logging
import os
from logging.handlers import RotatingFileHandler
from pathlib import Path

LOG_FILE_NAME = "app.log"
_FORMATTER = logging.Formatter(
    "%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
_SETUP_DONE = False


def resolve_log_dir() -> Path:
    """确定日志目录：应用目录内优先，不可写时回退数据目录。"""
    # sidecar/ 的父目录 = 应用目录
    app_dir = Path(__file__).resolve().parents[1]
    candidate = app_dir / "logs"
    try:
        candidate.mkdir(parents=True, exist_ok=True)
        # 写探测（目录可建但可能只读）
        probe = candidate / ".probe"
        probe.write_text("", encoding="utf-8")
        probe.unlink()
        return candidate
    except Exception:
        pass
    # 回退：数据目录（打包场景）
    try:
        from sidecar.config import data_root
        fb = Path(data_root()) / "logs"
        fb.mkdir(parents=True, exist_ok=True)
        return fb
    except Exception:
        # 最后兜底：用户目录（绝不因日志失败阻塞应用）
        fb = Path.home() / ".subagent" / "logs"
        fb.mkdir(parents=True, exist_ok=True)
        return fb


def setup_logging(level: int = logging.INFO) -> Path | None:
    """初始化 root 日志（幂等）。返回日志文件路径（禁用时 None）。"""
    global _SETUP_DONE
    if _SETUP_DONE:
        return getattr(setup_logging, "_log_path", None)
    _SETUP_DONE = True

    root = logging.getLogger()
    root.setLevel(level)

    if os.environ.get("SUBAGENT_NO_FILE_LOG"):
        setup_logging._log_path = None  # type: ignore[attr-defined]
        return None

    try:
        log_dir = resolve_log_dir()
        log_path = log_dir / LOG_FILE_NAME
        handler = RotatingFileHandler(
            log_path, maxBytes=2 * 1024 * 1024, backupCount=3, encoding="utf-8")
        handler.setFormatter(_FORMATTER)
        root.addHandler(handler)
        setup_logging._log_path = log_path  # type: ignore[attr-defined]
        logging.getLogger("sidecar").info(
            "日志初始化完成 → %s", log_path)
        return log_path
    except Exception as e:  # 日志失败绝不阻塞应用启动
        print(f"[logging_setup] 初始化失败（不影响运行）: {e}")
        setup_logging._log_path = None  # type: ignore[attr-defined]
        return None


def reset_for_test() -> None:
    """测试专用：重置幂等标记并移除已加的文件 handler。"""
    global _SETUP_DONE
    root = logging.getLogger()
    for h in list(root.handlers):
        if isinstance(h, RotatingFileHandler):
            root.removeHandler(h)
            h.close()
    _SETUP_DONE = False
    if hasattr(setup_logging, "_log_path"):
        delattr(setup_logging, "_log_path")
