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
"""0.4.29（P1）模型包后端套件：manifest 校验 / 注册表 / 下载器（本地 HTTP+Range）/ 端点层。

隔离：顶部先钉 VETARAI_MODEL_PACKS_DIR + VETARAI_DATA_ROOT 到临时目录，
再桩 config.store.get_config_path——直接跑（python test_model_packs.py）
也不碰真实 ~/.subagent；runner 跑时其 VETARAI_DATA_ROOT 生效（setdefault 不覆盖）。

本地 HTTP 小服务器（127.0.0.1 随机端口，guard 对 localhost 直连放行）支持：
Range 续传 / 无视 Range 回 200 / 416 / 404 / 慢速滴灌（取消测试用）。
侧车此前无本地 server 测试基建，本文件的 _start_server 是首份（可复用）。

变异测试机制（MUTATE=1|2|3 python test_model_packs.py）：
⛔ 变异模式下必须出现 FAIL；0 FAIL = 断言空转，需加强（不是"通过"）。
| 变异 | 撤掉的修复 | 应失败的断言 |
|---|---|---|
| 1 | manifest 放行 ".." 路径段 | A5a/A5b（路径穿越拒绝） |
| 2 | downloader 跳过 SHA256 校验 | C3a/C3b（坏哈希拒收） |
| 3 | downloader 不带 Range 续传头 | C2b（断点续传 Range 断言） |
"""
import asyncio
import hashlib
import json
import os
import re
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# ── 隔离（必须先于一切 sidecar 导入）──
TMP = Path(tempfile.mkdtemp(prefix="mp_test_"))
os.environ["VETARAI_MODEL_PACKS_DIR"] = str(TMP / "packs")
os.environ.setdefault("VETARAI_DATA_ROOT", str(TMP / "data"))

import sidecar.config.store as _cs  # noqa: E402
_cs.get_config_path = lambda: TMP / "config.json"
_cs._MEM = {}

import sidecar.model_packs.manifest as mpm  # noqa: E402
import sidecar.model_packs.store as mps  # noqa: E402
import sidecar.model_packs.downloader as mpd  # noqa: E402

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


# ══════════ 变异机制（test_loop.py 同款：内存备份 + finally 还原 + reload）══════════
MUTATE = int(os.environ.get("MUTATE", "0"))
_BACKUP: dict[str, str] = {}


def _apply_mutation() -> None:
    if not MUTATE:
        return
    if MUTATE == 1:
        s = Path(mpm.__file__).read_text(encoding="utf-8")
        _BACKUP["manifest"] = s
        patched = s.replace('if seg in (".", ".."):', 'if seg in (".",):')
        assert patched != s, "变异 1 未命中 manifest.py 源码，测试无效"
        Path(mpm.__file__).write_text(patched, encoding="utf-8")
        import importlib
        importlib.reload(mpm)
    elif MUTATE == 2:
        s = Path(mpd.__file__).read_text(encoding="utf-8")
        _BACKUP["downloader"] = s
        patched = s.replace("if got_sha != expected_sha:", "if False and got_sha != expected_sha:")
        assert patched != s, "变异 2 未命中 downloader.py 源码，测试无效"
        Path(mpd.__file__).write_text(patched, encoding="utf-8")
        import importlib
        importlib.reload(mpd)
    elif MUTATE == 3:
        s = Path(mpd.__file__).read_text(encoding="utf-8")
        _BACKUP["downloader"] = s
        patched = s.replace('headers["Range"] = f"bytes={existing}-"',
                            'headers["X-No-Range"] = "1"  # 变异3：不带 Range')
        assert patched != s, "变异 3 未命中 downloader.py 源码，测试无效"
        Path(mpd.__file__).write_text(patched, encoding="utf-8")
        import importlib
        importlib.reload(mpd)
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3）")


