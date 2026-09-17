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
"""0.4.29（P2）llama.cpp 驱动 + 模型包对话接入专项套件。

隔离：顶部先钉 VETARAI_MODEL_PACKS_DIR + VETARAI_DATA_ROOT 到临时目录，
再桩 config.store.get_config_path（test_model_packs.py 同款）；
子进程日志路径 _server_log_path 改指 TMP（不写仓库 logs/）。

半真实链路：假 llama-server = 本文件运行时写到 TMP 的 python 小 HTTP 服务
（127.0.0.1，实现 /v1/models 与 /v1/chat/completions 含 SSE），驱动对它做
真实 spawn / 健康探测 / 换装 / terminate→kill。行为开关走 FAKE_LLAMA_* 环境变量。

变异测试机制（MUTATE=1|2|3|4|5|6 python -m sidecar.model_packs.test_driver_llamacpp）：
⛔ 变异模式下必须出现 FAIL；0 FAIL = 断言空转，需加强（不是"通过"）。
| 变异 | 撤掉的修复 | 应失败的断言 |
|---|---|---|
| 1 | 工厂第三分支缺失（model_package 不再分发 ModelPackageConnector） | E8a |
| 2 | 换装作废（ensure_server 不再停旧直接启新） | D3a |
| 3 | manifest context_length 校验失效（非法值放行） | A2a/A2b/A2c |
| 4 | ensure_server 注册表门禁失效（禁用/卸载照样短路复用） | H1b/H1c/H4a/H4b |
| 5 | 卸载端点不回收运行时（llama-server 孤儿常驻） | H6b/H6c |
| 6 | 禁用端点不回收运行时 | H5b/H5c |
"""
import asyncio
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# ── 隔离（必须先于一切 sidecar 导入）──
TMP = Path(tempfile.mkdtemp(prefix="mpdrv_test_"))
os.environ["VETARAI_MODEL_PACKS_DIR"] = str(TMP / "packs")
os.environ.setdefault("VETARAI_DATA_ROOT", str(TMP / "data"))

import sidecar.config.store as _cs  # noqa: E402
_cs.get_config_path = lambda: TMP / "config.json"
_cs._MEM = {}

import sidecar.model_packs.manifest as mpm  # noqa: E402
import sidecar.model_packs.store as mps  # noqa: E402
import sidecar.model_packs.llamacpp_driver as mpd  # noqa: E402

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


# ══════════ 变异机制（test_model_packs.py 同款：内存备份 + finally 还原 + reload）══════════
MUTATE = int(os.environ.get("MUTATE", "0"))
_BACKUP: dict[str, tuple[Path, str]] = {}


def _mutate_file(path: Path, old: str, new: str, tag: str) -> None:
    s = path.read_text(encoding="utf-8")
    _BACKUP[tag] = (path, s)
    patched = s.replace(old, new)
    assert patched != s, f"变异 {MUTATE} 未命中 {path.name} 源码锚点，测试无效"
    path.write_text(patched, encoding="utf-8")


def _apply_mutation() -> None:
    if not MUTATE:
        return
    import importlib
    if MUTATE == 1:
        import sidecar.ollama.connector as connmod
        _mutate_file(Path(connmod.__file__),
                     '    if backend == "model_package":',
                     '    if backend == "model_package__mutated":', "connector")
        importlib.reload(connmod)
    elif MUTATE == 2:
        _mutate_file(Path(mpd.__file__),
                     "        if proc is not None:\n"
                     "            # 换装语义（Ollama 同款）：同一时刻只跑一个对话包——先停旧、再启新。\n"
                     "            await _stop_locked()",
                     "        if proc is not None:\n"
                     "            pass  # 变异2：换装作废", "driver")
        importlib.reload(mpd)
    elif MUTATE == 3:
        _mutate_file(Path(mpm.__file__),
                     "    if cl is not None and not _is_pos_int(cl):",
                     "    if False and cl is not None and not _is_pos_int(cl):", "manifest")
        importlib.reload(mpm)
    elif MUTATE == 4:
        _mutate_file(Path(mpd.__file__),
                     "            _enabled_entry(pack_id)",
                     "            pass  # 变异4：注册表门禁失效", "driver")
        importlib.reload(mpd)
    elif MUTATE == 5:
        from sidecar import app as _appmod
        _mutate_file(Path(_appmod.__file__),
                     "    await _release_pack_runtime(pack_id)\n"
                     "    ok = _mp_store.remove_pack(pack_id)",
                     "    ok = _mp_store.remove_pack(pack_id)  # 变异5：卸载不回收运行时",
                     "app")
        importlib.reload(_appmod)
    elif MUTATE == 6:
        from sidecar import app as _appmod
        _mutate_file(Path(_appmod.__file__),
                     "    if not new_state:\n"
                     "        await _release_pack_runtime(pack_id)",
                     "    if not new_state:\n"
                     "        pass  # 变异6：禁用不回收运行时", "app")
        importlib.reload(_appmod)
    else:
        raise SystemExit(f"未知变异编号 {MUTATE}（支持 1|2|3|4|5|6）")


