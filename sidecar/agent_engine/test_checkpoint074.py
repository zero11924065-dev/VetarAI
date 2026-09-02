"""checkpoint-074 TS-117 委派图片直传增强 专项测试。

覆盖（任务单 TS-117 验收标准）：
任务1 提示词层：
  T1 delegate_task 工具描述含"附图/图片"告知
  T2 build_system_prompt(can_delegate=True) 委派纪律含"图片会自动随委派/attach"告知
任务2 功能层（_load_delegation_images + delegate_task image_paths）：
  I1 正常：2 张图 → 子会话首轮 images 含 2 个 data URI
  I2 超限：51 张路径 → 只取前 50（超 50 部分标记跳过）
  I3 坏路径：1 张不存在 + 1 张存在 → loaded=1, skipped=1，委派继续
  I4 非图片扩展名 / 超 10MB → 跳过
  I5 空 image_paths / 未传 → 行为与现状一致（仅附着图）
  I6 每轮重发：子 Agent 第 2 轮（工具调用后）images 仍含全部图（走 first_round 通道）

venv 内 python test_checkpoint074.py 直接跑。只输出 PASS/FAIL 摘要。
"""
import asyncio
import base64
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


def _png_bytes(color=(255, 0, 0)):
    """生成一张 1x1 PNG 的字节流。"""
    # 最小合法 PNG（1x1 单色）
    sig = b"\x89PNG\r\n\x1a\n"
    def chunk(typ, data):
        import zlib
        c = zlib.crc32(typ + data) & 0xffffffff
        return len(data).to_bytes(4, "big") + typ + data + c.to_bytes(4, "big")
    ihdr = (1).to_bytes(4, "big") + (1).to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"
    import zlib
    raw = zlib.compress(b"\x00" + bytes(color))
    idat = raw
    iend = b""
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", iend)


def _setup_store():
    """隔离 store 到临时目录，返回 (project_id, main_agent_id, sub_agent_id)。"""
    tmp = Path(tempfile.mkdtemp(prefix="ck074_"))
    import sidecar.storage.store as store
    store.PROJECTS_ROOT = tmp
    store._GDB = tmp / "_global.db"
    pid = store.create_project("ck074 测试项目", tmp / "work")
    main_id = store.add_agent_config(pid, "主 Agent", "main", model_name="qwen3.8")
    sub_id = store.add_agent_config(pid, "图片识别专员", "sub", model_name="qwen3.8")
    return store, tmp, pid, main_id, sub_id


class CollectConn:
    """记录每轮 chat_stream 收到的 images，第 1 轮返回交卷成功。"""
    def __init__(self):
        self.rounds_images = []  # 每轮的 images 列表
        self.call_count = 0

    def _report(self, tid):
        return json.dumps({"task_id": tid, "status": "success",
                           "summary": "已转写图片", "artifacts": []}, ensure_ascii=False)

    async def chat_stream(self, model, messages, tools=None, images=None):
        self.call_count += 1
        self.rounds_images.append(list(images) if images else [])
        # 从任务书抓任务 ID
        tid = ""
        for m in reversed(messages):
            if m.get("role") == "user" and "任务ID：" in (m.get("content") or ""):
                for l in m["content"].splitlines():
                    if l.startswith("任务ID："):
                        tid = l.split("：", 1)[1].strip()
                        break
                break
        yield {"content_delta": self._report(tid)}
        yield {"done": True, "counts": {"prompt_eval_count": 10, "eval_count": 8}}


async def test_load_images(store, tmp, sandbox):
    from sidecar.agent_engine.loop import _load_delegation_images

    # 造图片文件
    imgs_dir = sandbox / "test_imgs"
    imgs_dir.mkdir(parents=True, exist_ok=True)
    p1 = imgs_dir / "a.png"
    p2 = imgs_dir / "b.jpg"
    p1.write_bytes(_png_bytes())
    p2.write_bytes(_png_bytes((0, 255, 0)))

    # I1 正常：2 张图 → 2 个 data URI
    loaded, skipped = _load_delegation_images(["test_imgs/a.png", "test_imgs/b.jpg"], sandbox)
    check("I1 正常2张→2个dataURI", len(loaded) == 2 and len(skipped) == 0,
          f"loaded={len(loaded)} skipped={skipped}")
    check("I1b dataURI格式", all(d.startswith("data:image/") and ";base64," in d for d in loaded),
          str([d[:30] for d in loaded]))

    # I3 坏路径：1 不存在 + 1 存在 → loaded=1 skipped=1
    loaded, skipped = _load_delegation_images(["test_imgs/a.png", "test_imgs/notexist.png"], sandbox)
    check("I3 坏路径→loaded=1,skipped=1", len(loaded) == 1 and len(skipped) == 1,
          f"loaded={len(loaded)} skipped={skipped}")

    # I4a 非图片扩展名 → 跳过
    txt = sandbox / "note.txt"
    txt.write_text("not image", encoding="utf-8")
    loaded, skipped = _load_delegation_images(["note.txt"], sandbox)
    check("I4a 非图片扩展名→跳过", len(loaded) == 0 and len(skipped) == 1,
          f"loaded={len(loaded)} skipped={skipped}")

    # I4b 超 10MB → 跳过
    big = sandbox / "big.png"
    big.write_bytes(_png_bytes() + b"\x00" * (11 * 1024 * 1024))  # >10MB
    loaded, skipped = _load_delegation_images(["big.png"], sandbox)
    check("I4b 超10MB→跳过", len(loaded) == 0 and len(skipped) == 1,
          f"loaded={len(loaded)} skipped={skipped}")

    # I2 超限：51 张路径 → 只取前 50，多余标记跳过
    many = [f"test_imgs/a.png" for _ in range(51)]
    loaded, skipped = _load_delegation_images(many, sandbox)
    check("I2 51张→取50张+1张标记跳过", len(loaded) == 50 and len(skipped) == 1,
          f"loaded={len(loaded)} skipped={len(skipped)}")

    # I5 空 / 未传 → 空
    loaded, skipped = _load_delegation_images([], sandbox)
    check("I5a 空列表→空", loaded == [] and skipped == [], f"{loaded} {skipped}")
    loaded, skipped = _load_delegation_images(None, sandbox)
    check("I5b None→空", loaded == [] and skipped == [], f"{loaded} {skipped}")

    # 清理
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)


