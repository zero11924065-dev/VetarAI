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
"""0.4.29（P1）模型包下载器 + catalog 拉取（侧车首个下载器，无现存先例可复用）。

出站纪律（唯一漏斗，web_search.py:196-231 范本）：
  assert_guard(host) → 执行 → 成功 guard_report_success(host) / 失败 guard_report_failure(host)
  httpx 必须 trust_env=False + 显式 proxy=（connector.py:149-156：禁止拾取环境变量代理）。
  NetworkGuardError（被拒）不向上抛给端点以外的调用方——按"源不可用"回退下一源，
  全源失败汇总为 PackDownloadError（中文明细）。

下载语义：
  * 流式落盘：httpx client.stream + aiter_bytes 写 .partial/<path>.part；
  * 断点续传：.part 已存在则带 Range: bytes=<已有字节>-；
    服务器回 416 或无视 Range 返回 200 → 从头重下（truncate）；
  * 每文件完成后 SHA256 校验 → 不符换下一源重下；全部源失败 → PackDownloadError；
  * 校验通过 → os.replace 原子 rename 到最终位置（同目录同文件系统）；
  * 全部文件完成 → 写 manifest.json 副本 + 登记 registry + emit download_done；
  * asyncio.CancelledError 友好：保留 .partial 供续传，emit download_cancelled 后再抛出；
    其余失败同样保留现场，emit download_error 带中文明细；
  * 进度：写 chunk 节流 emit（每 PROGRESS_INTERVAL 秒至多一次 + 每文件起止各一次）。

file:// 源：本地文件/目录直接拷贝（开发/测试/导入本地包），不经过 guard
（guard 只管网络出站，本地磁盘读不是出站）。
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import unquote, urlparse

import httpx

from sidecar.model_packs import manifest as _manifest
from sidecar.model_packs import store as _store
from sidecar.network.guard import (
    NetworkGuardError, assert_guard, guard_report_failure, guard_report_success,
)

_log = logging.getLogger("sidecar.model_packs")

_CHUNK = 256 * 1024            # 流式写盘块大小
_PROGRESS_INTERVAL = 0.15      # 进度事件节流（秒）：SSE 不是日志，暴雨事件会拖垮前端
_CONNECT_TIMEOUT = 10.0        # 连接超时（防空转，与 connector CONNECT_TIMEOUT 同值）
_READ_TIMEOUT = 60.0           # 读超时：两次 socket 读之间的最大间隔（非全程上限，
                               # GB 级大文件照样能下完；60s 无字节到达才判死）

# 进度/生命周期事件的 action 名（resource 恒为 RESOURCE_MODEL_PACK，前端按 action 分流）
EVT_START = "download_start"
EVT_PROGRESS = "download_progress"
EVT_DONE = "download_done"
EVT_ERROR = "download_error"
EVT_CANCELLED = "download_cancelled"

# emit 回调类型：(action, pack_id, **fields) —— 默认实现走 app_events 总线，
# 测试可注入捕获器验证节流与生命周期语义。
EmitFn = Callable[..., None]


class PackDownloadError(RuntimeError):
    """模型包下载失败（全源回退用尽 / 校验不过 / IO 错误），message 为中文明细。"""


def _default_emit(action: str, pack_id: str, **fields: Any) -> None:
    """经全局资源变更总线推 SSE（app.py /api/events/stream）。
    总线失败绝不影响下载主流程（app_events.notify 自身已吞异常）。"""
    try:
        from sidecar.agent_engine import app_events as _ae
        _ae.notify(_ae.RESOURCE_MODEL_PACK, action, None, pack_id=pack_id, **fields)
    except Exception:
        pass


def _file_url_to_path(url: str) -> Path:
    """file:///abs/path → /abs/path（macOS/POSIX；百分号解码）。"""
    parsed = urlparse(url)
    # file://localhost/... 与 file:///... 等价；其余 host 形态不支持
    return Path(unquote(parsed.path))


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fp:
        for block in iter(lambda: fp.read(_CHUNK * 4), b""):
            h.update(block)
    return h.hexdigest()


async def _sha256_async(path: Path) -> str:
    # 大文件哈希放线程：GB 级权重全量读会阻塞事件循环数秒（SSE 心跳都会卡）
    return await asyncio.to_thread(_sha256_file, path)


def _client_kwargs(host: str) -> dict[str, Any]:
    """httpx 出站 kwargs：过 guard 漏斗 + trust_env=False + 显式 proxy。

    被拒（熔断/名单/未配代理）抛 NetworkGuardError，由调用方按源回退处理。
    """
    proxies = assert_guard(host)
    kwargs: dict[str, Any] = {
        "timeout": httpx.Timeout(_READ_TIMEOUT, connect=_CONNECT_TIMEOUT),
        "trust_env": False,  # 勿改：环境变量代理会绕过守卫的唯一漏斗契约（2026-08-28 教训）
        "follow_redirects": True,  # 模型托管（GitHub Releases/ModelScope）普遍 302 到 CDN
    }
    if proxies:
        kwargs["proxy"] = proxies["http"]
    return kwargs


