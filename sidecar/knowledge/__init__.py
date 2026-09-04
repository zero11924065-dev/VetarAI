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
"""M4（TS-110）：知识与记忆模块包。"""
from sidecar.knowledge.store_knowledge import (
    knowledge_dir, list_knowledge, read_knowledge, write_knowledge,
    delete_knowledge, toggle_knowledge, build_knowledge_text,
    read_memory, write_memory, build_memory_injection, extract_prohibitions,
)

__all__ = [
    "knowledge_dir", "list_knowledge", "read_knowledge", "write_knowledge",
    "delete_knowledge", "toggle_knowledge", "build_knowledge_text",
    "read_memory", "write_memory", "build_memory_injection", "extract_prohibitions",
]
