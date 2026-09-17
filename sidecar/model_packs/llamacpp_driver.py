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
"""0.4.29（P2）llama.cpp 驱动：llama-server 子进程生命周期管理（计划 D1 方案①新 backend）。

职责边界：本模块只管"进程"（spawn/健康探测/停止/换装），不管"协议"
（OpenAI 兼容 SSE 解析在 mp_connector → openai_compat，一字不动）。

生命周期语义（Ollama 换装同款）：
  * 同一时刻只跑一个对话包——ensure_server(另一个包) = 停旧启新；
  * 重复启动同包直接复用（不起第二个进程）；
  * 停止＝terminate 带 ≤20s 宽限 → 未死再 kill，且动手前先 poll() 查进程在跑
    （agent_engine/loop.py:153-177 safe_unload_model 双防护范式；
     0.4.7「为卸载而加载」事故教训：对已死/不在的进程做动作等于白触发一次代价）；
  * 子进程 stdout/stderr 导流进日志目录（logging_setup 惯例：应用目录 logs/ 优先，
    打包回退 <data_root>/logs/）——"启动失败"的排查完全依赖这份日志。

禁用/卸载语义（0.4.29 缺陷修复 A/B，与 app.py 卸载/禁用端点对齐）：
  禁用或卸载一个正在服务的 chat 包，其 llama-server 子进程随状态失效即被回收
  （端点侧主动停；本驱动 ensure_server 的注册表门禁是兜底——热路径短路前必查，
  发现失效先停进程再报错），对该包的后续对话一律 LlamaServerError 中文明细。
  门禁开销：注册表是小 JSON 整读（asr_driver.resolve_asr_pack 每次转写同款口径），
  相对一次推理调用可忽略。

二进制解析链（勿改优先级；embedder.py:_bundled_model_dir 范式）：
  env VETARAI_LLAMA_SERVER > data_root()/drivers/llama-server
  > 冻结包内 Contents/Resources/drivers/llama-server（parents[2] 定位）

出站纪律：llama-server 只听 127.0.0.1 回环；健康探测 httpx 必须 trust_env=False，
子进程环境剥离 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY（plugin_loader/loader.py:_egress_env
先例）——本机回环不需要代理，继承代理变量只会绕过守卫的"唯一漏斗"契约。
"""
from __future__ import annotations

import asyncio
import atexit
import logging
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import httpx

from sidecar.model_packs import store as _store

_log = logging.getLogger("sidecar.model_packs.llamacpp")

ENV_LLAMA_SERVER = "VETARAI_LLAMA_SERVER"

# terminate 宽限（秒）：先 SIGTERM 礼让退出，超时再 SIGKILL。
# 具名常量化以便测试收窄等待（杀进程路径不值得每次真等 20s）。
TERMINATE_GRACE_S = 20.0

# 子进程环境剥离清单（_egress_env 先例同款；本地复制一份避免为 6 个字符串
# 引入 plugin_loader 的模块级副作用——其 import 即 mkdir PLUGINS_ROOT）
_PROXY_ENV_KEYS = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                   "http_proxy", "https_proxy", "all_proxy")

_DEFAULT_BOOT_TIMEOUT_S = 600.0  # 兜底；实际以 config model_pack_boot_timeout_s 为准

# 活动服务状态（进程级单例：{pack_id, proc, port, log_fp}）。
# 同一时刻至多一个对话包在跑——Ollama 换装语义，见模块 docstring。
_STATE: dict[str, Any] = {"pack_id": None, "proc": None, "port": None, "log_fp": None}

# 换装/停止串行锁：按事件循环惰性创建（测试会 asyncio.run 多次，
# 锁绑定旧循环后再 acquire 会炸，故按 loop 分桶）
_LOCKS: dict[int, asyncio.Lock] = {}


def _lock() -> asyncio.Lock:
    loop = asyncio.get_running_loop()
    lk = _LOCKS.get(id(loop))
    if lk is None:
        lk = asyncio.Lock()
        _LOCKS[id(loop)] = lk
    return lk


class LlamaServerError(RuntimeError):
    """llama-server 不可用（二进制缺失 / 包缺 GGUF / 启动失败 / 健康探测超时）。
    message 一律中文明细，connector 层转 OllamaAPIError(400) 直达用户。"""


# ────────────────────────── 解析（二进制 / GGUF / 端口 / 超时） ──────────────────────────