def _restore() -> None:
    """还原被变异的源文件（必须在 finally：用例 sys.exit 会抛 SystemExit）。"""
    if not MUTATE or not _BACKUP:
        return
    import importlib
    try:
        for path, s in _BACKUP.values():
            path.write_text(s, encoding="utf-8")
    finally:
        tags = set(_BACKUP.keys())
        _BACKUP.clear()
        if "connector" in tags:
            import sidecar.ollama.connector as connmod
            importlib.reload(connmod)
        if "driver" in tags:
            importlib.reload(mpd)
        if "manifest" in tags:
            importlib.reload(mpm)
        if "app" in tags:
            from sidecar import app as _appmod
            importlib.reload(_appmod)


# ══════════ 测试数据构造 ══════════

def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _install_fake_pack(pack_id: str, *, context_length=None, task: str = "chat",
                       enabled: bool = True, suffix: str = "model.gguf") -> dict:
    """造一个"已安装"包：权重占位文件 + manifest.json 副本 + 注册表登记。"""
    data = b"FAKE-WEIGHTS-" + pack_id.encode()
    d = mps.pack_dir(pack_id)
    d.mkdir(parents=True, exist_ok=True)
    (d / suffix).write_bytes(data)
    pack = {"pack_id": pack_id, "name": f"测试包 {pack_id}", "task": task,
            "format": "gguf" if suffix.endswith(".gguf") else "onnx",
            "driver": "llamacpp", "version": "1.0.0", "description": "P2 测试用",
            "size_bytes": len(data), "min_app_version": "", "homepage": "", "license": "MIT",
            "files": [{"path": suffix, "size_bytes": len(data),
                       "sha256": _sha(data), "sources": ["file:///x"]}]}
    if context_length is not None:
        pack["context_length"] = context_length
    (d / "manifest.json").write_text(json.dumps(pack, ensure_ascii=False), encoding="utf-8")
    mps.register_pack(pack_id, pack)
    if not enabled:
        mps.set_enabled(pack_id, False)
    return pack


# ══════════ 假 llama-server（python 小 HTTP 服务，半真实链路）══════════

FAKE_SERVER_PY = r'''#!/usr/bin/env python3
"""假 llama-server：/v1/models 健康探测 + /v1/chat/completions（含 SSE 流式）。
行为开关（环境变量）：
  FAKE_LLAMA_READY_DELAY   /v1/models 延迟就绪秒数（此前回 503）
  FAKE_LLAMA_DIE=1         启动即 exit(3)（模拟坏 GGUF 崩溃）
  FAKE_LLAMA_TERM_STUBBORN=1 收到 SIGTERM 记录到 FAKE_LLAMA_TERM_LOG 但不退出（等 SIGKILL）
  FAKE_LLAMA_REPORT        启动报告落盘路径（argv + 代理环境是否被剥离）
  FAKE_LLAMA_MAX_LIFE      寿命上限秒（防测试进程异常退出后孤儿常驻）
"""
import json, os, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if os.environ.get("FAKE_LLAMA_DIE") == "1":
    sys.stderr.write("fatal: mock bad gguf, cannot load model\n")
    sys.exit(3)

if os.environ.get("FAKE_LLAMA_TERM_STUBBORN") == "1":
    def _on_term(signum, frame):
        with open(os.environ["FAKE_LLAMA_TERM_LOG"], "a", encoding="utf-8") as fp:
            fp.write("term\n")
        # 故意不退出，等 SIGKILL
    signal.signal(signal.SIGTERM, _on_term)

args = sys.argv[1:]
av = {}
i = 0
while i < len(args):
    if args[i] in ("--model", "--port", "--host", "-c") and i + 1 < len(args):
        av[args[i]] = args[i + 1]
        i += 2
    else:
        i += 1
port = int(av.get("--port", "0"))
ready_delay = float(os.environ.get("FAKE_LLAMA_READY_DELAY", "0"))
born = time.monotonic()

report = os.environ.get("FAKE_LLAMA_REPORT")
if report:
    with open(report, "w", encoding="utf-8") as fp:
        json.dump({"argv": args,
                   "has_proxy_env": any(k in os.environ for k in (
                       "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                       "http_proxy", "https_proxy", "all_proxy"))}, fp)

max_life = float(os.environ.get("FAKE_LLAMA_MAX_LIFE", "180"))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _ready(self):
        return time.monotonic() - born >= ready_delay

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            if not self._ready():
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps({"object": "list",
                               "data": [{"id": "fake-model", "object": "model"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path.startswith("/v1/chat/completions"):
            ln = int(self.headers.get("Content-Length") or 0)
            try:
                req = json.loads(self.rfile.read(ln) or b"{}")
            except Exception:
                req = {}
            if req.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for obj in ({"choices": [{"delta": {"content": "po"}}]},
                            {"choices": [{"delta": {"content": "ng"}, "finish_reason": "stop"}],
                             "usage": {"prompt_tokens": 3, "completion_tokens": 2}}):
                    self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode())
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return
            body = json.dumps({"choices": [{"message": {"role": "assistant", "content": "pong"},
                                            "finish_reason": "stop"}],
                               "usage": {"prompt_tokens": 3, "completion_tokens": 1}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


srv = ThreadingHTTPServer(("127.0.0.1", port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(max_life)
'''