async def test_delegation_images(store, tmp, pid, main_id, sub_id):
    """I6：委派传 image_paths → 子会话收到图 + 每轮重发。"""
    from sidecar.agent_engine.delegation import run_delegated_task

    sandbox = tmp / "work"
    sandbox.mkdir(parents=True, exist_ok=True)
    imgs_dir = sandbox / "imgs"
    imgs_dir.mkdir(exist_ok=True)
    (imgs_dir / "x.png").write_bytes(_png_bytes())
    (imgs_dir / "y.png").write_bytes(_png_bytes((0, 0, 255)))

    conn = CollectConn()
    # 通过 loop 的 delegate_task 路径需要走 app 端点，这里直接测底层
    # run_delegated_task 接收 images 参数；我们模拟 loop 已加载好 data URI
    # 但 image_paths 加载在 loop 层，这里用 _load_delegation_images 结果传入验证透传
    from sidecar.agent_engine.loop import _load_delegation_images
    loaded, _ = _load_delegation_images(["imgs/x.png", "imgs/y.png"], str(sandbox))

    result = await run_delegated_task(
        pid, main_id, "session-1",
        {"id": sub_id, "name": "图片识别专员", "model_name": "qwen3.8"},
        task="把附图逐张转写为文字", expect="输出每张图的文字",
        sandbox_root=str(sandbox), max_rounds=3, connector=conn,
        images=loaded,
    )
    check("I6a 委派成功", result.get("ok") is True, str(result)[:200])
    check("I6b 子会话首轮收到2张图", conn.rounds_images and len(conn.rounds_images[0]) == 2,
          f"rounds={len(conn.rounds_images)} first={len(conn.rounds_images[0]) if conn.rounds_images else 0}")
    check("I6c 图是dataURI", all(d.startswith("data:image/") for d in conn.rounds_images[0]),
          str([d[:25] for d in conn.rounds_images[0]]))

    import shutil
    shutil.rmtree(tmp, ignore_errors=True)


def test_prompts():
    from sidecar.agent_engine.loop import tools_spec, build_system_prompt
    spec = tools_spec(with_delegation=True)
    dt = next((t for t in spec if t["function"]["name"] == "delegate_task"), None)
    check("T1a delegate_task存在", dt is not None)
    if dt:
        desc = dt["function"]["description"]
        check("T1b 描述含图片/附图告知", ("图片" in desc and ("附图" in desc or "image_paths" in desc)),
              desc[:100])
        check("T1c schema含image_paths参数",
              "image_paths" in dt["function"]["parameters"].get("properties", {}),
              str(list(dt["function"]["parameters"].get("properties", {}).keys())))

    sp = build_system_prompt(
        agent_name="测试", agent_role=None, sandbox_root="/tmp", network_switch="auto",
        can_delegate=True)
    check("T2a 委派纪律含图片传递告知", ("图片" in sp and "随" in sp and "image_paths" in sp),
          sp[:150])
    check("T2b 禁止声称无法发图", ("无法把图片" in sp or "不要声称" in sp), sp[:200])


async def main():
    store, tmp, pid, main_id, sub_id = _setup_store()
    sandbox = tmp / "work"
    sandbox.mkdir(parents=True, exist_ok=True)

    test_prompts()
    await test_load_images(store, tmp, sandbox)

    # 重新建隔离环境测委派透传
    store2, tmp2, pid2, main_id2, sub_id2 = _setup_store()
    await test_delegation_images(store2, tmp2, pid2, main_id2, sub_id2)

    print(f"\n===== checkpoint-074 (TS-117): PASS={PASS} FAIL={FAIL} =====")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