def resolve_server_binary() -> Path:
    """llama-server 二进制解析链（优先级见模块 docstring）。

    找不到 → LlamaServerError（中文，指引去模型包面板/设置）。
    env 指向非法路径时继续向后回退（embedder._bundled_model_dir 同款：
    env 是最高优先而不是唯一候选，配错不至于整体判死）。
    """
    candidates: list[Path] = []
    raw = os.environ.get(ENV_LLAMA_SERVER, "").strip()
    if raw:
        candidates.append(Path(raw).expanduser())
    try:
        from sidecar.config import data_root
        candidates.append(Path(data_root()) / "drivers" / "llama-server")
    except Exception:
        pass
    # 冻结包内：侧车可执行文件 Contents/Resources/sidecar/vetarai-sidecar/vetarai-sidecar
    # → parents[2] = Contents/Resources；驱动随安装包分发在 Resources/drivers/
    if getattr(sys, "frozen", False):
        try:
            exe = Path(sys.executable).resolve()
            candidates.append(exe.parents[2] / "drivers" / "llama-server")
        except Exception:
            pass
    for c in candidates:
        try:
            if c.is_file() and os.access(str(c), os.X_OK):
                return c
        except OSError:
            continue
    tried = "、".join(str(c) for c in candidates) or "（无候选路径）"
    raise LlamaServerError(
        "未找到 llama-server 二进制（模型包对话后端的本体）。"
        "请到「模型包」面板查看安装指引，或由设置/部署方将 llama-server 放入 "
        "数据目录 drivers/ 下（亦可用环境变量 VETARAI_LLAMA_SERVER 指定路径）。"
        f"已查找: {tried}")


def _enabled_entry(pack_id: str) -> dict[str, Any]:
    """注册表状态门禁：包须存在且启用中，否则 LlamaServerError（中文明细）。

    ensure_server 热路径短路前必过（0.4.29 缺陷修复 A）：包被禁用/卸载后，
    正在服务它的进程不得继续供血——只查进程存活不看注册表，禁用/卸载就会
    形同虚设（实测禁用后对话仍成功）。开销见模块 docstring「禁用/卸载语义」。
    """
    entry = _store.get_entry(pack_id)
    if entry is None:
        raise LlamaServerError(
            f"模型包 {pack_id!r} 未安装。请到「模型包」面板安装后再对话。")
    if entry.get("status") != "installed":
        raise LlamaServerError(
            f"模型包 {pack_id!r} 已禁用。请到「模型包」面板启用后再对话。")
    return entry


def _gguf_path(pack_id: str) -> Path:
    """从注册表条目取 GGUF 权重绝对路径（files[] 里首个以 .gguf 结尾的条目）。"""
    entry = _enabled_entry(pack_id)
    gguf_rel = ""
    for f in entry.get("files", []):
        p = str(f.get("path", ""))
        if p.lower().endswith(".gguf"):
            gguf_rel = p
            break
    if not gguf_rel:
        raise LlamaServerError(
            f"模型包 {pack_id!r} 的清单中没有 .gguf 权重文件，llama.cpp 驱动无法加载。"
            "请检查该包的 catalog 清单（files[].path 须含 .gguf 条目）。")
    path = _store.pack_dir(pack_id) / gguf_rel
    if not path.is_file():
        raise LlamaServerError(
            f"模型包 {pack_id!r} 的权重文件缺失: {gguf_rel}"
            "（安装不完整或文件被手动删除），请到「模型包」面板重新安装。")
    return path


def _context_length_of(pack_id: str) -> int | None:
    """manifest 可选键 context_length（正整数才采纳；非法值安装入口已拦，此处仅防御）。"""
    cl = _store.read_manifest(pack_id).get("context_length")
    if isinstance(cl, int) and not isinstance(cl, bool) and cl > 0:
        return cl
    return None