def _restore() -> None:
    """还原被变异的源文件（必须在 finally：用例 sys.exit 会抛 SystemExit）。"""
    if not MUTATE or not _BACKUP:
        return
    import importlib
    try:
        if "manifest" in _BACKUP:
            Path(mpm.__file__).write_text(_BACKUP["manifest"], encoding="utf-8")
        if "downloader" in _BACKUP:
            Path(mpd.__file__).write_text(_BACKUP["downloader"], encoding="utf-8")
    finally:
        _BACKUP.clear()
        if MUTATE == 1:
            importlib.reload(mpm)
        if MUTATE in (2, 3):
            importlib.reload(mpd)


# ══════════ 测试数据构造 ══════════

def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _mk_pack(pack_id: str, files: list[tuple[str, bytes]],
             source_for=None, **over) -> dict:
    """files: [(relpath, bytes)]；source_for(data, relpath) -> [urls]。"""
    entries = []
    for rel, data in files:
        entries.append({"path": rel, "size_bytes": len(data),
                        "sha256": _sha(data), "sources": source_for(data, rel)})
    pack = {
        "pack_id": pack_id, "name": f"测试包 {pack_id}", "task": "chat",
        "format": "gguf", "driver": "llamacpp", "version": "1.0.0",
        "description": "测试用", "size_bytes": sum(len(d) for _, d in files),
        "min_app_version": "", "homepage": "", "license": "MIT",
        "files": entries,
    }
    pack.update(over)
    return pack


# ══════════ 本地 HTTP 小服务器（Range 能力可配）══════════

def _start_server(routes: dict) -> ThreadingHTTPServer:
    """routes: path -> {"data": bytes, "status": int, "range_ok": bool,
    "reject_range_416": bool, "trickle": 秒/块, "trickle_chunk": int}"""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):  # 静默
            pass

        def do_GET(self):
            srv = self.server
            path = self.path.split("?")[0]
            rng = self.headers.get("Range")
            srv.requests.append((path, rng))
            rule = routes.get(path)
            if rule is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            data = rule["data"]
            if rule.get("status", 200) != 200:
                self.send_response(rule["status"])
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if rng and rule.get("reject_range_416"):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(data)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body, code = data, 200
            if rng and rule.get("range_ok", True):
                m = re.match(r"bytes=(\d+)-", rng or "")
                if m:
                    start = int(m.group(1))
                    if start >= len(data):
                        self.send_response(416)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    body, code = data[start:], 206
            self.send_response(code)
            if code == 206:
                self.send_header("Content-Range", f"bytes {start}-{len(data)-1}/{len(data)}")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            trickle = rule.get("trickle")
            if trickle:
                step = rule.get("trickle_chunk", 8192)
                for i in range(0, len(body), step):
                    try:
                        self.wfile.write(body[i:i + step])
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        return  # 客户端取消/断线：静默退出
                    time.sleep(trickle)
                return
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    srv.requests = []  # (path, Range头) 请求日志，供续传断言
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class _EvtLog:
    """下载事件捕获器（替代 _default_emit 注入）。"""

    def __init__(self):
        self.events: list[tuple[str, str, dict]] = []

    def __call__(self, action, pack_id, **fields):
        self.events.append((action, pack_id, fields))

    def actions(self):
        return [a for a, _, _ in self.events]


# ══════════ A. manifest 校验 ══════════

