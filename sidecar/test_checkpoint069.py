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
"""checkpoint-069 路径自纠正与防幻觉修复回归测试。
覆盖：
- 相对路径双前缀自纠正（root 目录名被当相对前缀再叠一层 → 自动去首层重试）
- read_file/list_dir 报错信息含解析路径与沙盒根提示（供模型自纠正）
venv 内 python test_checkpoint069.py 直接跑。
"""
import asyncio
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from sidecar.tools.registry import execute


class PathSelfCorrectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="c069_"))
        # 构造沙盒根，根目录名与模型误传的相对前缀相同
        self.root = self.tmp / "测试材料"
        target = self.root / "测试存档" / "聊天文本_副本"
        target.mkdir(parents=True)
        (target / "记录.md").write_text("正确的翻录内容", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_double_prefix_self_correct(self):
        # 模型传 "测试材料/测试存档/..."（root 已是 .../测试材料）→ 应自纠正命中
        r = asyncio.run(execute("read_file", {"path": "测试材料/测试存档/聊天文本_副本/记录.md"}, self.root))
        self.assertTrue(r.get("ok"), f"双前缀应自纠正: {r}")
        self.assertIn("正确的翻录内容", r.get("content", ""))

    def test_normal_relative_path_still_works(self):
        r = asyncio.run(execute("read_file", {"path": "测试存档/聊天文本_副本/记录.md"}, self.root))
        self.assertTrue(r.get("ok"), f"正常相对路径: {r}")

    def test_missing_file_error_has_hints(self):
        r = asyncio.run(execute("read_file", {"path": "不存在的/文件.md"}, self.root))
        self.assertFalse(r.get("ok"))
        self.assertIn("沙盒根", r.get("error", ""))

    def test_list_dir_on_file_gives_read_hint(self):
        r = asyncio.run(execute("list_dir", {"path": "测试存档/聊天文本_副本/记录.md"}, self.root))
        self.assertFalse(r.get("ok"))
        self.assertIn("read_file", r.get("error", ""), "对文件 list_dir 应提示改用 read_file")


if __name__ == "__main__":
    unittest.main(verbosity=1)