def _setup_fake_server() -> Path:
    """把假 llama-server 写到 TMP 并加可执行位；返回路径。"""
    p = TMP / "fake-llama-server"
    p.write_text(FAKE_SERVER_PY, encoding="utf-8")
    p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return p


def _fresh_state() -> None:
    """清驱动活动状态（各 section 之间不复用现场）。"""
    mpd._STATE.update({"pack_id": None, "proc": None, "port": None, "log_fp": None})


# ══════════ A. manifest context_length 可选键校验 ══════════

def test_manifest_context_length():
    base_files = [{"path": "m.gguf", "size_bytes": 3, "sha256": _sha(b"xyz"),
                   "sources": ["https://a.cn/x"]}]
    good = {"pack_id": "ctx-pack", "name": "n", "task": "chat", "format": "gguf",
            "driver": "llamacpp", "version": "1.0.0", "size_bytes": 3, "files": base_files}
    errs = mpm.validate_pack({**good, "context_length": 4096})
    check("A1 context_length=4096 合法", errs == [], str(errs))
    errs = mpm.validate_pack(good)
    check("A1b context_length 缺省（整键不写）合法", errs == [], str(errs))
    for i, bad in enumerate(["4096", 0, -128, True]):
        errs = mpm.validate_pack({**good, "context_length": bad})
        check(f"A2{chr(97+i)} 非法 context_length 拒绝: {bad!r}",
              any("context_length" in e for e in errs), str(errs))


# ══════════ B. 二进制解析链 ══════════

def test_binary_resolution(fake: Path):
    old_env = os.environ.pop("VETARAI_LLAMA_SERVER", None)
    try:
        try:
            mpd.resolve_server_binary()
            check("B1 二进制缺失 → LlamaServerError", False, "未抛错")
        except mpd.LlamaServerError as e:
            msg = str(e)
            check("B1 二进制缺失 → LlamaServerError", True)
            check("B1b 错误中文指引含模型包面板/设置",
                  "未找到 llama-server" in msg and "模型包" in msg, msg[:160])
        # env 指向非法路径 → 继续回退仍找不到（不静默成功）
        os.environ["VETARAI_LLAMA_SERVER"] = str(TMP / "no-such-binary")
        try:
            mpd.resolve_server_binary()
            check("B2 env 指向不存在 → 仍报错", False, "未抛错")
        except mpd.LlamaServerError:
            check("B2 env 指向不存在 → 仍报错", True)
        # env 指向假服务器（可执行）→ 命中
        os.environ["VETARAI_LLAMA_SERVER"] = str(fake)
        check("B3 env 指向可执行文件 → 解析命中", mpd.resolve_server_binary() == fake)
        # 数据目录 drivers/ 回退（env 撤销后）。
        # ⛔ 必须问 data_root() 实时值：runner 会把 VETARAI_DATA_ROOT 指到它自己的
        # 临时目录（本文件顶部 setdefault 不覆盖），不能拿 TMP/"data" 硬算
        os.environ.pop("VETARAI_LLAMA_SERVER", None)
        from sidecar.config import data_root
        drv = Path(data_root()) / "drivers"
        drv.mkdir(parents=True, exist_ok=True)
        real = drv / "llama-server"
        real.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        real.chmod(0o755)
        check("B4 data_root()/drivers 回退命中", mpd.resolve_server_binary() == real)
        real.unlink()
    finally:
        os.environ.pop("VETARAI_LLAMA_SERVER", None)
        if old_env:
            os.environ["VETARAI_LLAMA_SERVER"] = old_env


# ══════════ C. spawn 参数（mock subprocess.Popen）══════════

