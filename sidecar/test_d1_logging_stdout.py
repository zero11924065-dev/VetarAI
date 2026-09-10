# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""D1（0.4.18）专项：日志长期不更新的根治（stdout 捕获 + print→logging）。

═══ 治的是什么（用户原话："之前说要修复的实则没修复"）═══
sidecar.log 长期只有启动几行、之后再不更新。真凶（2026-09-10 实测确认）：
main.js 的 spawn stdio 第二项是 'ignore' → **stdout 全丢**，而 uvicorn 访问日志
（`INFO: 127.0.0.1 - "GET /api/... 200 OK"`）走的正是 stdout（stderr 只有启动几行）。
TS-102 B10 当年只接了 stderr，漏了 stdout，故"日志不更新"从未真正修复。

═══ 关键事实（实测得出，勿凭直觉改）═══
1. ⛔ **stdout 的唯一来源是 uvicorn 访问日志**，logging_setup 只挂 RotatingFileHandler
   写 app.log、**不加 StreamHandler** → 结构化日志（`YYYY-.. | LEVEL |`）根本不冒到 stdout
   （开发/类生产两模式实测计数均 0）。故 sidecar.log(stdout) 与 app.log 内容**不重叠、无重复可去**。
   → 曾据错误假设在 main.js 写过"跳过 logging 行"的去重正则，实测证明是**死代码，已删**。
2. ⛔ **根因②"路径分歧"是文档误判**：main.js resolveLogsDir 与 Python resolve_log_dir
   逻辑**完全一致**（开发都=源码/logs，打包都回退=data_root/logs）。真根因只有①stdout 丢弃。
   故**不改** Python 的 resolve_log_dir（改它=修一个不存在的问题，还会破坏 test_logging 断言）。
3. ⛔ Python 侧 9 处 print 中：app.py(3)/config.store(2)/network.guard(1) 改 logging；
   **start_sidecar.py(2) 是 CLI 脚本、logging_setup.py:98 是 logging 初始化失败的兜底 → 必须保留 print**。