def test_manifest():
    good = _mk_pack("asr-sensevoice", [("model.onnx", b"x" * 10), ("tokens.txt", b"t" * 5)],
                    source_for=lambda d, r: ["https://example.cn/m"])
    errs = mpm.validate_pack(good)
    check("A1 合法 pack（多文件）通过", errs == [], str(errs))
    errs = mpm.validate_catalog({"version": 1, "packs": [good]})
    check("A2 合法 catalog 通过", errs == [], str(errs))

    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"])
    del bad["files"]
    errs = mpm.validate_pack(bad)
    check("A3 缺 files → 明确错误", any("files" in e for e in errs), str(errs))

    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"])
    bad["files"][0]["sha256"] = "abc123"
    errs = mpm.validate_pack(bad)
    check("A4 坏 sha256（非64位hex）→ 明确错误", any("sha256" in e and "64" in e for e in errs), str(errs))

    for i, evil in enumerate(["../escape.bin", "/abs/path.bin", "..\\win.bin", "a/../../b.bin"]):
        bad = _mk_pack("ok-pack", [(evil, b"z")], source_for=lambda d, r: ["https://a.cn/x"])
        errs = mpm.validate_pack(bad)
        check(f"A5{chr(97+i)} 路径穿越拒绝: {evil!r}",
              any("path" in e for e in errs), str(errs))

    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"],
                   format="safetensors")
    errs = mpm.validate_pack(bad)
    check("A6a 未知 format → 明确错误", any("format" in e for e in errs), str(errs))
    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"],
                   task="tts")
    errs = mpm.validate_pack(bad)
    check("A6b 未知 task → 明确错误", any("task" in e for e in errs), str(errs))
    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"],
                   driver="vllm")
    errs = mpm.validate_pack(bad)
    check("A6c 未知 driver → 明确错误", any("driver" in e for e in errs), str(errs))

    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"])
    bad["size_bytes"] = 999
    errs = mpm.validate_pack(bad)
    check("A7 size_bytes 与 files 之和不符 → 拒绝", any("不一致" in e for e in errs), str(errs))

    for i, pid in enumerate(["UPPER", "has.dot", "has space", "x" * 65, ""]):
        check(f"A8{chr(97+i)} 非法 pack_id 拒绝: {pid!r}", not mpm.valid_pack_id(pid))
    check("A8f 合法 pack_id 通过", mpm.valid_pack_id("asr_sense-voice.small".replace(".", "-")))

    errs = mpm.validate_catalog({"version": 2, "packs": []})
    check("A9 catalog version≠1 → 明确错误", any("version" in e for e in errs), str(errs))

    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: ["ftp://x/y"])
    errs = mpm.validate_pack(bad)
    check("A10a 非法 source scheme → 拒绝", any("sources" in e for e in errs), str(errs))
    bad = _mk_pack("ok-pack", [("m.bin", b"z")], source_for=lambda d, r: [])
    errs = mpm.validate_pack(bad)
    check("A10b 空 sources → 拒绝", any("sources" in e for e in errs), str(errs))

    bad = _mk_pack("ok-pack", [("manifest.json", b"z")], source_for=lambda d, r: ["https://a.cn/x"])
    errs = mpm.validate_pack(bad)
    check("A11 保留名 manifest.json 占用 → 拒绝", any("manifest.json" in e for e in errs), str(errs))
    bad = _mk_pack("ok-pack", [(".partial/x.bin", b"z")], source_for=lambda d, r: ["https://a.cn/x"])
    errs = mpm.validate_pack(bad)
    check("A11b 保留目录 .partial/ 占用 → 拒绝", any(".partial" in e for e in errs), str(errs))


# ══════════ B. store / 注册表 / config 键 ══════════