async def test_spawn_args(fake: Path):
    os.environ["VETARAI_LLAMA_SERVER"] = str(fake)
    _install_fake_pack("ctx-pack", context_length=4096)
    _fresh_state()
    fake_proc = mock.Mock()
    fake_proc.poll.return_value = None  # None = 在跑（Mock 对象本身非 None，会被当成"已死"）
    with mock.patch.object(mpd.subprocess, "Popen", return_value=fake_proc) as popen_mock, \
         mock.patch.object(mpd, "_wait_ready", new=mock.AsyncMock()):
        url = await mpd.ensure_server("ctx-pack")
    argv = popen_mock.call_args[0][0]
    kwargs = popen_mock.call_args[1]
    gguf = str(mps.pack_dir("ctx-pack") / "model.gguf")
    check("C1a argv 形如 --model <gguf绝对路径> --port <p> --host 127.0.0.1",
          argv[0] == str(fake) and "--model" in argv and argv[argv.index("--model") + 1] == gguf
          and "--host" in argv and argv[argv.index("--host") + 1] == "127.0.0.1"
          and "--port" in argv, str(argv))
    check("C1b manifest context_length → -c 4096",
          "-c" in argv and argv[argv.index("-c") + 1] == "4096", str(argv))
    check("C1c 返回 base_url 含 /v1 且端口一致",
          url == f"http://127.0.0.1:{argv[argv.index('--port') + 1]}/v1", url)
    env = kwargs.get("env") or {}
    check("C1d 子进程环境剥离代理变量",
          all(k not in env for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                                     "http_proxy", "https_proxy", "all_proxy")), str(env)[:120])
    check("C1e stdout/stderr 导流到日志文件句柄",
          kwargs.get("stdout") is not None and kwargs.get("stderr") == mpd.subprocess.STDOUT)
    # 无 context_length 的包不带 -c
    _install_fake_pack("noctx-pack")
    with mock.patch.object(mpd.subprocess, "Popen", return_value=fake_proc) as popen_mock2, \
         mock.patch.object(mpd, "_wait_ready", new=mock.AsyncMock()):
        await mpd.ensure_server("noctx-pack")
    argv2 = popen_mock2.call_args[0][0]
    check("C2 无 context_length → 不带 -c", "-c" not in argv2, str(argv2))
    await mpd.stop_server()
    _fresh_state()


# ══════════ D. 生命周期（假 llama-server 半真实链路）══════════