class _Progress:
    """单包进度聚合与节流发射器。"""

    def __init__(self, pack_id: str, total_bytes: int, emit: EmitFn) -> None:
        self.pack_id = pack_id
        self.total_bytes = total_bytes
        self.emit = emit
        self.done_bytes = 0          # 已完成文件的累计字节（按清单声明值计）
        self.file_received = 0       # 当前文件已收字节（含续传基线）
        self.file_path = ""
        self.file_total = 0
        self._last = 0.0

    def start_file(self, path: str, total: int, baseline: int) -> None:
        self.file_path = path
        self.file_total = total
        self.file_received = baseline
        self._emit_now()

    def advance(self, n: int) -> None:
        self.file_received += n
        now = time.monotonic()
        if now - self._last >= _PROGRESS_INTERVAL:
            self._emit_now()

    def finish_file(self) -> None:
        self.done_bytes += self.file_total
        self._emit_now()

    def _emit_now(self) -> None:
        self._last = time.monotonic()
        self.emit(EVT_PROGRESS, self.pack_id,
                  file=self.file_path,
                  file_received=self.file_received,
                  file_total=self.file_total,
                  received_bytes=self.done_bytes + self.file_received,
                  total_bytes=self.total_bytes)


async def _download_http_file(url: str, part: Path, expected_size: int,
                              progress: _Progress) -> None:
    """从单个 http(s) 源流式下载到 part（支持续传）。失败抛异常（调用方回退下一源）。

    Range 语义（三态，实测口径）：
      * 206 → 服务器支持续传，追加写；
      * 200（我们带了 Range）→ 服务器无视 Range，从头重下（覆盖写）；
      * 416 → 本地 .part 已大于等于远端全长（远端文件多半变了）→ 删 .part 从头重下
        （只重试一次：重试仍 416 说明远端与清单严重不符，按失败回退下一源）。
    """
    host = urlparse(url).hostname or ""
    kwargs = _client_kwargs(host)  # NetworkGuardError 在此抛出（源被拒 → 回退）
    retried_416 = False
    while True:
        existing = part.stat().st_size if part.exists() else 0
        headers: dict[str, str] = {}
        if existing > 0:
            headers["Range"] = f"bytes={existing}-"
        async with httpx.AsyncClient(**kwargs) as client:
            async with client.stream("GET", url, headers=headers) as r:
                if r.status_code == 416 and existing > 0 and not retried_416:
                    # 本地续传点越界：删半截从头再来
                    _log.warning("模型包分片续传越界（416），删 .part 重下: %s", part)
                    part.unlink(missing_ok=True)
                    retried_416 = True
                    continue  # 出 stream/client 上下文后重进循环，不带 Range 重下
                if r.status_code not in (200, 206):
                    guard_report_failure(host)
                    raise PackDownloadError(f"{host}: HTTP {r.status_code}")
                if r.status_code == 200:
                    # 服务器无视 Range（或首次下载）：覆盖写，进度基线归零
                    mode, baseline = "wb", 0
                else:  # 206
                    mode, baseline = "ab", existing
                if baseline != progress.file_received:
                    # 基线可能因 416/200 重下而重置，校准进度计数（防进度条>100%）
                    progress.file_received = baseline
                part.parent.mkdir(parents=True, exist_ok=True)
                with open(part, mode) as fp:
                    async for chunk in r.aiter_bytes(_CHUNK):
                        # 同步写 256KB 块耗时微秒级，不另行 to_thread（已知代价：
                        # 极慢磁盘上事件循环会有微秒级抖动，换来取消点语义简单可靠）
                        fp.write(chunk)
                        progress.advance(len(chunk))
        break
    # 完整性预检：字节数对不上不必浪费哈希（分块丢失/提前断流的常见形态）
    got = part.stat().st_size
    if expected_size > 0 and got != expected_size:
        raise PackDownloadError(
            f"字节数不符：{part.name} 收到 {got}，应为 {expected_size}")


def _copy_local_file(src: Path, part: Path, progress: _Progress) -> None:
    """file:// 源：本地分块拷贝（线程内执行，进度回调线程安全——emit 最终走
    app_events.notify，其内部本就是跨 loop 安全投递）。"""
    part.parent.mkdir(parents=True, exist_ok=True)
    with open(src, "rb") as fin, open(part, "wb") as fout:
        for block in iter(lambda: fin.read(_CHUNK), b""):
            fout.write(block)
            progress.advance(len(block))