def test_store():
    check("B1 packs_root 走 env 优先", mps.packs_root() == TMP / "packs", str(mps.packs_root()))

    pack = _mk_pack("reg-pack", [("m.bin", b"data1")], source_for=lambda d, r: ["file:///x"])
    mps.register_pack("reg-pack", pack)
    entry = mps.get_entry("reg-pack")
    check("B2a 注册后条目存在", entry is not None)
    check("B2b 默认启用（status=installed）", entry and entry.get("status") == "installed")
    check("B2c sha256_ok=True", entry and entry.get("sha256_ok") is True)
    check("B2d files 快照含 sha256", entry and entry["files"][0]["sha256"] == _sha(b"data1"))
    check("B3 原子写不留 .tmp", not (TMP / "packs" / "registry.json.tmp").exists())

    check("B4a toggle 禁用返回 False", mps.set_enabled("reg-pack", False) is False)
    check("B4b toggle 持久化（重读）", mps.get_entry("reg-pack")["status"] == "disabled")
    check("B4c toggle 未安装返回 None", mps.set_enabled("ghost-pack", True) is None)
    mps.set_enabled("reg-pack", True)

    listed = mps.list_installed()
    mine = [p for p in listed if p["pack_id"] == "reg-pack"]
    check("B5a 列表含包且 enabled", mine and mine[0]["enabled"] is True, str(listed))
    check("B5b 缺文件探测（m.bin 未落盘）", mine and mine[0]["missing_files"] == ["m.bin"], str(mine))

    check("B6 非法 pack_id 抛 ValueError", _raises(ValueError, lambda: mps.pack_dir("../evil")))

    check("B7a 卸载清理注册表", mps.unregister_pack("reg-pack") is True)
    check("B7b 卸载后不再安装", not mps.is_installed("reg-pack"))
    check("B7c 重复卸载返回 False", mps.unregister_pack("reg-pack") is False)

    # .app 封印：安装根落在 .app 内必须拒绝
    old_env = os.environ.get("VETARAI_MODEL_PACKS_DIR")
    os.environ["VETARAI_MODEL_PACKS_DIR"] = str(TMP / "Fake.app" / "Contents" / "Resources")
    try:
        check("B8 .app 内安装根拒绝", _raises(RuntimeError, mps.packs_root))
    finally:
        os.environ["VETARAI_MODEL_PACKS_DIR"] = old_env or ""

    # config 键校验（成对登记；reload_config 未知键拒写机制 :416）
    from sidecar.config import reload_config
    check("B9a catalog_urls 非法 scheme 拒写",
          _raises(ValueError, lambda: reload_config({"model_pack_catalog_urls": ["ftp://x"]})))
    check("B9b catalog_urls 非列表拒写",
          _raises(ValueError, lambda: reload_config({"model_pack_catalog_urls": "http://x"})))
    check("B9c confirm 开关非 bool 拒写",
          _raises(ValueError, lambda: reload_config({"confirm_model_pack_download": "yes"})))
    check("B9d packs_dir 相对路径拒写",
          _raises(ValueError, lambda: reload_config({"model_packs_dir": "relative/x"})))
    cfg = reload_config({"model_pack_catalog_urls": ["file:///tmp/ok", "https://a.cn/c.json"]})
    check("B9e 合法 catalog_urls 写入", cfg.get("model_pack_catalog_urls") == ["file:///tmp/ok", "https://a.cn/c.json"])
    reload_config({"model_pack_catalog_urls": []})
    check("B9f 未知键仍拒写（既有机制不破坏）",
          _raises(ValueError, lambda: reload_config({"no_such_key_0429": 1})))


def _raises(exc_type, fn) -> bool:
    try:
        fn()
        return False
    except exc_type:
        return True
    except Exception:
        return False


# ══════════ C. 下载器（本地 HTTP + Range）══════════

