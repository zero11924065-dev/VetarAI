"""M4（TS-110）：Skill 管理模块包。"""
from sidecar.skills_mgr.manager import (
    list_skills, read_skill, create_or_update_skill, delete_skill,
    toggle_skill, install_skill_from_repo, build_skills_list_text,
)

__all__ = [
    "list_skills", "read_skill", "create_or_update_skill", "delete_skill",
    "toggle_skill", "install_skill_from_repo", "build_skills_list_text",
]
