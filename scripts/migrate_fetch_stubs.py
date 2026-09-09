#!/usr/bin/env python3
"""第 0 批（0.4.14）动作二：把测试里的 fetch 桩从 `as any` 迁移到类型化 helper。

⛔ 为什么要迁移（不是风格洁癖，是安全网可信度问题）：
  旧写法 `mockImplementation((async (url:any, init?:any) => {...}) as any)` 里的 `as any`
  把 fetch 的返回类型整个擦掉 → tsc 完全不检查这个桩。于是两类分歧可以静默存在：
    ① 假 response 对象缺成员（真实代码读 res.text()/statusText/body.getReader()，
       桩里没有）→ 运行时才炸，或被 catch 吞掉走错分支，**测试假绿**；
    ② 参数签名分歧（真实 fetch(url,{method,body,signal})，桩只写 (url)）。
  迁移后 route 必须返回原生 `Response`（已实测 jsdom/node 具备），`as any` 消失，
  任何缺成员/类型不符都在 **tsc 阶段**报错。已用 zz_proof2 实验证明：
  手写假对象触发 TS2322，而 as any 写法静默放过；canary 实验证明 tsc 确实检查 __tests__。

本脚本只处理**规律形态**（普查：82 处 `{ ok, status, json: async () => X }`）。
含 SSE body / text / headers 的特殊桩会跳过并报告，由人工迁移。

用法：
  python3 scripts/migrate_fetch_stubs.py --check      # 只报告，不写盘
  python3 scripts/migrate_fetch_stubs.py --apply      # 实际改写
  python3 scripts/migrate_fetch_stubs.py --apply --only taskPanel
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "renderer" / "src" / "__tests__"
HELPER_REL = "./helpers/fetchMock"

# 含这些**手写假 response 特征**的桩不由脚本处理（需人工用 sseRes / 原生 Response）。
# ⛔ 必须写得精确，不能只匹配裸 `body:` / `headers:`：
#   - 裸 `body:` 会误伤 `puts.push({ url, body: JSON.parse(...) })` 这类**记录请求体**的普通对象；
#   - 裸 `headers:` 会误伤 `new Response(stream, { headers: {...} })` —— 那已是**正确写法**。
#   误判后果是整块被跳过、`as any` 残留（实测 m5 / checkpoint058 各漏 1~2 处）。
# 真正需要人工的特征只有：手写对象把 body/text/statusText 当作 **response 成员**返回。
SPECIAL_MARKERS = (
    "body: stream",              # 手写流式假 response
    "body: new ReadableStream",
    "text: async () =>",         # 手写 text 成员
    "statusText:",               # 手写 statusText 成员
)

SPY_OPEN = re.compile(
    r"vi\.spyOn\(globalThis,\s*'fetch'\)\.mockImplementation\(\(async\s*\(([^)]*)\)\s*=>\s*\{"
)

# 形态 B：表达式体箭头函数 —— `(async () => ({ ok, status, json: async () => X })) as any`
# 无 `{` 函数体，故 SPY_OPEN 匹配不到（试点 taskPanel 实测漏掉 4 处）。
# 这类形态返回真实 Response 后**连 as any 都不需要**（已实验验证：tsc 0 错），
# 故直接内联重写为 `mockImplementation(async (params) => jsonRes(X))`，比块体形态更简洁。
SPY_EXPR = re.compile(
    r"vi\.spyOn\(globalThis,\s*'fetch'\)\.mockImplementation\(\(async\s*\(([^)]*)\)\s*=>\s*\("
)


def find_block_end(s: str, brace_start: int) -> tuple[int, int] | None:
    """从 `=> {` 的 `{` 位置起找到配对 `}`。

    返回 (闭合花括号下标, 整条语句结束下标即 `) as any);` 之后)。
    ⛔ 必须返回闭合括号下标：调用方要用它切出箭头函数体 inner。
    此前只返回语句末尾，导致 inner 被切成空串、json 字面量一个都替换不掉。
    """
    depth = 0
    i = brace_start
    n = len(s)
    while i < n:
        c = s[i]
        if c in "\"'`":                     # 跳过字符串/模板串
            q = c
            i += 1
            while i < n and s[i] != q:
                if s[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "/":   # 行注释
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "*":   # 块注释
            i += 2
            while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                # 期望紧跟 ") as any);"
                tail = s[i + 1 : i + 40]
                m = re.match(r"\s*\)\s*as\s+any\s*\)\s*;", tail)
                if m:
                    return i, i + 1 + m.end()
                return None
        i += 1
    return None


def extract_json_arg(s: str, start: int) -> tuple[str, int] | None:
    """从 `json: async () => ` 之后提取实参 X（支持嵌套括号/对象/数组/字符串）。

    返回 (X文本, 结束位置)。X 形如 `TASKS`、`({})`、`[{ id: 'a1' }]`。
    """
    i = start
    n = len(s)
    depth = 0
    begun = False
    while i < n:
        c = s[i]
        if c in "\"'`":
            q = c
            begun = True
            i += 1
            while i < n and s[i] != q:
                if s[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if c in "([{":
            depth += 1
            begun = True
        elif c in ")]}":
            if depth == 0:
                break          # 撞到外层结构（如 response 字面量的 }）→ X 结束
            depth -= 1
            if depth == 0 and begun:
                return s[start : i + 1].strip(), i + 1
        elif c == "," and depth == 0 and begun:
            return s[start:i].strip(), i
        elif not c.isspace() and depth == 0:
            begun = True
        i += 1
    return (s[start:i].strip(), i) if begun else None


def transform_json_literals(body: str) -> tuple[str, int]:
    """把 body 里所有 `{ ok: true, status: N, json: async () => X }` 换成 `jsonRes(X)`。"""
    out: list[str] = []
    pos = 0
    count = 0
    pat = re.compile(r"\{\s*ok:\s*(true|false)\s*,\s*status:\s*(\d+)\s*,\s*json:\s*async\s*\(\)\s*=>\s*")
    while True:
        m = pat.search(body, pos)
        if not m:
            out.append(body[pos:])
            break
        out.append(body[pos : m.start()])
        arg, end = extract_json_arg(body, m.end())
        if arg is None:
            out.append(body[m.start() : m.end()])
            pos = m.end()
            continue
        # 吃掉 X 之后到 response 字面量闭合 } 的部分
        j = end
        while j < len(body) and body[j].isspace():
            j += 1
        if j < len(body) and body[j] == "}":
            j += 1
        else:
            # 结构不符预期 → 保守跳过，不改写
            out.append(body[m.start() : m.end()])
            pos = m.end()
            continue
        ok, status = m.group(1), m.group(2)
        # 规整参数：原桩 `json: async () => ({...})` 里的 `({...})` 是箭头函数返回
        # 对象字面量**必须**的外层括号；但传给 jsonRes(...) 后它就多余了 → 剥掉，
        # 使 `jsonRes(({}))` 变 `jsonRes({})`、`jsonRes(({a:1}))` 变 `jsonRes({a:1})`。
        arg = re.sub(r"^\((\{.*\}|\[.*\])\)$", r"\1", arg.strip(), flags=re.S)
        if ok == "true" and status == "200":
            out.append(f"jsonRes({arg})")
        else:
            out.append(f"jsonRes({arg}, {status})")
        count += 1
        pos = j
    return "".join(out), count


def find_expr_end(s: str, paren_start: int) -> tuple[int, int, int] | None:
    """形态 B：从 `(async () => (` 的**内层** `(` 起找到配对 `)`，
    再确认其后紧跟 `) as any);`。

    返回 (内层表达式体起点, 内层表达式体终点, 整条语句结束下标)。
    """
    depth = 0
    i = paren_start
    n = len(s)
    while i < n:
        c = s[i]
        if c in "\"'`":
            q = c
            i += 1
            while i < n and s[i] != q:
                if s[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                tail = s[i + 1 : i + 40]
                m = re.match(r"\s*\)\s*as\s+any\s*\)\s*;", tail)
                if m:
                    return paren_start + 1, i, i + 1 + m.end()
                return None
        i += 1
    return None


def migrate_file(path: Path, apply: bool) -> dict:
    s = path.read_text(encoding="utf-8")
    report = {"file": path.name, "spies": 0, "json_literals": 0, "skipped_special": 0, "changed": False}

    result: list[str] = []
    pos = 0
    impl_idx = 0
    while True:
        # 两种形态都要找，取**位置靠前**的那个处理（否则同文件混用时会漏改或改错）
        mA = SPY_OPEN.search(s, pos)   # 形态 A：块体 `=> { ... }`
        mB = SPY_EXPR.search(s, pos)   # 形态 B：表达式体 `=> ({...})`
        if not mA and not mB:
            result.append(s[pos:])
            break
        use_B = (not mA) or (mB and mB.start() < mA.start())
        m = mB if use_B else mA

        if use_B:
            found = find_expr_end(s, m.end() - 1)   # m.end()-1 指向内层 `(`
            if found is None:
                result.append(s[pos : m.end()])
                pos = m.end()
                continue
            body_start, body_end, end = found
            expr = s[body_start:body_end]
            report["spies"] += 1
            if any(k in expr for k in SPECIAL_MARKERS):
                report["skipped_special"] += 1
                result.append(s[pos:end])
                pos = end
                continue
            new_expr, n_lit = transform_json_literals(expr)
            report["json_literals"] += n_lit
            params = re.sub(r":\s*any", "", m.group(1)).strip()
            # 形态 B 返回真实 Response 后**连 as any 都不需要**（已实验验证 tsc 0 错），
            # 故直接内联，比块体形态更简洁：mockImplementation(async (params) => jsonRes(X))
            arg_str = f"{params}" if params else ""
            rebuilt = (
                f"vi.spyOn(globalThis, 'fetch').mockImplementation("
                f"async ({arg_str}) => {new_expr.strip()});"
            )
            result.append(s[pos : m.start()])
            result.append(rebuilt)
            pos = end
            report["changed"] = True
            continue

        brace_start = m.end() - 1        # 指向 `{`
        found = find_block_end(s, brace_start)
        if found is None:
            result.append(s[pos : m.end()])
            pos = m.end()
            continue
        brace_end, end = found
        # ⛔ 函数体 = `{` 之后到配对 `}` 之前。此前误写成 s[m.end():brace_start]
        # （m.end() 已越过 `{`，而 brace_start = m.end()-1）→ 切出**空串**，
        # 导致 json 字面量一个都替换不掉（spy 计数正常但替换数恒为 0）。
        inner = s[brace_start + 1 : brace_end]
        report["spies"] += 1

        # 特殊形态（SSE body / headers / statusText）→ 跳过，交人工
        if any(k in inner for k in SPECIAL_MARKERS):
            report["skipped_special"] += 1
            result.append(s[pos:end])
            pos = end
            continue

        new_inner, n_lit = transform_json_literals(inner)
        report["json_literals"] += n_lit

        # 参数：保留原名，去掉 `: any`（typeof fetch 会推断出正确类型）
        params = m.group(1)
        params = re.sub(r":\s*any", "", params).strip()
        impl_idx += 1
        name = "impl" if impl_idx == 1 else f"impl{impl_idx}"
        # 缩进：spy 语句所在行的缩进（用于闭合行与后续 vi.spyOn 行）
        line_start = s.rfind("\n", 0, m.start()) + 1
        indent = s[line_start : m.start()]
        if indent.strip() != "":
            indent = ""
        # ⛔ 不要给首行前置 indent：`s[pos:m.start()]` 里**已经**含该行的缩进空白，
        # 再前置一次会变成双倍缩进（试点实测 4→8 空格）。
        # ⛔ `};` 前也不加 indent：new_inner 本身就以 "\n<缩进>" 结尾（原 `}` 前的空白）。
        rebuilt = (
            f"const {name}: typeof fetch = async ({params}) => {{"
            f"{new_inner}"
            f"}};\n"
            f"{indent}vi.spyOn(globalThis, 'fetch').mockImplementation({name});"
        )
        result.append(s[pos : m.start()])
        result.append(rebuilt)
        pos = end
        report["changed"] = True

    new_s = "".join(result)

    if report["changed"]:
        # 补 import（若缺）
        if HELPER_REL not in new_s:
            needed = ["jsonRes"]
            imp = f"import {{ {', '.join(needed)} }} from '{HELPER_REL}';\n"
            # 插到最后一条 import 之后
            imports = list(re.finditer(r"^import .+?;\s*$", new_s, re.M | re.S))
            if imports:
                last = imports[-1]
                new_s = new_s[: last.end()] + "\n" + imp + new_s[last.end() :]
            else:
                new_s = imp + new_s
        if apply:
            path.write_text(new_s, encoding="utf-8")

    return report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="实际写盘（默认只报告）")
    ap.add_argument("--only", default="", help="只处理文件名含该子串的")
    args = ap.parse_args()

    files = sorted(p for p in TESTS.glob("*.test.ts*"))
    if args.only:
        files = [f for f in files if args.only in f.name]

    tot = {"spies": 0, "json_literals": 0, "skipped_special": 0, "changed": 0}
    for f in files:
        r = migrate_file(f, args.apply)
        if r["spies"] or r["skipped_special"]:
            print(f"{'[写]' if args.apply else '[查]'} {r['file']:<34} "
                  f"spy={r['spies']} json字面量={r['json_literals']} 跳过特殊={r['skipped_special']}")
        tot["spies"] += r["spies"]
        tot["json_literals"] += r["json_literals"]
        tot["skipped_special"] += r["skipped_special"]
        tot["changed"] += 1 if r["changed"] else 0
    print("-" * 70)
    print(f"合计：处理 spy {tot['spies']} 处，替换 json 字面量 {tot['json_literals']} 处，"
          f"跳过特殊形态 {tot['skipped_special']} 处，涉及文件 {tot['changed']} 个")
    if not args.apply:
        print("（--check 模式，未写盘；确认无误后加 --apply）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