def _free_port() -> int:
    """探测空闲回环端口（bind 0 即得即放）。bind 与 spawn 之间存在理论竞态
    （端口被第三者抢走）——健康探测会把这种情况识别为启动失败，用户重试即可，可接受。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _boot_timeout() -> float:
    """启动健康探测超时：config model_pack_boot_timeout_s（默认 600s，大模型启动慢）。"""
    try:
        from sidecar.config import get_config
        v = float(get_config().get("model_pack_boot_timeout_s") or _DEFAULT_BOOT_TIMEOUT_S)
    except Exception:
        return _DEFAULT_BOOT_TIMEOUT_S
    return max(10.0, min(v, 7200.0))


def _subprocess_env() -> dict[str, str]:
    """子进程环境：剥离代理变量（plugin_loader/loader.py:_egress_env 先例）。
    llama-server 只听回环，本机回环不需要代理；继承 HTTP_PROXY 等会让它自己的
    偶发出站（如拉远端聊天模板）绕过守卫漏斗。"""
    return {k: v for k, v in os.environ.items() if k not in _PROXY_ENV_KEYS}


def _server_log_path(pack_id: str) -> Path:
    """子进程 stdout/stderr 落点（logging_setup 惯例：logs/ 目录，与 app.log 同处）。"""
    from sidecar.logging_setup import resolve_log_dir
    return resolve_log_dir() / f"llama-server-{pack_id}.log"


# ────────────────────────── spawn / 健康探测 ──────────────────────────

def _spawn(pack_id: str, binary: Path, gguf: Path, port: int,
           context_length: int | None) -> tuple[subprocess.Popen, Any, Path]:
    """拉起 llama-server。返回 (proc, log_fp, log_path)；失败时关闭日志句柄再抛。"""
    argv = [str(binary), "--model", str(gguf),
            "--port", str(port), "--host", "127.0.0.1"]
    if context_length:
        argv += ["-c", str(context_length)]
    log_path = _server_log_path(pack_id)
    # append 模式：换装重启不抹掉上一次日志（排查"上次为什么挂"要它）；
    # 已知代价：长期运行日志会涨（llama-server 自身按请求逐行写，量级可控）
    log_fp = open(log_path, "ab", buffering=0)
    try:
        proc = subprocess.Popen(
            argv, stdout=log_fp, stderr=subprocess.STDOUT, env=_subprocess_env())
    except Exception:
        log_fp.close()
        raise
    _log.info("llama-server 已拉起: pack=%s pid=%s port=%s argv=%s log=%s",
              pack_id, proc.pid, port, argv, log_path)
    return proc, log_fp, log_path


def _log_tail(path: Path, limit: int = 2000) -> str:
    """日志尾巴（错误信息用）：llama-server 拒启动的原因（坏 GGUF/参数错）只写在这里。"""
    try:
        data = path.read_bytes()[-limit:]
        return data.decode("utf-8", errors="replace").strip() or "（日志为空）"
    except Exception as e:
        return f"（读取日志失败: {e}）"


async def _wait_ready(proc: subprocess.Popen, port: int, log_path: Path,
                      timeout: float) -> None:
    """健康探测循环：GET /v1/models 直到 200。

    两种失败都带日志尾巴（中文）：
      ① 子进程早死（poll() 非 None）——坏 GGUF/参数错是主因；
      ② 超时（config model_pack_boot_timeout_s，默认 600s）——超大模型加载慢可上调。
    """
    deadline = time.monotonic() + timeout
    url = f"http://127.0.0.1:{port}/v1/models"
    # trust_env=False 勿改：回环探测若拾取环境变量代理，会被导到未监听端口而永远超时
    async with httpx.AsyncClient(trust_env=False,
                                 timeout=httpx.Timeout(2.0, connect=2.0)) as client:
        while True:
            if proc.poll() is not None:
                raise LlamaServerError(
                    f"llama-server 启动后立即退出（exit={proc.returncode}）。"
                    f"日志尾巴：{_log_tail(log_path)}")
            try:
                r = await client.get(url)
                if r.status_code == 200:
                    return
            except httpx.HTTPError:
                pass  # 连接被拒 = 还没起好，继续等
            if time.monotonic() >= deadline:
                raise LlamaServerError(
                    f"llama-server 启动超时（{timeout:.0f}s 内 /v1/models 未就绪）。"
                    f"日志尾巴：{_log_tail(log_path)}")
            await asyncio.sleep(0.5)


# ────────────────────────── 停止（双防护） ──────────────────────────

async def _stop_locked() -> bool:
    """停止活动子进程并清状态（调用方须持锁）。

    返回 True=本次活动进程已处理（终止或本就已死）；False=本来就没有活动进程。
    """
    proc: subprocess.Popen | None = _STATE["proc"]
    log_fp = _STATE.get("log_fp")
    _STATE.update({"pack_id": None, "proc": None, "port": None, "log_fp": None})
    if log_fp is not None:
        try:
            log_fp.close()
        except Exception:
            pass
    if proc is None:
        return False
    # 防护①：先查进程在跑再动手（0.4.7 教训：对已死进程做动作是白付代价）
    if proc.poll() is not None:
        _log.info("llama-server 子进程已自行退出（exit=%s），仅清理状态", proc.returncode)
        return True
    # 防护②：terminate 带 ≤20s 宽限，未死再 kill；wait 放线程，不阻塞事件循环
    try:
        proc.terminate()
    except Exception:
        pass
    try:
        await asyncio.to_thread(proc.wait, TERMINATE_GRACE_S)
    except Exception:
        # 宽限内未退出（Popen.wait(timeout) 抛 TimeoutExpired）→ 补 SIGKILL
        try:
            proc.kill()
        except Exception:
            pass
        try:
            await asyncio.to_thread(proc.wait, 5.0)
        except Exception:
            pass
    _log.info("llama-server 已停止: pid=%s", proc.pid)
    return True


# ────────────────────────── 对外 API ──────────────────────────

def active_pack() -> str | None:
    """当前活动对话包 id（子进程活着才算数；只读查询，不做清理副作用）。"""
    proc = _STATE["proc"]
    if proc is None or proc.poll() is not None:
        return None
    return _STATE["pack_id"]


def active_base_url() -> str | None:
    """活动服务的 OpenAI 兼容 base_url（含 /v1）；无活动服务返回 None。"""
    if active_pack() is None:
        return None
    return f"http://127.0.0.1:{_STATE['port']}/v1"


async def ensure_server(pack_id: str) -> str:
    """确保 pack_id 的 llama-server 在跑，返回 base_url（含 /v1）。

    * 注册表门禁先行：包被禁用/卸载 → LlamaServerError 中文明细；若失效包正是
      当前活动服务对象，先回收它的子进程再抛（0.4.29 缺陷修复 A，语义见模块
      docstring「禁用/卸载语义」）；
    * 同包已在跑 → 直接复用（不起第二个进程）；
    * 异包在跑 → 换装：停旧启新（Ollama 换装语义）；
    * 启动失败 → 回收子进程现场再抛 LlamaServerError（不留半截状态
      让下次 ensure 误判"已在跑"）。
    """
    async with _lock():
        # 门禁必须在热路径短路之前：否则"同包且进程存活"会在禁用/卸载后照样
        # 直接返回 base_url，禁用/卸载形同虚设（实测缺陷 A：禁用后对话仍 200）。
        # 失效包正在服务时先停进程再报错——文件已删/已禁用的进程继续 mmap 权重
        # 服务，等于禁用/卸载没生效，还白占数 GB 内存直到侧车退出（atexit）。
        try:
            _enabled_entry(pack_id)
        except LlamaServerError:
            if _STATE["pack_id"] == pack_id:
                await _stop_locked()
            raise
        proc: subprocess.Popen | None = _STATE["proc"]
        if _STATE["pack_id"] == pack_id and proc is not None and proc.poll() is None:
            return f"http://127.0.0.1:{_STATE['port']}/v1"
        if proc is not None:
            # 换装语义（Ollama 同款）：同一时刻只跑一个对话包——先停旧、再启新。
            await _stop_locked()
        binary = resolve_server_binary()
        gguf = _gguf_path(pack_id)
        context_length = _context_length_of(pack_id)
        port = _free_port()
        proc, log_fp, log_path = _spawn(pack_id, binary, gguf, port, context_length)
        _STATE.update({"pack_id": pack_id, "proc": proc, "port": port, "log_fp": log_fp})
        try:
            await _wait_ready(proc, port, log_path, _boot_timeout())
        except Exception:
            await _stop_locked()  # 启动失败回收现场
            raise
        return f"http://127.0.0.1:{port}/v1"


async def stop_server(pack_id: str | None = None) -> bool:
    """停止活动 llama-server。

    pack_id 给定时只停匹配的包（不匹配 = 不动并返回 False——调用方拿的多半是
    过期名字，乱停会把正在跑的对话掐掉）；None = 无条件停当前活动包。
    返回 True=调用后无活动服务（含"本就已死"的清理）；False=未匹配/本无活动。
    """
    async with _lock():
        if _STATE["proc"] is None:
            return False
        if pack_id is not None and _STATE["pack_id"] != pack_id:
            return False
        return await _stop_locked()


def _atexit_cleanup() -> None:
    """进程退出兜底：侧车退出不会自动带走子进程（macOS 无进程组随父死语义），
    不挂这个钩子，应用退出后 llama-server 会孤儿常驻、白白占着几 GB 内存。
    退出路径从简：terminate 只等 5s（应用退出不该被拖 20s），未死再 kill。"""
    proc = _STATE.get("proc")
    log_fp = _STATE.get("log_fp")
    if log_fp is not None:
        try:
            log_fp.close()
        except Exception:
            pass
    if proc is None:
        return
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
    except Exception:
        pass


atexit.register(_atexit_cleanup)
