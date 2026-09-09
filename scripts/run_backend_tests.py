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
"""第 0 批测试加固（0.4.14）：统一隔离后端测试 runner。

为什么需要它（0.4.13 实测教训，⛔ 改任何会写 config/数据的代码前必读）：
  审计发现**约 30 个**后端套件在「真实 HOME + 不设 VETARAI_DATA_ROOT」下会写进真实
  ~/.subagent/config.json —— 因为它们只桩 get_config、不桩写入路径，而
  guard_report_failure / reload_config 等会真写盘。我上一轮就因此污染过一次用户真实
  config（写入 google.com + 打乱键序，逐字节还原）。逐个改 30 个文件风险高、易漏；
  本 runner 用**统一入口强制隔离** + **跑后校验真实数据 md5 未变**，一次覆盖全部，
  从根上杜绝"测试污染用户真实数据"这类 bug 再次发生。

隔离手段（比假 HOME 更精准）：
  给每个套件子进程设 VETARAI_DATA_ROOT=<一次性临时目录>。data_root() 优先读该环境变量，
  故套件的所有读写都落在临时目录，真实 ~/.subagent 完全不被触碰。
  （不用假 HOME：那会连带影响 git/ssh 等与测试无关的东西。）

污染哨兵：
  跑前对真实 data_root 下的 config.json 与所有 *.db 做 md5 快照；每个套件跑完立即比对，
  一旦发现真实数据被改，标记该套件为「污染源」并让整个 runner 以非 0 退出——
  这样"不自隔离的测试"会**自己暴露**，而不是悄悄损坏用户数据。

用法：
  .venv/bin/python scripts/run_backend_tests.py              # 跑全部
  .venv/bin/python scripts/run_backend_tests.py -k ts103     # 只跑模块名含 ts103 的
  .venv/bin/python scripts/run_backend_tests.py -v           # 打印每个套件的完整输出
  .venv/bin/python scripts/run_backend_tests.py --no-sentinel  # 关闭污染哨兵（不建议）

退出码：0 = 全过（SKIP 不算失败）；1 = 有真失败 / 检测到污染 / 运行异常。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# subagent 根目录（本脚本在 subagent/scripts/ 下）
ROOT = Path(__file__).resolve().parents[1]
PYTHON = str(ROOT / ".venv" / "bin" / "python")
if not Path(PYTHON).exists():           # 兜底：用当前解释器
    PYTHON = sys.executable

# 测试文件发现范围与排除项
EXCLUDE_PARTS = {".venv", "node_modules", "__pycache__", "dist", "build", ".git"}

# 第 0 批：慢套件清单（--fast 模式跳过）。
# ⛔ 这两个套件占了全量 338s 的约 85%（实测 h15_e2e≈107s、checkpoint062_stress≈182s），
# 而第 0 批的核心目标是「**改代码必跑**的最小回归集」——5 分钟没人会每次改代码都跑，
# 安全网就会被绕过（等于没有）。故 fast 模式排除它们，把"必跑"压到 ~1 分钟；
# 这两个慢套件仍纳入**打包前的全量回归**（不带 --fast）。
# 用模块名后缀匹配，避免硬编码全路径在重构后失效。
SLOW_SUFFIXES = ("test_h15_e2e", "test_checkpoint062_stress")


def discover_suites(fast: bool = False) -> list[str]:
    """递归发现所有 test_*.py，返回点号模块名（相对 subagent 根）。

    ⛔ 用递归 glob 而非硬编码清单——新增测试自动纳入，无需维护列表
      （此前审计只覆盖 sidecar/、tools/、agent_engine/ 三处，漏了 knowledge/ 等）。
    fast=True 时跳过 SLOW_SUFFIXES（见其注释：为"改代码必跑"压缩时长）。
    """
    mods: list[str] = []
    for p in (ROOT / "sidecar").rglob("test_*.py"):
        if any(part in EXCLUDE_PARTS for part in p.parts):
            continue
        if fast and any(p.stem == suf for suf in SLOW_SUFFIXES):
            continue
        rel = p.relative_to(ROOT).with_suffix("")
        mods.append(".".join(rel.parts))
    return sorted(set(mods))


def _md5(path: Path) -> str:
    try:
        return hashlib.md5(path.read_bytes()).hexdigest()
    except OSError:
        return "<unreadable>"


def real_data_root() -> Path:
    """用户真实数据目录（不带 VETARAI_DATA_ROOT 时的 data_root）。"""
    # 与 config.store.data_root() 同源：默认 ~/.subagent，可被 config 的 data_root 覆盖。
    # 这里只做哨兵用途，直接取默认；若用户改过 data_root，哨兵仍覆盖默认位置（够用）。
    return Path(os.environ.get("VETARAI_REAL_DATA_ROOT", str(Path.home() / ".subagent")))


def snapshot_real_data() -> dict[str, str]:
    """对真实 data_root 下的 config.json 与所有 *.db 做 md5 快照（哨兵基线）。

    只盯小文件（config + db）：测试污染几乎总是写这两类；models/ 下大文件测试不会碰，
    全量 md5 太慢。足以抓住"测试写了真实配置/数据库"。
    """
    root = real_data_root()
    snap: dict[str, str] = {}
    if not root.exists():
        return snap
    cfg = root / "config.json"
    if cfg.exists():
        snap[str(cfg)] = _md5(cfg)
    for db in root.rglob("*.db"):
        if any(part in EXCLUDE_PARTS for part in db.parts):
            continue
        snap[str(db)] = _md5(db)
    return snap


def diff_snapshot(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """返回被改动的真实文件路径（新增/内容变化都算）。"""
    changed = []
    for k, v in after.items():
        if before.get(k) != v:
            changed.append(k)
    return changed


def classify(rc: int, output: str) -> str:
    """退出码 + 输出 → PASS / SKIP / FAIL。

    约定（与现有套件一致）：0=PASS；2 且输出含 "SKIP"=优雅跳过（需真实模型/Ollama）；
    其余=FAIL。⛔ 不能把 SKIP 当 FAIL——m31/m32 需真实 qwen3.8，本机常态跳过。
    """
    if rc == 0:
        return "PASS"
    if rc == 2 and "SKIP" in output:
        return "SKIP"
    return "FAIL"


def run_suite(mod: str, verbose: bool, sentinel: bool) -> tuple[str, str, float, list[str]]:
    """在隔离临时数据目录下跑一个套件。返回 (状态, 摘要行, 耗时秒, 污染文件列表)。"""
    before = snapshot_real_data() if sentinel else {}
    tmp = tempfile.mkdtemp(prefix="vetarai_test_")
    env = dict(os.environ)
    env["VETARAI_DATA_ROOT"] = tmp          # ⛔ 隔离核心：所有**写**落临时目录
    env.pop("VETARAI_REAL_DATA_ROOT", None)  # 哨兵基线用真实路径，别被子进程继承干扰
    env["PYTHONWARNINGS"] = "ignore"
    # ⛔ 0.4.14 修复 runner 自身的设计缺陷：只隔离 VETARAI_DATA_ROOT 会**误伤需要真实
    # bge-m3 模型的测试**（test_embedder / test_hybrid_search）——它们要读 {data_root}/models/
    # 下的权重，data_root 一指到空临时目录，模型就找不到，套件从 PASS 变 FAIL。
    # embedder.py 的模型解析有独立环境变量 VETARAI_MODELS_DIR（三级回退的第 2 级），
    # 可让**只读模型目录**脱离 data_root 单独指向真实位置。于是：写隔离（临时 data_root）
    # + 读共享（真实 models，只读推理不污染），两者兼得。实测组合后两套件恢复 13/0、11/0，
    # 且真实 config.json 与 _global.db 的 md5 全程未变。
    real_models = real_data_root() / "models"
    if real_models.is_dir():
        env["VETARAI_MODELS_DIR"] = str(real_models)
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            [PYTHON, "-m", mod],
            cwd=str(ROOT), env=env,
            capture_output=True, text=True, timeout=600,
        )
        rc, out = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired:
        rc, out = 124, "TIMEOUT: 套件超过 600s 未结束"
    finally:
        # 清理临时数据目录（即便失败也清，避免 /tmp 堆积）
        subprocess.run(["rm", "-rf", tmp], capture_output=True)
    dt = time.monotonic() - t0
    status = classify(rc, out)
    # 摘要：取输出里的 SUMMARY/PASS=/专项 行，没有则取末行
    summary = ""
    for line in reversed(out.strip().splitlines()):
        if any(k in line for k in ("SUMMARY", "PASS=", "专项", "passed", "Tests ")):
            summary = line.strip()
            break
    if not summary:
        summary = (out.strip().splitlines() or [f"exit={rc}"])[-1].strip()[:90]
    # 污染哨兵：跑后比对真实数据
    polluted: list[str] = []
    if sentinel:
        polluted = diff_snapshot(before, snapshot_real_data())
    if verbose:
        print(out)
    return status, summary[:90], dt, polluted


def main() -> int:
    ap = argparse.ArgumentParser(description="VetarAI 后端统一隔离测试 runner（第 0 批）")
    ap.add_argument("-k", dest="keyword", default="", help="只跑模块名含该子串的套件")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印每个套件完整输出")
    ap.add_argument("--no-sentinel", action="store_true", help="关闭真实数据污染哨兵（不建议）")
    ap.add_argument("--fast", action="store_true",
                    help="跳过慢套件（h15_e2e/checkpoint062_stress），压缩到~1分钟，供改代码必跑")
    args = ap.parse_args()

    sentinel = not args.no_sentinel
    suites = discover_suites(fast=args.fast)
    if args.keyword:
        suites = [s for s in suites if args.keyword.lower() in s.lower()]
    if not suites:
        print("未发现匹配的测试套件")
        return 1

    print(f"发现 {len(suites)} 个后端套件；隔离=VETARAI_DATA_ROOT 临时目录；"
          f"污染哨兵={'开' if sentinel else '关'}")
    if sentinel:
        base = snapshot_real_data()
        print(f"真实数据哨兵基线：{len(base)} 个文件（config.json + *.db）")
    print("-" * 78)

    counts = {"PASS": 0, "SKIP": 0, "FAIL": 0}
    fails: list[tuple[str, str]] = []
    skips: list[str] = []
    polluters: list[tuple[str, list[str]]] = []
    total_t = 0.0

    for mod in suites:
        status, summary, dt, polluted = run_suite(mod, args.verbose, sentinel)
        total_t += dt
        counts[status] = counts.get(status, 0) + 1
        mark = {"PASS": "✓", "SKIP": "○", "FAIL": "✗"}[status]
        flag = "  ⚠️污染真实数据!" if polluted else ""
        print(f"{mark} {status:<4} {mod:<44} {dt:5.1f}s  {summary}{flag}")
        if status == "FAIL":
            fails.append((mod, summary))
        elif status == "SKIP":
            skips.append(mod)
        if polluted:
            polluters.append((mod, polluted))

    print("-" * 78)
    print(f"合计 {len(suites)} 套件：PASS={counts['PASS']}  SKIP={counts['SKIP']}  "
          f"FAIL={counts['FAIL']}  用时 {total_t:.0f}s")
    if skips:
        print(f"SKIP（需真实模型/Ollama，非失败）：{', '.join(s.split('.')[-1] for s in skips)}")
    if fails:
        print("失败套件：")
        for mod, s in fails:
            print(f"  ✗ {mod}  —  {s}")
    if polluters:
        print("⛔ 污染真实数据的套件（必须补隔离，否则损坏用户配置/数据库）：")
        for mod, files in polluters:
            print(f"  ⚠️ {mod}  改了: {', '.join(Path(f).name for f in files)}")

    # 退出码：有真失败 或 有污染 → 1
    return 1 if (fails or polluters) else 0


if __name__ == "__main__":
    sys.exit(main())