async def test_lifecycle(fake: Path):
    os.environ["VETARAI_LLAMA_SERVER"] = str(fake)
    _fresh_state()
    _install_fake_pack("chat-a", context_length=4096)
    _install_fake_pack("chat-b")

    # D1 启动 + 健康探测重试（延迟就绪 1.2s → 探测须重试后成功）
    os.environ["FAKE_LLAMA_READY_DELAY"] = "1.2"
    t0 = time.monotonic()
    url = await mpd.ensure_server("chat-a")
    dt = time.monotonic() - t0
    os.environ.pop("FAKE_LLAMA_READY_DELAY", None)
    check("D1a 延迟就绪 → 重试后启动成功", url.startswith("http://127.0.0.1:") and url.endswith("/v1"), url)
    check("D1b 确实等了就绪延迟（重试非空转）", dt >= 1.0, f"{dt:.2f}s")
    check("D1c active_pack 登记", mpd.active_pack() == "chat-a")
    proc_a = mpd._STATE["proc"]

    # D2 重复启动同包 → 复用同进程
    url2 = await mpd.ensure_server("chat-a")
    check("D2 同包重复启动复用（同一进程对象）",
          mpd._STATE["proc"] is proc_a and url2 == url)

    # D3 换装 = 停旧启新
    url3 = await mpd.ensure_server("chat-b")
    check("D3a 换装后旧进程已停", proc_a.poll() is not None)
    check("D3b 换装后新包在跑", mpd.active_pack() == "chat-b" and url3 != url)

    # D4 停止语义
    check("D4a 停不匹配名字 → False 且不动现役", await mpd.stop_server("chat-a") is False
          and mpd.active_pack() == "chat-b")
    check("D4b 停现役 → True", await mpd.stop_server("chat-b") is True)
    check("D4c 停后无活动包", mpd.active_pack() is None)
    check("D4d 重复停 → False", await mpd.stop_server("chat-b") is False)

    # D5 terminate 先礼后兵：SIGTERM 记录但不退出 → 宽限后 SIGKILL
    term_log = TMP / "term.log"
    os.environ["FAKE_LLAMA_TERM_STUBBORN"] = "1"
    os.environ["FAKE_LLAMA_TERM_LOG"] = str(term_log)
    old_grace = mpd.TERMINATE_GRACE_S
    mpd.TERMINATE_GRACE_S = 0.3  # 测试收窄宽限（常量化的意义所在）
    try:
        await mpd.ensure_server("chat-a")
        stubborn = mpd._STATE["proc"]
        ok = await mpd.stop_server("chat-a")
        check("D5a 顽固进程停止返回 True", ok is True)
        deadline = time.monotonic() + 5
        while stubborn.poll() is None and time.monotonic() < deadline:
            await asyncio.sleep(0.05)
        check("D5b SIGKILL 后进程终死", stubborn.poll() is not None)
        check("D5c 先 terminate 后 kill（term 已送达）",
              term_log.exists() and "term" in term_log.read_text(), "term.log 无记录")
    finally:
        mpd.TERMINATE_GRACE_S = old_grace
        os.environ.pop("FAKE_LLAMA_TERM_STUBBORN", None)
        os.environ.pop("FAKE_LLAMA_TERM_LOG", None)

    # D6 启动即死 → 中文明细带日志尾巴
    os.environ["FAKE_LLAMA_DIE"] = "1"
    try:
        await mpd.ensure_server("chat-a")
        check("D6a 启动即死 → LlamaServerError", False, "未抛错")
    except mpd.LlamaServerError as e:
        check("D6a 启动即死 → LlamaServerError", "退出" in str(e), str(e)[:160])
        check("D6b 错误带日志尾巴（fatal 字样）", "fatal" in str(e), str(e)[:200])
    check("D6c 启动失败后状态已回收", mpd.active_pack() is None and mpd._STATE["proc"] is None)
    os.environ.pop("FAKE_LLAMA_DIE", None)

    # D7 健康探测超时 → 中文超时错误 + 现场回收
    os.environ["FAKE_LLAMA_READY_DELAY"] = "30"
    old_bt = mpd._boot_timeout
    mpd._boot_timeout = lambda: 2.0  # 测试收窄（真实口径走 config model_pack_boot_timeout_s）
    try:
        await mpd.ensure_server("chat-a")
        check("D7a 探测超时 → LlamaServerError", False, "未抛错")
    except mpd.LlamaServerError as e:
        check("D7a 探测超时 → LlamaServerError", "超时" in str(e), str(e)[:160])
    finally:
        mpd._boot_timeout = old_bt
        os.environ.pop("FAKE_LLAMA_READY_DELAY", None)
    check("D7b 超时后状态已回收", mpd.active_pack() is None)

    # D8 子进程代理环境剥离（真 spawn：父进程带 HTTP_PROXY，子进程报告无）
    report = TMP / "spawn_report.json"
    os.environ["HTTP_PROXY"] = "http://127.0.0.1:9"
    os.environ["FAKE_LLAMA_REPORT"] = str(report)
    try:
        await mpd.ensure_server("chat-a")
        deadline = time.monotonic() + 5
        while not report.exists() and time.monotonic() < deadline:
            await asyncio.sleep(0.05)
        rep = json.loads(report.read_text(encoding="utf-8")) if report.exists() else {}
        check("D8 子进程无代理环境变量", rep.get("has_proxy_env") is False, str(rep))
    finally:
        os.environ.pop("HTTP_PROXY", None)
        os.environ.pop("FAKE_LLAMA_REPORT", None)
    await mpd.stop_server()

    # D9 已死进程仅清理不动手（0.4.7 防护①）：外部先杀，再 stop → True 且不抛
    await mpd.ensure_server("chat-a")
    zombie = mpd._STATE["proc"]
    zombie.kill()
    await asyncio.to_thread(zombie.wait, 5.0)
    check("D9 已死进程 stop → True（仅清理状态）", await mpd.stop_server("chat-a") is True)
    _fresh_state()

    # D10 端口分配可绑定
    import socket as _sock
    p = mpd._free_port()
    ok = False
    try:
        with _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", p))
            ok = True
    except OSError:
        ok = False
    check("D10 空闲端口分配可绑定", ok and 1 <= p <= 65535, str(p))

    # D11 未安装/已禁用/无 GGUF → 中文报错
    for pid, expect, setup in (
            ("ghost-pack", "未安装", None),
            ("disabled-pack", "已禁用", lambda: _install_fake_pack("disabled-pack", enabled=False)),
            ("nogguf-pack", ".gguf", lambda: _install_fake_pack("nogguf-pack", suffix="model.onnx")),
    ):
        if setup:
            setup()
        try:
            await mpd.ensure_server(pid)
            check(f"D11 {pid} → 报错", False, "未抛错")
        except mpd.LlamaServerError as e:
            check(f"D11 {pid} → 报错含 {expect}", expect in str(e), str(e)[:160])


# ══════════ E. ModelPackageConnector（假服务器真实 HTTP 往返）══════════

