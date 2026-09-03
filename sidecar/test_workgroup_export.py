"""TS-121（0.3.1 补遗2）：工作组 JSON 导出测试。

覆盖：
  X1 导出文件生成且 JSON 可解析
  X2 内容含项目/agents/会话消息/任务队列/圆桌
  X3 项目不存在 → ValueError
  X4 归档消息也随 JSON 导出（JSON 是完整数据快照，与 MD 占位策略不同）

隔离：store 指到临时目录，不碰真实 ~/.subagent。
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

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
    tmp = Path(tempfile.mkdtemp(prefix="ck_wg_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp
    store._GDB = tmp / "_global.db"

    from sidecar.exporter import export_workgroup_json

    # 建项目 + agent + 会话消息
    pid = store.create_project("测试工作组", str(tmp / "wd"))
    aid = store.add_agent_config(pid, "主", "main", model="m")
    sid = store.create_session(pid, aid)
    store.save_message(pid, sid, aid, "user", "记住数字12")
    store.save_message(pid, sid, aid, "assistant", "好的，12")
    m_ids = [m["id"] for m in store.load_messages(pid, sid)]
    store.archive_messages(pid, m_ids[:1])  # 归档一条，验证 JSON 仍含完整快照

    # X1/X2/X4
    res = export_workgroup_json(pid)
    p = Path(res["path"])
    check("X1a 导出文件存在", p.is_file(), str(p))
    data = json.loads(p.read_text(encoding="utf-8"))
    check("X2a 含项目元信息", data.get("project", {}).get("id") == pid)
    check("X2b 含 agent 与会话消息",
          any(a.get("id") == aid and a.get("sessions") for a in data.get("agents", [])),
          str([a.get("id") for a in data.get("agents", [])]))
    msgs = [m for a in data["agents"] for s in a.get("sessions", []) for m in s.get("messages", [])]
    check("X2c 消息条数齐全", len(msgs) == 2, str(len(msgs)))
    check("X4 归档消息仍在 JSON 快照（带 archived 标记）",
          any(m.get("archived") for m in msgs), str([m.get("archived") for m in msgs]))
    check("X2d 含任务队列与圆桌字段", "task_queue" in data and "roundtables" in data)

    # X3 不存在项目
    try:
        export_workgroup_json("nope")
        check("X3 不存在项目报错", False, "未抛错")
    except ValueError:
        check("X3 不存在项目报错", True)

    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