async def test_downloader():
    data1 = os.urandom(300 * 1024)      # model.gguf 300KB
    data2 = os.urandom(50 * 1024)       # tokenizer/tokens.json 50KB（子目录路径）
    routes = {
        "/p1/model.gguf": {"data": data1},
        "/p1/tokens.json": {"data": data2},
        "/p1/badsha.bin": {"data": b"corrupted-bytes"},
        "/good/model.bin": {"data": b"good-source-two"},
        "/slow/big.bin": {"data": os.urandom(2 * 1024 * 1024), "trickle": 0.02},
        "/norange/m.bin": {"data": b"norange-content-1234567890", "range_ok": False},
    }
    srv = _start_server(routes)
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        # ── C1 全量下载（多文件 + 子目录路径）──
        ev = _EvtLog()
        pack = _mk_pack("dl-full", [("model.gguf", data1), ("tokenizer/tokens.json", data2)],
                        source_for=lambda d, r: [f"{base}/p1/{'model.gguf' if 'model' in r else 'tokens.json'}"])
        await mpd.download_pack(pack, emit=ev)
        d = mps.pack_dir("dl-full")
        check("C1a 两文件落盘且内容一致",
              (d / "model.gguf").read_bytes() == data1
              and (d / "tokenizer" / "tokens.json").read_bytes() == data2)
        check("C1b manifest.json 副本写入", (d / "manifest.json").is_file())
        check("C1c 注册表已登记", mps.is_installed("dl-full"))
        check("C1d .partial 已清空", not (d / ".partial").exists() or not any((d / ".partial").rglob("*.part")))
        acts = ev.actions()
        check("C1e 事件含 start/progress/done",
              "download_start" in acts and "download_progress" in acts and "download_done" in acts,
              str(acts))
        start_ev = [f for a, _, f in ev.events if a == "download_start"][0]
        check("C1f start 事件带总字节数", start_ev.get("total_bytes") == len(data1) + len(data2))

        # ── C2 断点续传：预置半截 .part，服务器必须收到 Range ──
        srv.requests.clear()
        ev2 = _EvtLog()
        half = len(data1) // 2
        pd = mps.partial_dir("dl-resume")
        pd.mkdir(parents=True, exist_ok=True)
        (pd / "model.gguf.part").write_bytes(data1[:half])
        pack = _mk_pack("dl-resume", [("model.gguf", data1)],
                        source_for=lambda d, r: [f"{base}/p1/model.gguf"])
        await mpd.download_pack(pack, emit=ev2)
        check("C2a 续传后文件完整", (mps.pack_dir("dl-resume") / "model.gguf").read_bytes() == data1)
        ranges = [r for _, r in srv.requests if r]
        check("C2b 服务器收到 Range 且起点=半截字节数",
              any(r == f"bytes={half}-" for r in ranges), str(srv.requests))

        # ── C3 SHA256 不匹配拒收 ──
        pack = _mk_pack("dl-badsha", [("badsha.bin", b"corrupted-bytes")],
                        source_for=lambda d, r: [f"{base}/p1/badsha.bin"])
        pack["files"][0]["sha256"] = _sha(b"the-real-bytes")  # 声明与实际不符
        try:
            await mpd.download_pack(pack, emit=_EvtLog())
            check("C3a 坏哈希 → PackDownloadError", False, "未抛错")
        except mpd.PackDownloadError as e:
            check("C3a 坏哈希 → PackDownloadError", "SHA256" in str(e), str(e)[:120])
        check("C3b 坏哈希文件未落地", not (mps.pack_dir("dl-badsha") / "badsha.bin").exists())
        check("C3c 坏哈希未登记注册表", not mps.is_installed("dl-badsha"))

        # ── C4 多源回退：第一源 404 → 第二源成 ──
        ev4 = _EvtLog()
        pack = _mk_pack("dl-fallback", [("model.bin", b"good-source-two")],
                        source_for=lambda d, r: [f"{base}/no/such.file", f"{base}/good/model.bin"])
        await mpd.download_pack(pack, emit=ev4)
        check("C4 首源 404 → 次源成功安装",
              (mps.pack_dir("dl-fallback") / "model.bin").read_bytes() == b"good-source-two")

        # ── C5 取消后 .partial 保留（慢速滴灌 + manager.cancel）──
        ev5 = _EvtLog()
        orig_emit = mpd._default_emit
        mpd._default_emit = ev5  # manager 内部走 _default_emit，注入捕获器
        try:
            big = routes["/slow/big.bin"]["data"]
            pack = _mk_pack("dl-cancel", [("big.bin", big)],
                            source_for=lambda d, r: [f"{base}/slow/big.bin"])
            mgr = mpd.pack_download_manager
            mgr.start("dl-cancel", pack)
            part = mps.partial_dir("dl-cancel") / "big.bin.part"
            # 等下载真正开始写字节（轮询防时序 flaky）
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if part.exists() and part.stat().st_size > 0:
                    break
                await asyncio.sleep(0.05)
            check("C5a 取消前已有半截字节", part.exists() and 0 < part.stat().st_size < len(big))
            ok = await mgr.cancel("dl-cancel")
            check("C5b cancel 返回 True", ok is True)
            check("C5c .partial 保留供续传", part.exists() and part.stat().st_size > 0)
            check("C5d 取消后未登记注册表", not mps.is_installed("dl-cancel"))
            check("C5e 事件含 download_cancelled", "download_cancelled" in ev5.actions(), str(ev5.actions()))
            check("C5f 重复 cancel 返回 False", await mgr.cancel("dl-cancel") is False)
        finally:
            mpd._default_emit = orig_emit

        # ── C6 file:// 源（本地目录直接拷贝）──
        local_dir = TMP / "local_pack"
        local_dir.mkdir(parents=True, exist_ok=True)
        (local_dir / "model.onnx").write_bytes(b"local-onnx-weights")
        (local_dir / "tokens.txt").write_bytes(b"local-tokens")
        pack = _mk_pack("dl-local", [("model.onnx", b"local-onnx-weights"), ("tokens.txt", b"local-tokens")],
                        source_for=lambda d, r: [(local_dir / r).as_uri()])
        await mpd.download_pack(pack, emit=_EvtLog())
        check("C6 file:// 双文件本地拷贝安装",
              (mps.pack_dir("dl-local") / "model.onnx").read_bytes() == b"local-onnx-weights"
              and (mps.pack_dir("dl-local") / "tokens.txt").read_bytes() == b"local-tokens")

        # ── C7 服务器无视 Range（回 200）→ 从头重下仍完整 ──
        pd7 = mps.partial_dir("dl-norange")
        pd7.mkdir(parents=True, exist_ok=True)
        (pd7 / "m.bin.part").write_bytes(b"nora")  # 预置 4 字节半截
        pack = _mk_pack("dl-norange", [("m.bin", b"norange-content-1234567890")],
                        source_for=lambda d, r: [f"{base}/norange/m.bin"])
        await mpd.download_pack(pack, emit=_EvtLog())
        check("C7 无视 Range → 全量重下内容完整",
              (mps.pack_dir("dl-norange") / "m.bin").read_bytes() == b"norange-content-1234567890")
    finally:
        srv.shutdown()
        srv.server_close()


