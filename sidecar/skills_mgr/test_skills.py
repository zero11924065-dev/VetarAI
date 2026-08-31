"""TS-110 M4 Skill 模块单测（venv 内直接跑）。
覆盖：frontmatter 解析/CRUD/toggle/清单构建/非法名/本地安装。
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
    TMP = Path(tempfile.mkdtemp(prefix="m4sk_"))
    # 隔离技能目录：data_root 指向临时区
    import sidecar.config as cfgmod
    cfgmod.data_root = lambda: TMP / "dataroot"
    from sidecar.skills_mgr import manager as sm

    # ══ 1. frontmatter 解析 ══
    meta, body = sm._parse_frontmatter("---\nname: demo\ndescription: 示例技能\nenabled: true\n---\n\n正文内容")
    check("1a frontmatter 解析", meta == {"name": "demo", "description": "示例技能", "enabled": "true"}
          and body.strip() == "正文内容", f"{meta} | {body!r}")
    meta2, body2 = sm._parse_frontmatter("无 frontmatter 的纯文本")
    check("1b 无 frontmatter → 空 meta", meta2 == {} and body2 == "无 frontmatter 的纯文本")
    meta3, _ = sm._parse_frontmatter("---\nname: x\n没有闭合")
    check("1c 未闭合 frontmatter → 空 meta（降级）", meta3 == {})

    # ══ 2. 创建/读取 ══
    check("2a 创建技能", sm.create_or_update_skill("周报助手", "按模板生成周报", "# 步骤\n1. 收集数据", True) is True)
    sk = sm.read_skill("周报助手")
    check("2b 读取技能（名称/描述/正文/启用）",
          sk is not None and sk["name"] == "周报助手" and sk["description"] == "按模板生成周报"
          and "收集数据" in sk["content"] and sk["enabled"] is True, str(sk)[:200] if sk else "None")
    check("2c 非法名拒绝（路径字符）", sm.create_or_update_skill("../evil", "x", "y") is False)
    check("2d 非法名拒绝（超长）", sm.create_or_update_skill("a" * 65, "x", "y") is False)
    check("2e 读取不存在技能 → None", sm.read_skill("不存在") is None)

    # ══ 3. 列表 + 清单构建 ══
    sm.create_or_update_skill("翻译", "中英互译", "翻译指令", True)
    lst = sm.list_skills()
    check("3a 列表含两个技能", len(lst) == 2, str([s['dir_name'] for s in lst]))
    text = sm.build_skills_list_text()
    check("3b 清单含启用项（名称+描述）",
          "周报助手" in text and "按模板生成周报" in text and "翻译" in text, text)

    # ══ 4. toggle 禁用 → 清单不含 ══
    new_state = sm.toggle_skill("翻译")
    check("4a toggle 返回新状态 False", new_state is False)
    text2 = sm.build_skills_list_text()
    check("4b 禁用后不出现在清单", "翻译" not in text2 and "周报助手" in text2, text2)
    check("4c 禁用技能仍可读取（标记 enabled=False）",
          sm.read_skill("翻译") is not None and sm.read_skill("翻译")["enabled"] is False)
    sm.toggle_skill("翻译")  # 恢复

    # ══ 5. 更新 ══
    sm.create_or_update_skill("周报助手", "新描述", "新正文", True)
    sk2 = sm.read_skill("周报助手")
    check("5a 更新后内容覆盖", sk2["description"] == "新描述" and "新正文" in sk2["content"], str(sk2)[:150])

    # ══ 6. 本地路径安装 ══
    src = TMP / "skill_src"
    src.mkdir()
    (src / "SKILL.md").write_text(
        "---\nname: 外来技能\ndescription: 从目录安装\ntest\n---\n外来正文", encoding="utf-8")
    r = sm.install_skill_from_repo(str(src))
    check("6a 本地目录安装成功", r["ok"] is True and r["name"] == "外来技能", str(r))
    check("6b 安装后技能可读", sm.read_skill("外来技能") is not None)
    r2 = sm.install_skill_from_repo(str(src))
    check("6c 重复安装拒绝", r2["ok"] is False and "已存在" in r2["error"], str(r2))
    # 子目录含 SKILL.md
    src2 = TMP / "repo2"
    (src2 / "sub").mkdir(parents=True)
    (src2 / "sub" / "SKILL.md").write_text("---\nname: 子目录技能\ndescription: d\n---\nb", encoding="utf-8")
    r3 = sm.install_skill_from_repo(str(src2))
    check("6d 子目录 SKILL.md 可识别", r3["ok"] is True and r3["name"] == "子目录技能", str(r3))
    # 无 SKILL.md
    src3 = TMP / "empty_repo"
    src3.mkdir()
    r4 = sm.install_skill_from_repo(str(src3))
    check("6e 无 SKILL.md → 报错", r4["ok"] is False and "SKILL.md" in r4["error"], str(r4))

    # ══ 7. 删除 ══
    check("7a 删除技能", sm.delete_skill("翻译") is True)
    check("7b 删除后读取为 None", sm.read_skill("翻译") is None)
    check("7c 删除不存在 → False", sm.delete_skill("翻译") is False)

    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("测试临时目录已清理", not TMP.exists())

    print(f"\n===== M4 Skill 模块专项: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
