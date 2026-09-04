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
"""checkpoint-070 附着图片每轮重发回归测试。
修复背景（用户实测）：用户附着聊天截图让多模态模型转写，模型第二轮调用 read_file 后，
原只发第一轮的附着图片被丢弃，模型只剩磁盘上 read_file 的图，转写错误对象（把营业执照当聊天截图）。
覆盖：附着图片在 round1 和 round2（工具调用后）都传给连接器。
venv 内 python test_checkpoint070.py 直接跑。
"""
import asyncio
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


class ImgCaptureConn:
    """记录每轮收到的 images 参数；第一轮发 read_file 工具调用，第二轮直接完成。"""
    def __init__(self):
        self.calls = 0
        self.received_images = []  # 每轮 images 列表

    async def chat_stream(self, model, messages, tools=None, images=None):
        self.calls += 1
        self.received_images.append(list(images or []))
        if self.calls == 1:
            # 第一轮：模型先"看"附着图，但选择调 read_file 读磁盘图
            yield {"content_delta": "我来读取图片"}
            yield {"tool_calls": [{"id": "t1", "function": {"name": "read_file",
                  "arguments": json.dumps({"path": "some_file.txt"})}}]}
            yield {"done": True, "counts": {}}
        else:
            yield {"content_delta": "转写结果"}
            yield {"done": True, "counts": {}}


async def main():
    TMP = Path(tempfile.mkdtemp(prefix="c070_"))
    from sidecar.agent_engine.loop import run_tool_loop, tools_spec

    # 造一个真实磁盘文件供 read_file 成功（避免 not_a_file 干扰）
    (TMP / "some_file.txt").write_text("磁盘文件内容", encoding="utf-8")

    ATTACHED = ["data:image/png;base64,QUJD"]  # 用户附着图片
    conn = ImgCaptureConn()
    evs = []
    async for ev in run_tool_loop("m", [{"role": "user", "content": "转写"}], tools_spec(),
                                  str(TMP), max_rounds=5, connector=conn,
                                  first_round_images=ATTACHED):
        evs.append(ev)

    r1, r2 = conn.received_images[0], conn.received_images[1]
    check("70a 第1轮收到附着图片", ATTACHED[0] in r1, f"round1 images={r1}")
    check("70b 第2轮(工具调用后)仍收到附着图片", ATTACHED[0] in r2,
          f"round2 images={r2}（若为空=附着图片丢失，会转写错误对象）")

    # 清理
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
    check("临时目录已清理", not TMP.exists())

    print(f"\n===== checkpoint-070: PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