async def test_connector():
    from sidecar.config import reload_config
    from sidecar.model_packs.mp_connector import ModelPackageConnector
    import sidecar.ollama.connector as connmod
    from sidecar.ollama.connector import OllamaAPIError

    _fresh_state()
    # 注册表清场（前面 C/D 段注册的包还在，聚合断言要从干净状态开始）
    for p in mps.list_installed():
        mps.remove_pack(p["pack_id"])
    # 注册表：两个启用 chat 包 + 一个禁用 chat 包 + 一个 asr 包
    _install_fake_pack("chat-a", context_length=4096)
    _install_fake_pack("chat-b")
    _install_fake_pack("chat-c", enabled=False)
    _install_fake_pack("asr-x", task="asr", suffix="model.onnx")

    conn = ModelPackageConnector()
    models = await conn.list_models()
    names = [m["name"] for m in models]
    check("E1a list_models 聚合已启用 chat 包", sorted(names) == ["chat-a", "chat-b"], str(names))
    check("E1b asr 包不出现", "asr-x" not in names)
    check("E1c 禁用包不出现", "chat-c" not in names)
    a = next(m for m in models if m["name"] == "chat-a")
    check("E1d 条目带 size/source/context_length",
          a.get("source") == "model_pack" and a.get("size", 0) > 0
          and a.get("context_length") == 4096, str(a))
    check("E2 capabilities 定稿",
          conn.capabilities() == {"backend": "model_package", "tools": True,
                                  "vision": False, "pull": False, "delete": False},
          str(conn.capabilities()))

    # E3 未安装的包对话 → OllamaAPIError（中文明细）
    try:
        await conn.chat("ghost-pack", [{"role": "user", "content": "hi"}])
        check("E3 未安装包对话 → OllamaAPIError", False, "未抛错")
    except OllamaAPIError as e:
        check("E3 未安装包对话 → OllamaAPIError", "未安装" in str(e), str(e)[:160])

    # E4 非流式 chat：目标包未跑 → 自动启动 → 假服务器回 pong
    reply = await conn.chat("chat-a", [{"role": "user", "content": "hi"}])
    check("E4a chat 自动启动并拿到回复", reply == "pong", reply[:80])
    check("E4b chat 后活动包登记", mpd.active_pack() == "chat-a")
    check("E5a list_loaded_models = [活动包]", await conn.list_loaded_models() == ["chat-a"])

    # E5 流式 chat_stream：SSE 解析零改动继承（协议一致一票否决项）
    events = []
    async for ev in conn.chat_stream("chat-a", [{"role": "user", "content": "hi"}]):
        events.append(ev)
    deltas = [e["content_delta"] for e in events if "content_delta" in e]
    done = next((e for e in events if e.get("done")), None)
    check("E5b 流式 content 增量拼接", "".join(deltas) == "pong", str(events)[:200])
    check("E5c done 事件 usage 映射",
          done is not None and done["counts"] == {"prompt_eval_count": 3, "eval_count": 2},
          str(done))

    # E6 unload_model = 停驱动
    check("E6a unload 现役 → True", await conn.unload_model("chat-a") is True)
    check("E6b unload 后 loaded 为空", await conn.list_loaded_models() == [])
    check("E6c unload 无名 → False", await conn.unload_model("chat-a") is False)

    # E7 连接器层面换装：chat(chat-b) → chat-a 已停
    await conn.chat("chat-a", [{"role": "user", "content": "hi"}])
    proc_a = mpd._STATE["proc"]
    await conn.chat("chat-b", [{"role": "user", "content": "hi"}])
    check("E7 连接器换装：旧包进程已停", proc_a.poll() is not None
          and mpd.active_pack() == "chat-b")
    await conn.unload_model("chat-b")

    # E8 工厂第三分支（变异 1 的靶子）
    reload_config({"inference_backend": "model_package"})
    connmod._MP_SINGLETON = None
    c = connmod.get_inference_connector()
    check("E8a model_package 后端 → ModelPackageConnector", isinstance(c, ModelPackageConnector),
          type(c).__name__)
    check("E8b 工厂单例稳定", connmod.get_inference_connector() is c)
    check("E8c 别名 get_ollama_connector 跟随工厂", connmod.get_ollama_connector() is c)

    # E9 model_package 后端下不强求 inference_base_url（config 校验）
    cfg = reload_config({"inference_backend": "model_package", "inference_base_url": ""})
    check("E9 model_package 空 inference_base_url 可保存",
          cfg.get("inference_backend") == "model_package")
    reload_config({"inference_backend": "ollama"})
    _fresh_state()


# ══════════ F. 端点层（context/limit 从 manifest、status/models 天然工作）══════════

def test_endpoints():
    from sidecar import app as appmod
    from sidecar.config import reload_config
    from fastapi.testclient import TestClient

    # ⛔ 两处都要是 model_package：appmod.get_config 桩只覆盖端点函数里的读法；
    # 工厂 get_inference_connector 走的是 connector 模块自己的 get_config 引用
    # （读 TMP config.json），只桩 appmod 会让 status 端点分发到 OllamaConnector。
    reload_config({"inference_backend": "model_package"})
    appmod.get_config = lambda: {
        **_cs.DEFAULT_CONFIG,
        "network_switch": "auto", "egress_proxy_required": [],
        "inference_backend": "model_package", "inference_base_url": "",
    }
    with TestClient(appmod.app) as client:
        r = client.get("/api/context/limit", params={"model": "chat-a"})
        check("F1 context/limit 从 manifest 取值",
              r.status_code == 200 and r.json()["context_length"] == 4096
              and r.json()["source"] == "manifest", r.text[:160])
        r = client.get("/api/context/limit", params={"model": "chat-b"})
        check("F2 manifest 无 context_length → unsupported",
              r.status_code == 200 and r.json()["source"] == "unsupported", r.text[:160])
        r = client.get("/api/inference/status")
        body = r.json()
        check("F3 status：backend/capabilities 走工厂",
              body.get("backend") == "model_package"
              and body.get("capabilities", {}).get("backend") == "model_package", r.text[:240])
        check("F3b status online（list_models 读注册表即可达）", body.get("online") is True, r.text[:240])
        r = client.get("/api/inference/models")
        names = [m.get("name") for m in r.json()]
        check("F4 models 端点聚合包列表", sorted(names) == ["chat-a", "chat-b"], r.text[:240])