async def _fetch_one_file(file_entry: dict[str, Any], dest: Path, part: Path,
                          progress: _Progress) -> None:
    """按 sources 顺序回退下载单个文件，SHA256 校验通过后原子 rename 到位。"""
    expected_sha = str(file_entry["sha256"]).lower()
    expected_size = int(file_entry["size_bytes"])
    # 续传基线：.part 已有字节从断点继续（进度条不应从 0 起跳再猛蹿）
    baseline = part.stat().st_size if part.exists() else 0
    progress.start_file(file_entry["path"], expected_size, baseline)

    # 快速路径：最终文件已存在且哈希正确（上次装到一半中断在 rename 之后）→ 直接复用
    if dest.exists() and await _sha256_async(dest) == expected_sha:
        progress.file_received = expected_size
        progress.finish_file()
        return

    # 续传快捷路径：.part 恰好完整（中断发生在 rename 之前）→ 只补校验+rename
    if part.exists() and part.stat().st_size == expected_size:
        if await _sha256_async(part) == expected_sha:
            dest.parent.mkdir(parents=True, exist_ok=True)
            os.replace(str(part), str(dest))
            progress.file_received = expected_size
            progress.finish_file()
            return
        part.unlink()  # 尺寸对但哈希错：内容不可信，重下
    elif part.exists() and part.stat().st_size > expected_size:
        part.unlink()  # 半截比声明还长（远端文件变了）→ 重下，Range 必被 416 拒

    errors: list[str] = []
    for src in file_entry.get("sources", []):
        try:
            if str(src).startswith("file://"):
                local = _file_url_to_path(str(src))
                if not local.is_file():
                    raise PackDownloadError(f"本地源不存在: {local}")
                await asyncio.to_thread(_copy_local_file, local, part, progress)
            else:
                await _download_http_file(str(src), part, expected_size, progress)
            got_sha = await _sha256_async(part)
            if got_sha != expected_sha:
                # 哈希不符不记 guard 失败——这不是网络故障，是源内容不可信
                errors.append(f"{src}: SHA256 不符（{got_sha[:12]}… ≠ {expected_sha[:12]}…）")
                part.unlink(missing_ok=True)
                progress.file_received = 0
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            os.replace(str(part), str(dest))  # 同目录原子替换
            host = urlparse(str(src)).hostname or ""
            if not str(src).startswith("file://"):
                guard_report_success(host)
            progress.file_received = expected_size
            progress.finish_file()
            return
        except PackDownloadError as e:
            errors.append(str(e))
            continue
        except NetworkGuardError as e:
            errors.append(f"{e.host}: {e.message}")
            continue
        except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
            host = urlparse(str(src)).hostname or ""
            guard_report_failure(host)
            errors.append(f"{host}: 连接失败/超时（{type(e).__name__}）")
            continue
        except asyncio.CancelledError:
            raise  # 取消是主流程语义，不得被源回退吞掉
        except Exception as e:
            errors.append(f"{src}: {type(e).__name__}: {e}")
            continue
    raise PackDownloadError(
        f"文件 {file_entry['path']} 全部源失败 —— " + "；".join(errors[:3]))


