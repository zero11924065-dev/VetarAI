"""TS-110 M4 知识/记忆模块单测（venv 内直接跑）。
覆盖：目录定位/启用约定/拼接截断/记忆读写/禁止事项提取/降级。
只输出 PASS/FAIL 摘要。
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
    TMP = Path(tempfile.mkdtemp(prefix="m4km_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = TMP
    store._GDB = TMP / "_global.db"
    # 隔离全局记忆目录：config.data_root 指向临时区，绝不污染用户真实 ~/.subagent
    import sidecar.config as cfgmod
    cfgmod.data_root = lambda: TMP / "dataroot"
    from sidecar.knowledge import store_knowledge as km

    wd = TMP / "projwd"
    wd.mkdir()
    pid = store.create_project("km-proj", wd)

    # ══ 1. 目录定位 ══
    kdir = km.knowledge_dir(pid)
    check("1a 知识库目录=项目工作目录/knowledge",
          kdir is not None and kdir.resolve() == (wd / "knowledge").resolve(), str(kdir))
    check("1b 不存在的项目 → None", km.knowledge_dir("ghost-pid") is None)

    # ══ 2. 启用约定 + toggle ══
    check("2a 写入知识文件", km.write_knowledge(pid, "规范.md", "# 规范\n必须用中文回复") is True)
    check("2b 文件名非法拒绝（路径穿越）", km.write_knowledge(pid, "../evil.md", "x") is False)
    check("2c 文件名非法拒绝（非 .md）", km.write_knowledge(pid, "a.txt", "x") is False)
    items = km.list_knowledge(pid)
    check("2d 列表含新文件且默认启用",
          len(items) == 1 and items[0]["name"] == "规范.md" and items[0]["enabled"] is True, str(items))
    new_name = km.toggle_knowledge(pid, "规范.md")
    check("2e toggle 禁用 → 加 _ 前缀", new_name == "_规范.md", str(new_name))
    items = km.list_knowledge(pid)
    check("2f 禁用后 enabled=False", items[0]["enabled"] is False, str(items))
    check("2g 再 toggle 恢复启用", km.toggle_knowledge(pid, "_规范.md") == "规范.md")

    # ══ 3. build_knowledge_text ══
    km.write_knowledge(pid, "材料.md", "材料正文XYZ")
    km.write_knowledge(pid, "_不注入.md", "不应出现的内容")
    text = km.build_knowledge_text(pid)
    check("3a 拼接启用文件（含文件名标注）",
          "【规范.md】" in text and "必须用中文回复" in text and "材料正文XYZ" in text, text[:200])
    check("3b 禁用文件不注入", "不应出现的内容" not in text, text[:200])
    # 单文件截断
    km.write_knowledge(pid, "超长.md", "长" * 5000)
    text2 = km.build_knowledge_text(pid)
    seg = text2.split("【超长.md】")[-1].split("【")[0]
    check("3c 单文件超 4000 字截断标注",
          "（该文件超长已截断）" in text2 and len(seg) < 4200, str(len(seg)))
    # 无目录降级
    check("3d 不存在的项目降级空串", km.build_knowledge_text("ghost-pid") == "")

    # ══ 4. 记忆读写 ══
    check("4a 项目记忆写入", km.write_memory("project", "记住：用户叫小明", pid) is True)
    check("4b 项目记忆读取", "用户叫小明" in km.read_memory("project", pid))
    check("4c 项目记忆文件在项目工作目录", (wd / "memory.md").is_file())
    gpath = km._memory_path("global")
    check("4d 全局记忆写入数据目录", km.write_memory("global", "全局规则") is True
          and gpath is not None and gpath.is_file())
    check("4e 全局记忆读取", "全局规则" in km.read_memory("global"))
    check("4f 超长记忆截断保存", km.write_memory("project", "x" * 5000, pid) is True
          and "（超长已截断）" in km.read_memory("project", pid))
    # 恢复正常内容供后续用例
    km.write_memory("project", "记住：用户叫小明", pid)

    # ══ 5. 禁止事项提取 + 注入 ══
    km.write_memory("project",
                    "记住：用户叫小明。\n禁止讨论薪资话题。\n- 不得删除生产数据库。\n普通备注一行。\n严禁泄露密钥。",
                    pid)
    pros = km.extract_prohibitions(km.read_memory("project", pid))
    check("5a 禁止行提取（3 条，普通行排除）",
          len(pros) == 3 and "禁止讨论薪资话题。" in pros
          and "不得删除生产数据库。" in pros and "严禁泄露密钥。" in pros, str(pros))
    mem_text, pros2 = km.build_memory_injection(pid)
    check("5b 注入正文含项目记忆段", "【本项目记忆】" in mem_text and "用户叫小明" in mem_text, mem_text[:200])
    check("5c 注入含优先级说明", "以本项目记忆为准" in mem_text, mem_text[:200])
    check("5d 禁止事项随注入返回", len(pros2) == 3, str(pros2))
    # 全局+项目合并与冲突文案
    km.write_memory("global", "禁止夜间操作。\n全局备注。")
    mem_text2, pros3 = km.build_memory_injection(pid)
    check("5e 全局+项目记忆合并", "【全局记忆】" in mem_text2 and "【本项目记忆】" in mem_text2, mem_text2[:200])
    check("5f 禁止事项合并去重（4 条）", len(pros3) == 4, str(pros3))
    check("5g 异常降级（空项目 id 不抛错）", km.build_memory_injection(None) is not None)

    # ══ 6. 知识删除 ══
    check("6a 删除知识文件", km.delete_knowledge(pid, "材料.md") is True)
    check("6b 删除不存在的文件 → False", km.delete_knowledge(pid, "不存在.md") is False)
    check("6c 列表同步", all(i["name"] != "材料.md" for i in km.list_knowledge(pid)))

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M4 知识/记忆模块专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
