# VetarAI - Local-first multi-agent orchestration application
# Copyright (C) 2026 zero11924065-dev
# GPL-3.0-or-later（见仓库 LICENSE）
"""C7（0.4.18）专项：聊天附件落盘 + 会话级清理 + 文件名净化。

═══ 治的是什么 ═══
/api/attachments/parse 原本只解码→解析→返回，**全程 0 处写盘** → 附件只活在当轮请求内存里，
下一轮 agent 想再读原文件必然 not_a_file（用户报告"上传文件只当轮可读，后续会话读不到"）。

═══ 关键设计约束（勿凭直觉改）═══
1. ⛔ **文件名必须净化**：req.name 是用户可控输入，本项目此前**没有任何**文件名净化 helper
   （现有落盘处只 .strip()），直接拼路径会被 "../../" 穿越出附件目录。
2. ⛔ **落盘在 data_root 内、不写用户工作目录**：工作目录是用户 Finder 可见、自己管的地方；
   而 registry.py 明确"读取任何位置都不拦截"，故 data_root 下绝对路径 agent 照样能读。
3. ⛔ **截长必须保住扩展名**：C4/A10 靠扩展名分发解析器，截掉扩展名会退化成乱码读取。
4. ⛔ **同名不覆盖**：两份都保留（用户铁律：遇同名项先保留两边）。
5. ⛔ **只做"删会话连带清理"，不做定期清理**：定期清理无法判断文件是否仍被历史消息正文
   引用（正文里存着绝对路径），会误删仍在用的副本。
6. ⛔ **落盘失败不得让解析失败**：text 已解析出来才是主价值，路径是增益。
7. ⛔ **归属缺失时只解析不落盘、不报错**：新会话尚未创建时 session_id 可能为空，
   不能因此让用户传不了文件。

运行：.venv/bin/python -m sidecar.test_c7_attachment_persist
（⛔ 勿裸跑：走 scripts/run_backend_tests.py 隔离 runner）
"""
import io
import sys
import uuid
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
    from sidecar.storage import store as S
    from sidecar.config import data_root

    root = Path(data_root())
    check("T0 隔离生效：data_root 不是用户真实目录",
          ".subagent" not in str(root) or "tmp" in str(root).lower(), str(root))

    pid, sid = f"c7proj-{uuid.uuid4().hex[:6]}", f"c7sess-{uuid.uuid4().hex[:6]}"

    # ── T1 文件名净化：路径穿越必须挡住 ──
    sanitize = S._sanitize_attachment_name
    attacks = {
        "相对穿越": "../../etc/passwd",
        "绝对路径": "/etc/passwd",
        "Windows 穿越": "..\\..\\windows\\system32\\cmd.exe",
        "双点斜杠组合": "....//....//x",
        "NUL 字节": "a\x00b.txt",
        "纯空格": "   ",
        "父目录": "..",
        "当前目录": ".",
        "空串": "",
        "换行注入": "a\nrm -rf /.txt",
    }
    for desc, raw in attacks.items():
        out = sanitize(raw)
        safe = ("/" not in out and "\\" not in out and "\x00" not in out
                and out not in ("", ".", "..") and "\n" not in out)
        check(f"T1 净化挡住 {desc}", safe, f"{raw!r} -> {out!r}")

    # 正常名不得被破坏（中文名/括号/空格是真实场景）
    for good in ("normal.doc", "中文 报告（终版）.docx", "a.b.c.pdf"):
        check(f"T1 正常名保留 {good}", sanitize(good) == good, sanitize(good))

    # ⛔ 截长必须保住扩展名（C4/A10 靠扩展名分发）
    long_out = sanitize("x" * 300 + ".pdf")
    check("T1 超长名截断后仍以 .pdf 结尾", long_out.endswith(".pdf"), long_out[-8:])
    check("T1 超长名被限长", len(long_out) <= S._ATTACH_MAX_NAME_LEN, len(long_out))
    # 无扩展名的超长名也不该崩
    check("T1 无扩展名超长名不崩", len(sanitize("y" * 300)) <= S._ATTACH_MAX_NAME_LEN)

    # ── T2 落盘：位置 / 内容 / 归属隔离 ──
    d = S.attachments_dir(pid, sid)
    p1 = S.save_attachment(pid, sid, "报告.doc", b"DATA1")
    check("T2a 文件真实落盘", p1.exists() and p1.read_bytes() == b"DATA1", str(p1))
    check("T2b 返回绝对路径", p1.is_absolute(), str(p1))
    check("T2c 落盘在 data_root 内（不污染用户工作目录）",
          str(p1).startswith(str(root)), str(p1))
    check("T2d 路径含项目与会话归属", pid in str(p1) and sid in str(p1), str(p1))

    # 不同会话互不串目录
    sid2 = sid + "-other"
    p2 = S.save_attachment(pid, sid2, "报告.doc", b"DATA2")
    check("T2e 不同会话落不同目录", p1.parent != p2.parent, f"{p1.parent} vs {p2.parent}")
    check("T2f 跨会话内容不串", p1.read_bytes() == b"DATA1" and p2.read_bytes() == b"DATA2")

    # ⛔ 同名不覆盖：两份都保留
    p3 = S.save_attachment(pid, sid, "报告.doc", b"DATA3")
    check("T2g 同名不覆盖（新文件另起名）", p3 != p1 and p3.exists(), f"{p1} vs {p3}")
    check("T2h 同名保留旧文件内容", p1.read_bytes() == b"DATA1", p1.read_bytes())
    check("T2i 同名新文件内容正确", p3.read_bytes() == b"DATA3", p3.read_bytes())

    # 穿越名经净化后落盘仍在目录内（不能因为净化把文件写到别处）
    p4 = S.save_attachment(pid, sid, "../../../evil.txt", b"EVIL")
    check("T2j 穿越名落盘仍被限制在会话目录内",
          p4.exists() and p4.parent == d and str(p4).startswith(str(root)), str(p4))

    # ── T3 会话级清理 ──
    n_before = len(list(d.iterdir()))
    check("T3a 清理前目录有多个文件", n_before >= 3, n_before)
    removed = S.delete_session_attachments(pid, sid)
    check("T3b 返回删除条数与实际一致", removed == n_before, f"{removed} vs {n_before}")
    check("T3c 附件文件已全部删除", not d.exists() or not any(d.iterdir()), str(d))
    # 不影响别的会话
    check("T3d 不误删其他会话的附件", p2.exists() and p2.read_bytes() == b"DATA2", str(p2))
    # 幂等：重复清理不报错
    check("T3e 重复清理幂等返回 0", S.delete_session_attachments(pid, sid) == 0)
    check("T3f 清理不存在的会话不报错",
          S.delete_session_attachments("no-such-proj", "no-such-sess") == 0)

    # ── T4 端点契约（归属缺失 → 只解析不落盘、不报错）──
    import inspect
    src_app = Path(S.__file__).parent.parent / "app.py"
    app_src = src_app.read_text(encoding="utf-8")
    seg = app_src.split("async def api_parse_chat_attachment")[1].split("\n@app.")[0]
    check("T4a 端点带 project_id/session_id 入参",
          "project_id" in seg and "session_id" in seg)
    check("T4b 归属齐全才落盘（缺失时退回旧行为不报错）",
          "if pid and sid and raw:" in seg, "缺归属守卫")
    check("T4c 回传 saved_path", '"saved_path"' in seg or "saved_path" in seg)
    check("T4d 落盘失败降级（OSError 不让解析失败）", "except OSError" in seg)
    check("T4e 10MB 上限仍在（未因落盘放宽）", "_CHAT_ATT_MAX_BYTES" in seg)
    # ⛔ 删除会话端点必须在 delete_session **成功之后**才清理（404 时不得删文件）
    dseg = app_src.split("async def api_delete_session")[1].split("\n@app.")[0]
    ok_i = dseg.find("ok = delete_session")
    clean_i = dseg.find("delete_session_attachments")
    notfound_i = dseg.find('status_code=404')
    check("T4f 删除会话端点接入附件清理", clean_i > 0)
    check("T4g 清理在 delete_session 之后（404 分支前不删文件）",
          0 < ok_i < notfound_i < clean_i, f"ok={ok_i} 404={notfound_i} clean={clean_i}")

    # ── T5 前端契约：解析失败但有路径的文件不得被丢弃（C7 治本点）──
    fe = Path(__file__).resolve().parents[1] / "renderer/src/panels/ChatPanel.tsx"
    fe_src = fe.read_text(encoding="utf-8")
    check("T5a 前端不再只收 parsedText（旧 .filter(f => f.parsedText) 会丢掉无法解析的文件）",
          "f.parsedText || f.savedPath" in fe_src)
    check("T5b 正文写入原件绝对路径", "原件已保存" in fe_src and "savedPath" in fe_src)
    check("T5c 请求体带归属标识", "session_id: currentSessionIdRef.current" in fe_src)
    check("T5d PendingItem 有 savedPath 字段", "savedPath?: string" in fe_src)

    print(f"\n===== C7 专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        for f in FAILURES:
            print("  ✗", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