# ══════════ H. 禁用/卸载语义（0.4.29 缺陷修复 A/B：进程随状态失效即止）══════════

async def test_disable_uninstall_semantics(fake: Path):
    """驱动层：禁用/卸载正在服务的包 → ensure_server 先回收子进程再报中文错。"""
    from sidecar.model_packs.mp_connector import ModelPackageConnector
    from sidecar.ollama.connector import OllamaAPIError

    os.environ["VETARAI_LLAMA_SERVER"] = str(fake)
    _fresh_state()
    _install_fake_pack("chat-h")

    # H1 禁用热路径：服务中禁用 → ensure_server 先回收进程再报「已禁用」（缺陷 A 主修复）
    await mpd.ensure_server("chat-h")
    proc = mpd._STATE["proc"]
    check("H1a 服务在跑（前置）", proc is not None and proc.poll() is None)
    mps.set_enabled("chat-h", False)
    try:
        await mpd.ensure_server("chat-h")
        check("H1b 禁用后 ensure → LlamaServerError", False, "未抛错")
    except mpd.LlamaServerError as e:
        check("H1b 禁用后 ensure → 报错含已禁用", "已禁用" in str(e), str(e)[:160])
    check("H1c 禁用后进程被回收", proc.poll() is not None)
    check("H1d 禁用后无活动包", mpd.active_pack() is None)

    # H2 连接器层：禁用包对话 → OllamaAPIError(400)（端点 4xx 语义来源）
    conn = ModelPackageConnector()
    try:
        await conn.chat("chat-h", [{"role": "user", "content": "hi"}])
        check("H2 禁用包对话 → OllamaAPIError", False, "未抛错")
    except OllamaAPIError as e:
        check("H2 禁用包对话 → 400 含已禁用",
              e.status_code == 400 and "已禁用" in str(e), str(e)[:160])

    # H3 启用恢复：重新启用 → 对话恢复（重新拉起进程）
    mps.set_enabled("chat-h", True)
    reply = await conn.chat("chat-h", [{"role": "user", "content": "hi"}])
    check("H3 启用后对话恢复", reply == "pong" and mpd.active_pack() == "chat-h", reply[:80])

    # H4 卸载热路径兜底：绕过端点直接删注册表+文件 → ensure 先回收再报「未安装」
    proc2 = mpd._STATE["proc"]
    mps.remove_pack("chat-h")
    try:
        await mpd.ensure_server("chat-h")
        check("H4a 卸载后 ensure → LlamaServerError", False, "未抛错")
    except mpd.LlamaServerError as e:
        check("H4a 卸载后 ensure → 报错含未安装", "未安装" in str(e), str(e)[:160])
    check("H4b 卸载后进程被回收", proc2.poll() is not None)
    check("H4c 卸载后无活动包", mpd.active_pack() is None)
    _fresh_state()


def test_disable_uninstall_endpoints(fake: Path):
    """端点层：禁用/卸载正在服务的 chat 包 → 端点即停进程（缺陷 B 与禁用对齐语义）。"""
    from sidecar import app as appmod
    from fastapi.testclient import TestClient
    from sidecar.model_packs.mp_connector import ModelPackageConnector
    from sidecar.ollama.connector import OllamaAPIError

    os.environ["VETARAI_LLAMA_SERVER"] = str(fake)
    appmod.get_config = lambda: {
        **_cs.DEFAULT_CONFIG,
        "network_switch": "auto", "egress_proxy_required": [],
    }
    _install_fake_pack("chat-ep")
    _fresh_state()

    with TestClient(appmod.app) as client:
        # H5 禁用端点：服务中禁用 → 200 且进程即停；重新启用 → 200
        asyncio.run(mpd.ensure_server("chat-ep"))
        proc = mpd._STATE["proc"]
        r = client.post("/api/model-packs/chat-ep/toggle", json={"enabled": False})
        check("H5a toggle 禁用 → 200 enabled=False",
              r.status_code == 200 and r.json().get("enabled") is False, r.text[:160])
        check("H5b 禁用端点即停进程", proc.poll() is not None)
        check("H5c 禁用端点后无活动包", mpd.active_pack() is None)
        r = client.post("/api/model-packs/chat-ep/toggle", json={"enabled": True})
        check("H5d 重新启用 → 200 enabled=True",
              r.status_code == 200 and r.json().get("enabled") is True, r.text[:160])

        # H6 卸载端点：服务中卸载 → 200 且进程即停（不再孤儿常驻）
        asyncio.run(mpd.ensure_server("chat-ep"))
        proc2 = mpd._STATE["proc"]
        r = client.delete("/api/model-packs/chat-ep")
        check("H6a 卸载 → 200 deleted",
              r.status_code == 200 and r.json().get("deleted") is True, r.text[:160])
        check("H6b 卸载端点即停进程", proc2.poll() is not None)
        check("H6c 卸载端点后无活动包", mpd.active_pack() is None)

    # H6d 卸载后对话 → OllamaAPIError(400) 含未安装（端点 4xx 语义来源）
    async def _chat_after_delete():
        conn = ModelPackageConnector()
        try:
            await conn.chat("chat-ep", [{"role": "user", "content": "hi"}])
            return None
        except OllamaAPIError as e:
            return e
    err = asyncio.run(_chat_after_delete())
    check("H6d 卸载后对话 → 400 含未安装",
          err is not None and err.status_code == 400 and "未安装" in str(err),
          str(err)[:160] if err else "未抛错")
    _fresh_state()


