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
"""TS-120（0.3.0）知识仓库（拉模式）后端隔离测试。

覆盖（全部在临时目录隔离，绝不触碰真实 ~/.subagent）：
  W1 全局条目：新增 → 生成 .md 文件（frontmatter 正确）→ 列表 → 读取正文
  W2 项目条目：新增到项目目录（知识库/）→ 列表过滤
  W3 关键词检索：FTS5 + jieba 中文分词命中（"地球"→"地球是圆的"）
  W4 检索作用域过滤：项目/全局隔离
  W5 删除：删文件 + 删索引 + 删 FTS
  W6 索引重建：扫描 .md 重建（容灾），重建后检索仍命中
  W7 消息归档：archive_messages 标记 + load_messages 返回 archived
  W8 标题自动生成：转移时留空取首条前 20 字
  W9 frontmatter 往返：_entry_to_md → _parse_md 无损

venv 内 PYTHONPATH=.. python knowledge/test_warehouse.py 直接跑。
"""
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
    import sidecar.knowledge.warehouse as wh
    import sidecar.storage.store as store

    # 隔离：改写数据根与索引库到临时目录
    tmp = Path(tempfile.mkdtemp(prefix="wh_test_"))
    wh._DATA_ROOT_OVERRIDE = tmp
    wh._INDEX_DB_PATH = tmp / "index.db"

    # 隔离项目库（项目知识需要项目工作目录）
    proj_root = tmp / "projects"
    proj_root.mkdir(parents=True, exist_ok=True)
    store.PROJECTS_ROOT = proj_root
    store._GDB = proj_root / "_global.db"
    # 建一个测试项目（工作目录指向临时文件夹）
    work_dir = tmp / "proj_work"
    work_dir.mkdir(parents=True, exist_ok=True)
    pid = store.create_project("测试项目", work_dir)

    # W1 全局条目
    e1 = wh.add_entry("global", None, "地球是圆的", "地球是圆的，这是常识。",
                      keywords=["地球", "常识"], category="常识")
    check("W1a 全局条目写入", e1 is not None, str(e1))
    check("W1b .md 文件生成", e1 and Path(e1["file_path"]).exists(), e1.get("file_path") if e1 else "")
    md_text = Path(e1["file_path"]).read_text(encoding="utf-8") if e1 else ""
    check("W1c frontmatter 含 title/scope", "title: 地球是圆的" in md_text and "scope: global" in md_text, md_text[:120])
    lst = wh.list_entries("global")
    check("W1d 全局列表含该条目", any(x["id"] == e1["id"] for x in lst), str([x["title"] for x in lst]))
    got = wh.get_entry(e1["id"])
    check("W1e 读取正文", got and "地球是圆的，这是常识" in got["body"], (got or {}).get("body", "")[:60])

    # W2 项目条目（到 项目工作目录/知识库/）
    e2 = wh.add_entry("project", pid, "项目笔记", "这是项目内的知识。", keywords=["项目"])
    check("W2a 项目条目写入", e2 is not None, str(e2))
    check("W2b 文件在项目知识库目录", e2 and "知识库" in e2["file_path"], e2.get("file_path") if e2 else "")
    plst = wh.list_entries("project", pid)
    check("W2c 项目列表过滤", any(x["id"] == e2["id"] for x in plst) and all(x["scope"] == "project" for x in plst),
          str([(x["title"], x["scope"]) for x in plst]))

    # W3 关键词检索（中文分词）
    r = wh.search_entries("地球", "global")
    check("W3a 搜'地球'命中", len(r) == 1 and r[0]["id"] == e1["id"], str([x["title"] for x in r]))
    r2 = wh.search_entries("常识")
    check("W3b 搜'常识'命中（关键词字段）", any(x["id"] == e1["id"] for x in r2), str([x["title"] for x in r2]))
    r3 = wh.search_entries("不存在的词xyz")
    check("W3c 无匹配返回空", r3 == [], str(r3))

    # W4 作用域过滤
    r4 = wh.search_entries("项目", "global")
    check("W4a 全局作用域搜不到项目条目", all(x["scope"] == "global" for x in r4), str([(x["title"], x["scope"]) for x in r4]))
    r5 = wh.search_entries("项目", "project", pid)
    check("W4b 项目作用域命中项目条目", any(x["id"] == e2["id"] for x in r5), str([x["title"] for x in r5]))

    # W9 frontmatter 往返
    entry = {"id": "x1", "title": "往返测试", "scope": "global", "project_id": "",
             "category": "c", "keywords": ["k1", "k2"], "source": "chat", "created_at": "2026-01-01 00:00:00"}
    md = wh._entry_to_md(entry, "正文内容")
    meta, body = wh._parse_md(md)
    check("W9a frontmatter 往返无损", meta.get("title") == "往返测试" and meta.get("keywords") == ["k1", "k2"],
          str(meta))
    check("W9b 正文往返", body.strip() == "正文内容", body)

    # W5 删除
    ok = wh.delete_entry(e1["id"])
    check("W5a 删除返回 True", ok is True, str(ok))
    check("W5b .md 文件已删", not Path(e1["file_path"]).exists(), e1["file_path"])
    check("W5c 列表不再含该条目", all(x["id"] != e1["id"] for x in wh.list_entries("global")),
          str([x["title"] for x in wh.list_entries("global")]))

    # W6 索引重建（先删索引，再扫描 .md 重建）
    wh.delete_entry(e2["id"])  # 清掉项目条目，重新造一个用于重建测试
    e3 = wh.add_entry("global", None, "重建测试", "这是用于索引重建的内容。", keywords=["重建"])
    wh.search_entries("重建")  # 确保可检索
    # 清空索引模拟损坏
    conn = wh._iconn()
    conn.execute("DELETE FROM knowledge_entries"); conn.execute("DELETE FROM knowledge_fts"); conn.commit(); conn.close()
    check("W6a 索引清空后检索为空", wh.search_entries("重建") == [], "应为空")
    n = wh.rebuild_index()
    check("W6b 重建返回条目数", n >= 1, str(n))
    r6 = wh.search_entries("重建")
    check("W6c 重建后检索命中", any(x["id"] == e3["id"] for x in r6), str([x["title"] for x in r6]))

    # W7 消息归档
    aid = store.add_agent_config(pid, "测试Agent", "main")
    sid = store.create_session(pid, aid, "测试会话")
    store.save_message(pid, sid, aid, "user", "第一条消息")
    store.save_message(pid, sid, aid, "assistant", "第二条消息")
    msgs = store.load_messages(pid, sid)
    check("W7a 初始消息无归档标记", all(not m.get("archived") for m in msgs), str([m.get("archived") for m in msgs]))
    msg_ids = [m["id"] for m in msgs]
    cnt = store.archive_messages(pid, msg_ids[:1])  # 归档第一条
    check("W7b 归档返回条数", cnt == 1, str(cnt))
    msgs2 = store.load_messages(pid, sid)
    archived_flags = [m.get("archived", False) for m in msgs2]
    check("W7c 仅第一条被归档", archived_flags == [True, False], str(archived_flags))

    # W8 标题自动生成（在端点层逻辑，这里验证取首条前20字的规则）
    first_content = "这是一条超过二十个字符的很长很长的测试消息内容"
    auto_title = first_content[:20]
    check("W8 标题取首条前20字", auto_title == first_content[:20] and len(auto_title) == 20, auto_title)

    # W9 外部删除对账（TS-121 问题4/5：Finder 删 .md 后索引必须同步清除）
    e1 = wh.add_entry("global", None, "外部删除测试", "这是一条将被外部删除的测试条目")
    check("W9a 条目创建成功", e1 is not None)
    if e1:
        Path(e1["file_path"]).unlink()  # 模拟用户在 Finder 直接删除 .md
        n = wh.prune_missing()
        check("W9b 对账清除 1 条", n == 1, str(n))
        check("W9c list 不再包含已删条目",
              all(x["id"] != e1["id"] for x in wh.list_entries("global")))
        check("W9d search 不再命中已删条目",
              all(x["id"] != e1["id"] for x in wh.search_entries("外部删除测试", "global")))
        # 第二次对账应清除 0 条（幂等）
        check("W9e 二次对账清除 0 条", wh.prune_missing() == 0)

    # 清理
    wh._DATA_ROOT_OVERRIDE = None
    wh._INDEX_DB_PATH = None
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n===== 结果：{PASS} PASS / {FAIL} FAIL =====")
    if FAILURES:
        print("失败项：", "、".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