async def download_pack(pack: dict[str, Any], emit: EmitFn | None = None) -> dict[str, Any]:
    """下载并安装一个模型包（core coroutine；取消/失败均保留 .partial 现场）。

    成功返回注册表条目字段；失败抛 PackDownloadError；取消抛 CancelledError。
    """
    emit = emit or _default_emit
    pack_id = str(pack["pack_id"])
    files = pack.get("files", [])
    total = int(pack.get("size_bytes") or sum(f["size_bytes"] for f in files))
    dest_dir = _store.pack_dir(pack_id)
    part_dir = _store.partial_dir(pack_id)
    dest_dir.mkdir(parents=True, exist_ok=True)
    part_dir.mkdir(parents=True, exist_ok=True)

    progress = _Progress(pack_id, total, emit)
    emit(EVT_START, pack_id, total_bytes=total, file_count=len(files),
         name=str(pack.get("name") or pack_id), version=str(pack.get("version") or ""))
    try:
        for f in files:
            await _fetch_one_file(f, dest_dir / f["path"],
                                  part_dir / (f["path"] + ".part"), progress)
        # manifest.json 副本（原子写，勿覆盖包自带同名文件——manifest 校验已拒绝该保留名）
        man_tmp = part_dir / "manifest.json.tmp"
        man_tmp.write_text(json.dumps(pack, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(str(man_tmp), str(dest_dir / "manifest.json"))
        _store.register_pack(pack_id, pack)
        try:
            if part_dir.exists() and not any(part_dir.iterdir()):
                part_dir.rmdir()  # 空暂存目录顺手清掉；有残留（别的中断文件）则保留
        except OSError:
            pass
        emit(EVT_DONE, pack_id, total_bytes=total)
        return _store.get_entry(pack_id) or {}
    except asyncio.CancelledError:
        # 取消友好：.partial 原地保留，下次安装从断点续传
        emit(EVT_CANCELLED, pack_id,
             received_bytes=progress.done_bytes + progress.file_received,
             total_bytes=total)
        raise
    except Exception as e:
        emit(EVT_ERROR, pack_id, error=str(e))
        raise


class ModelPackDownloadManager:
    """进行中的下载任务注册表（每 pack_id 至多一个任务）。

    进程级内存态（侧车重启即清空）——重启后 .partial 仍在磁盘，
    用户重新点安装即续传，无需任务态持久化。
    """

    def __init__(self) -> None:
        self._tasks: dict[str, asyncio.Task] = {}

    def active_ids(self) -> list[str]:
        return [pid for pid, t in self._tasks.items() if not t.done()]

    def is_active(self, pack_id: str) -> bool:
        t = self._tasks.get(pack_id)
        return t is not None and not t.done()

    def start(self, pack_id: str, pack: dict[str, Any]) -> asyncio.Task:
        """在当前事件循环上起后台任务。重复启动抛 PackDownloadError（端点层转 409）。"""
        if self.is_active(pack_id):
            raise PackDownloadError(f"模型包 {pack_id} 正在下载中")
        task = asyncio.create_task(self._run(pack_id, pack),
                                   name=f"model-pack-dl-{pack_id}")
        self._tasks[pack_id] = task
        return task

    async def cancel(self, pack_id: str) -> bool:
        """取消进行中的下载并等它收尾（.partial 保留）。无进行中任务返回 False。"""
        task = self._tasks.get(pack_id)
        if task is None or task.done():
            return False
        task.cancel()
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=10.0)
        except (asyncio.CancelledError, asyncio.TimeoutError, Exception):
            # CancelledError=任务已响应取消；Timeout=任务卡在非取消点（如线程拷贝），
            # 仍返回 True——取消信号已送达，磁盘现场由 .partial 语义兜底
            pass
        return True

    async def _run(self, pack_id: str, pack: dict[str, Any]) -> None:
        try:
            await download_pack(pack)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            _log.warning("模型包下载失败 %s: %s", pack_id, e)
        finally:
            self._tasks.pop(pack_id, None)


# 模块级单例（端点与测试共用；任务态本就进程级，多实例反而割裂）
pack_download_manager = ModelPackDownloadManager()


async def fetch_catalog(url: str) -> tuple[list[dict[str, Any]] | None, str | None]:
    """拉取并校验一个 catalog 源。返回 (packs, error)；成功 error 为 None。

    * file:// 源：直接读本地 JSON（目录则取其下 catalog.json），相对 sources
      一并改写为绝对 file://（本地包导入形态：catalog.json 与权重同目录）；
    * http(s):// 源：过 guard 漏斗（被拒/失败计入熔断语义同 web_search）；
    * 单源失败由端点层汇总标注，不拖死整列。
    """
    url = str(url or "").strip()
    if not url:
        return None, "空 catalog 源地址"
    raw: Any = None
    if url.startswith("file://"):
        path = _file_url_to_path(url)
        try:
            if path.is_dir():
                path = path / "catalog.json"
            raw = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None, f"本地 catalog 不存在: {path}"
        except json.JSONDecodeError as e:
            return None, f"本地 catalog 不是合法 JSON: {e}"
        except OSError as e:
            return None, f"读取本地 catalog 失败: {e}"
        # 相对 sources → 绝对 file://（仅 file 型 catalog 支持相对写法）
        base = path.parent
        for p in (raw.get("packs") or []) if isinstance(raw, dict) else []:
            for f in (p.get("files") or []) if isinstance(p, dict) else []:
                if isinstance(f, dict) and isinstance(f.get("sources"), list):
                    f["sources"] = [
                        s if isinstance(s, str) and s.startswith(("http://", "https://", "file://"))
                        else (base / str(s)).as_uri() if isinstance(s, str) else s
                        for s in f["sources"]
                    ]
    else:
        host = urlparse(url).hostname or ""
        try:
            kwargs = _client_kwargs(host)
        except NetworkGuardError as e:
            return None, e.message
        try:
            async with httpx.AsyncClient(**kwargs) as client:
                r = await client.get(url)
            if r.status_code != 200:
                guard_report_failure(host)
                return None, f"{host}: HTTP {r.status_code}"
            raw = r.json()
            guard_report_success(host)
        except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
            guard_report_failure(host)
            return None, f"{host}: 连接失败/超时（{type(e).__name__}）"
        except json.JSONDecodeError as e:
            return None, f"{host}: catalog 不是合法 JSON: {e}"
    errors = _manifest.validate_catalog(raw)
    if errors:
        return None, "catalog 校验失败: " + "；".join(errors[:3])
    return list(raw.get("packs") or []), None