# ══════════ G. 真实 GGUF E2E（skip-if-absent，m31/m32 先例）══════════

async def test_real_e2e():
    """真实 llama-server + 真实小 GGUF 全链路。缺二进制或缺模型即 SKIP（不算失败）。

    触发条件（两个都要）：
      * 二进制：env VETARAI_TEST_LLAMA_SERVER 或 ~/.subagent/drivers/llama-server
        （注意：本套件 data_root 已隔离到 TMP，默认解析链找不到真实 drivers，故读真实家目录）
      * 模型：env VETARAI_TEST_GGUF 指向一个小 GGUF
    """
    candidates = [os.environ.get("VETARAI_TEST_LLAMA_SERVER", "").strip(),
                  str(Path.home() / ".subagent" / "drivers" / "llama-server")]
    binary = next((Path(c) for c in candidates
                   if c and Path(c).is_file() and os.access(c, os.X_OK)), None)
    gguf = Path(os.environ.get("VETARAI_TEST_GGUF", "")) if os.environ.get("VETARAI_TEST_GGUF") else None
    if binary is None:
        print("SKIP  G 真实 E2E：无 llama-server 二进制（VETARAI_TEST_LLAMA_SERVER 或 "
              "~/.subagent/drivers/llama-server）")
        return
    if gguf is None or not gguf.is_file():
        print("SKIP  G 真实 E2E：无测试 GGUF（VETARAI_TEST_GGUF 未指或不存在）")
        return
    print(f"真实 E2E 启动: binary={binary} gguf={gguf}")
    os.environ["VETARAI_LLAMA_SERVER"] = str(binary)
    _fresh_state()
    pack = _install_fake_pack("e2e-real", context_length=512)
    # 用真实 GGUF 替换占位权重（软链，避免拷贝大文件）
    real_gguf = mps.pack_dir("e2e-real") / "model.gguf"
    real_gguf.unlink()
    real_gguf.symlink_to(gguf)
    pack["files"][0]["size_bytes"] = gguf.stat().st_size
    pack["size_bytes"] = gguf.stat().st_size
    from sidecar.model_packs.mp_connector import ModelPackageConnector
    conn = ModelPackageConnector()
    try:
        reply = await conn.chat("e2e-real", [{"role": "user", "content": "你好，回复一个字即可"}],
                                read_timeout_s=180)
        check("G1 真实 GGUF 对话有回复", bool(reply and reply.strip()), reply[:120])
        events = []
        async for ev in conn.chat_stream("e2e-real", [{"role": "user", "content": "hi"}]):
            events.append(ev)
        check("G2 真实 GGUF 流式有增量+done",
              any("content_delta" in e for e in events) and any(e.get("done") for e in events),
              str(events)[:200])
    finally:
        await conn.unload_model("e2e-real")
        check("G3 E2E 后卸载即停", mpd.active_pack() is None)
        _fresh_state()


# ══════════ main ══════════

def main():
    # 子进程日志改指 TMP（不写仓库 logs/；驱动对路径的使用不变）
    log_dir = TMP / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    mpd._server_log_path = lambda pid: log_dir / f"llama-server-{pid}.log"

    fake = _setup_fake_server()
    test_manifest_context_length()
    test_binary_resolution(fake)
    asyncio.run(test_spawn_args(fake))
    asyncio.run(test_lifecycle(fake))
    asyncio.run(test_connector())
    test_endpoints()
    asyncio.run(test_disable_uninstall_semantics(fake))
    test_disable_uninstall_endpoints(fake)
    asyncio.run(test_real_e2e())

    print(f"\n===== 0.4.29-P2 llama.cpp 驱动专项: PASS={PASS} FAIL={FAIL} =====")
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