运行：.venv/bin/python -m sidecar.test_d1_logging_stdout
"""
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

PASS, FAIL = 0, 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


def main():
    repo = Path(__file__).resolve().parents[1]
    main_js = (repo / "main.js").read_text(encoding="utf-8")

    # ── T1 main.js：stdout 不再被丢弃（根因①的根治）──
    # ⛔ 这是 D1 的命门：stdio 第二项曾是 'ignore'。两处 spawn（打包/开发）都必须改 'pipe'。
    # ⛔⛔ 断言只取 stdio:[...] 的**数组部分**，必须先剥离行尾注释——注释里写了
    #    "由 'ignore' 改 'pipe'"，连注释一起算会被这些字样污染（本项目反复踩的坑：
    #    源码文本断言必须锚定代码形态、避开注释/docstring 干扰）。
    import re as _re
    stdio_arrays = _re.findall(r"stdio:\s*\[([^\]]*)\]", main_js)
    check("T1a main.js 两处 spawn 都有 stdio 数组配置", len(stdio_arrays) >= 2, str(stdio_arrays))
    check("T1b ⛔ 无任何 stdio 数组仍含 'ignore'（stdout 丢弃根因已除）",
          all("ignore" not in arr for arr in stdio_arrays), str(stdio_arrays))
    check("T1c stdio 数组三项均为 pipe（stdin/stdout/stderr 都接管）",
          all(arr.count("'pipe'") == 3 for arr in stdio_arrays), str(stdio_arrays))

    # ── T2 main.js：stdout + stderr 都接到日志写入（缺一就是只修了一半）──
    check("T2a 监听 sidecarProcess.stdout.on('data')",
          "sidecarProcess.stdout.on('data'" in main_js)
    check("T2b 监听 sidecarProcess.stderr.on('data')（既有不得退化）",
          "sidecarProcess.stderr.on('data'" in main_js)
    check("T2c 两路都经同一 writeChunk 写入（统一落 sidecar.log）",
          main_js.count("writeChunk('stdout'") == 1 and main_js.count("writeChunk('stderr'") == 1)

    # ── T3 main.js：⛔ 不得残留"跳过 logging 行"的死代码（实测证明永不触发）──
    check("T3a 无 LOGGING_LINE 去重正则（实测 logging 不冒 stdout，该逻辑是死代码）",
          "LOGGING_LINE" not in main_js)
    check("T3b 无按 logging 格式过滤 stdout 的 filter（死代码）",
          ".filter(ln" not in main_js)
    # 但空 chunk 守卫应保留（uvicorn 尾部空行，非死代码）
    check("T3c 保留空 chunk 守卫（防日志噪声，非死代码）",
          "if (!text.trim()) return;" in main_js)

    # ── T4 Python：startup/shutdown 的 print 已改 logging（落 app.log 而非被丢的 stdout）──
    app_py = (repo / "sidecar" / "app.py").read_text(encoding="utf-8")
    check("T4a app.py startup 配置加载用 _log（不再 print）",
          '_log.info("config loaded from' in app_py)
    check("T4b app.py startup ollama/data_root 用 _log",
          '_log.info("ollama=%s data_root=%s"' in app_py)
    check("T4c app.py shutdown connector 错误用 _log.warning",
          '_log.warning("connector close error' in app_py)
    check("T4d app.py 已无 print(flush=True)（全部改 logging）",
          "print(f\"[sidecar]" not in app_py)

    # config.store / network.guard 同样改 logging
    store_py = (repo / "sidecar" / "config" / "store.py").read_text(encoding="utf-8")
    guard_py = (repo / "sidecar" / "network" / "guard.py").read_text(encoding="utf-8")
    check("T4e config.store 有模块 logger", 'getLogger("sidecar.config")' in store_py)
    check("T4f config.store 读失败/熔断失败用 _log.warning",
          '_log.warning("failed to read' in store_py
          and "切换网络模式后重置熔断器失败" in store_py
          and store_py.count("print(f\"[config]") == 0)
    check("T4g network.guard 有模块 logger 且名单写入告警用 _log.warning",
          'getLogger("sidecar.guard")' in guard_py
          and '_log.warning("写入「需代理」名单失败' in guard_py
          and guard_py.count("print(f\"[guard]") == 0)

    # ── T5 Python：⛔ 必须保留的 print 不被误删（CLI + logging 兜底）──
    start_py = (repo / "sidecar" / "start_sidecar.py").read_text(encoding="utf-8")
    lsetup_py = (repo / "sidecar" / "logging_setup.py").read_text(encoding="utf-8")
    check("T5a start_sidecar.py 的 CLI print 保留（终端脚本，改 logging 反而看不到启动信息）",
          "print(" in start_py)
    check("T5b logging_setup.py 初始化失败兜底 print 保留（logging 本身坏了不能靠 logging 报）",
          "print(f\"[logging_setup] 初始化失败" in lsetup_py)

    # ── T6 行为验证：startup logger 真能落盘（端到端，不只看源码）──
    # 用 app 的真实 logger 写一条，确认 root handler 收到（与 test_logging 同一机制）。
    import sidecar.logging_setup as ls
    ls.reset_for_test()
    log_path = ls.setup_logging()
    marker = "D1_STARTUP_PROBE_甲乙丙"
    logging.getLogger("sidecar.app").info(marker)
    for h in logging.getLogger().handlers:
        h.flush()
    content = Path(log_path).read_text(encoding="utf-8") if log_path else ""
    check("T6a startup logger 的消息真落盘 app.log", marker in content, content[-160:])
    check("T6b 日志含结构化级别与 logger 名", "| INFO | sidecar.app |" in content)
    ls.reset_for_test()

    # ── T7 根因②澄清：两侧路径解析逻辑一致（断言"不改 Python 路径"是对的）──
    # main.js 与 Python 都是「源码/logs 优先 → 失败回退 data_root/logs」。
    check("T7a main.js resolveLogsDir：源码 logs 优先 + dataRoot 回退",
          "__dirname, 'logs'" in main_js and "dataRootExpanded" in main_js)
    check("T7b Python resolve_log_dir：源码 logs 优先 + data_root 回退（逻辑一致，故无需改）",
          'app_dir / "logs"' in lsetup_py and "data_root()" in lsetup_py)

    print(f"\n===== D1 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