# ══════════ D. 端点层（TestClient）══════════

def test_endpoints():
    from sidecar import app as appmod
    from fastapi.testclient import TestClient

    # C 段已装了若干包，端点层从干净状态开始（卸载清理，模拟全新安装）
    for p in mps.list_installed():
        mps.remove_pack(p["pack_id"])

    # 本地 catalog 目录（catalog.json + 权重同目录，sources 用相对写法，
    # 覆盖 fetch_catalog 的相对→绝对 file:// 改写）
    catdir = TMP / "catalog_dir"
    catdir.mkdir(parents=True, exist_ok=True)
    (catdir / "mini.gguf").write_bytes(b"mini-weights-0429")
    cat_pack = _mk_pack("e2e-mini", [("mini.gguf", b"mini-weights-0429")],
                        source_for=lambda d, r: ["mini.gguf"])  # 相对源
    (catdir / "catalog.json").write_text(
        json.dumps({"version": 1, "packs": [cat_pack]}, ensure_ascii=False), encoding="utf-8")

    # 桩 get_config 必须并入完整 DEFAULT_CONFIG：with TestClient 会跑 startup 钩子
    # （_boot 读 cfg['ollama_base_url']），只给三个键会 KeyError（实测踩过）。
    appmod.get_config = lambda: {
        **_cs.DEFAULT_CONFIG,
        "network_switch": "auto", "egress_proxy_required": [],
        "model_pack_catalog_urls": [catdir.as_uri(),  "http://127.0.0.1:1/dead.json"],
    }
    # 必须 with 进入上下文：starlette TestClient 不用 with 时**每个请求各起一个临时
    # 事件循环**（_portal_factory 实测，starlette 1.6），install 的后台 asyncio 任务
    # 会在响应返回后随临时 loop 关闭被销毁——D3 轮询永远等不到安装完成。
    # 生产 uvicorn 主 loop 常驻，无此问题。
    with TestClient(appmod.app) as client:
        _run_endpoint_checks(client, catdir)
    return


def _run_endpoint_checks(client, catdir: Path):

    r = client.get("/api/model-packs")
    check("D1 空列表", r.status_code == 200 and r.json()["packs"] == [], r.text[:120])

    r = client.get("/api/model-packs/catalog")
    body = r.json()
    check("D2a catalog 合并出包", r.status_code == 200 and len(body["packs"]) == 1, r.text[:200])
    check("D2b 坏源标注 source_errors 不拖死整列",
          len(body["source_errors"]) == 1 and "dead" in body["source_errors"][0]["source"],
          str(body.get("source_errors")))
    check("D2c packs 标注未安装", body["packs"] and body["packs"][0]["installed"] is False)
    check("D2d 相对 source 已改写为绝对 file://",
          body["packs"] and body["packs"][0]["files"][0]["sources"][0].startswith("file:///"),
          str(body["packs"][0]["files"][0]["sources"]) if body["packs"] else "")

    # install → accepted → 后台任务完成 → 列表出现
    entry = body["packs"][0]
    r = client.post("/api/model-packs/install", json={"pack_id": "e2e-mini", "catalog_entry": entry})
    check("D3a install 立即 accepted", r.status_code == 200 and r.json().get("accepted") is True, r.text[:120])
    deadline = time.monotonic() + 10
    installed = None
    while time.monotonic() < deadline:
        lr = client.get("/api/model-packs").json()["packs"]
        installed = next((p for p in lr if p["pack_id"] == "e2e-mini"), None)
        if installed:
            break
        time.sleep(0.1)
    check("D3b 安装完成出现在列表", installed is not None)
    check("D3c 列表 enabled 且无缺文件",
          bool(installed) and installed["enabled"] is True and installed["missing_files"] == [],
          str(installed))
    check("D3d 权重已落盘",
          (mps.pack_dir("e2e-mini") / "mini.gguf").read_bytes() == b"mini-weights-0429")

    r = client.post("/api/model-packs/install", json={"pack_id": "e2e-mini", "catalog_entry": entry})
    check("D4a 重复安装 → 409", r.status_code == 409, str(r.status_code))
    r = client.post("/api/model-packs/install",
                    json={"pack_id": "e2e-mini", "catalog_entry": {**entry, "pack_id": "other-pack"}})
    check("D4b pack_id 不一致 → 400", r.status_code == 400, str(r.status_code))
    evil = _mk_pack("evil-pack", [("../escape.bin", b"z")], source_for=lambda d, r: ["file:///x"])
    r = client.post("/api/model-packs/install", json={"pack_id": "evil-pack", "catalog_entry": evil})
    check("D4c 路径穿越条目 → 400", r.status_code == 400, str(r.status_code))
    r = client.post("/api/model-packs/cancel", json={"pack_id": "e2e-mini"})
    check("D4d 无进行中下载 cancel → 404", r.status_code == 404, str(r.status_code))

    r = client.post("/api/model-packs/e2e-mini/toggle", json={"enabled": False})
    check("D5a toggle 禁用", r.status_code == 200 and r.json()["enabled"] is False, r.text[:120])
    check("D5b 禁用持久化到注册表", mps.get_entry("e2e-mini")["status"] == "disabled")
    r = client.post("/api/model-packs/ghost-pack/toggle", json={"enabled": True})
    check("D5c 未安装 toggle → 404", r.status_code == 404, str(r.status_code))
    client.post("/api/model-packs/e2e-mini/toggle", json={"enabled": True})

    r = client.delete("/api/model-packs/e2e-mini")
    check("D6a 卸载 deleted", r.status_code == 200 and r.json().get("deleted") is True, r.text[:120])
    check("D6b 目录已删", not mps.pack_dir("e2e-mini").exists())
    check("D6c 注册表已清", not mps.is_installed("e2e-mini"))
    r = client.delete("/api/model-packs/e2e-mini")
    check("D6d 重复卸载 → 404", r.status_code == 404, str(r.status_code))
    lr = client.get("/api/model-packs").json()["packs"]
    check("D6e 列表回到无 e2e-mini", all(p["pack_id"] != "e2e-mini" for p in lr))


# ══════════ main ══════════

def main():
    test_manifest()
    test_store()
    asyncio.run(test_downloader())
    test_endpoints()

    print(f"\n===== 0.4.29-P1 模型包专项: PASS={PASS} FAIL={FAIL} =====")
    if MUTATE:
        # 变异模式下必须出现 FAIL；0 FAIL = 断言空转（测试对该修复无效）
        if FAIL == 0:
            print(f"⛔ 变异 {MUTATE} 未被抓住 —— 本测试对该修复无效，断言需加强")
            sys.exit(1)
        print(f"变异 {MUTATE} 已命中（FAIL={FAIL}，符合预期）")
        return
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    _apply_mutation()
    try:
        main()
    finally:
        _restore()
