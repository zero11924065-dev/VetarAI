#!/usr/bin/env python3
"""一次性脚本（0.4.26，用户拍板方案B）：剥除业务代码注释/docstring 中的 ⛔/📌 emoji。

保留：可执行字符串字面量（Agent 提示词/用户可见文案）、测试文件、交接文档、脚本自身注释。
用法：python3 scripts/strip_emoji_b9.py          # dry-run，只报告
      python3 scripts/strip_emoji_b9.py --apply  # 实际改写
"""
import ast, glob, io, re, sys, tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EMOJI = re.compile(r'[⛔📌]+[ \t]?')

def strip_line(s: str) -> str:
    """剥 emoji 及其后随的一个空格；行尾空白收干净。"""
    return EMOJI.sub('', s).rstrip()

# ── 后端 .py：tokenize 精确区分 COMMENT / docstring / 普通字符串 ──
def py_spans(path: Path):
    """返回 (可剥的注释span列表, 跳过的字符串span列表)。span=(srow,scol,erow,ecol)"""
    src = path.read_text(encoding='utf-8')
    # ast 收集 docstring 的起始位置（模块/类/函数体第一个表达式字符串）
    doc_starts = set()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if isinstance(body, list) and body and isinstance(body[0], ast.Expr) \
           and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            doc_starts.add((body[0].value.lineno, body[0].value.col_offset))
    comments, skipped = [], []
    toks = list(tokenize.generate_tokens(io.StringIO(src).readline))
    for i, tok in enumerate(toks):
        if '⛔' not in tok.string and '📌' not in tok.string:
            continue
        if tok.type == tokenize.COMMENT:
            comments.append((tok.start, tok.end, tok.string))
        elif tok.type == tokenize.STRING:
            if tok.start in doc_starts:
                comments.append((tok.start, tok.end, tok.string))  # docstring 可剥
            else:
                skipped.append((tok.start, tok.string.splitlines()[0][:70]))  # Agent 字符串，保留
    return comments, skipped

def apply_py(path: Path, dry: bool):
    src = path.read_text(encoding='utf-8')
    lines = src.split('\n')
    comments, skipped = py_spans(path)
    changed = []
    for (srow, scol), (erow, ecol), text in comments:
        for r in range(srow, erow + 1):
            seg = lines[r - 1]
            a = scol if r == srow else 0
            b = ecol if r == erow else len(seg)
            if '⛔' not in seg[a:b] and '📌' not in seg[a:b]:
                continue
            new = seg[:a] + strip_line(seg[a:b])
            new = new.rstrip()
            # 整行注释被剥成空壳（只剩 # 或空白）→ 删整行
            if re.fullmatch(r'\s*#?\s*', new):
                new = None
            changed.append((r, lines[r - 1], new))
    if not dry:
        for r, old, new in changed:
            lines[r - 1] = new
        lines = [l for l in lines if l is not None]
        path.write_text('\n'.join(lines), encoding='utf-8')
    return changed, skipped

# ── 前端 .ts/.tsx：行分类（整行注释 / 块注释内部 / 行尾注释），字符串跳过 ──
def fe_changes(path: Path):
    lines = path.read_text(encoding='utf-8').split('\n')
    changed, skipped = [], []
    in_block = False
    for idx, ln in enumerate(lines, 1):
        if '⛔' not in ln and '📌' not in ln:
            # 块注释状态机仍要推进（块内可能无 emoji 行）
            if in_block and '*/' in ln:
                in_block = False
            elif not in_block and ('/*' in ln or '{/*' in ln):
                # 单行 /* ... */ 不含 emoji 则不进块
                op = ln.find('/*')
                if '*/' not in ln[op:]:
                    in_block = True
            continue
        s = ln.lstrip()
        if s.startswith('//') or s.startswith('/*') or s.startswith('{/*') or \
           (in_block and not s.startswith('"') and not s.startswith("'")):
            new = strip_line(ln)
            if re.fullmatch(r'\s*(//|/\*+|\*+|{/\*+)?\s*(\*/)?\s*}?', new):
                new = None  # 空壳注释行
            changed.append((idx, ln, new))
        elif '//' in ln:
            pos = ln.rfind('//')
            head, tail = ln[:pos], ln[pos:]
            # 行尾注释：// 前的代码段引号/反引号必须成对（防误伤字符串里的 //）
            if head.count('"') % 2 == 0 and head.count("'") % 2 == 0 and head.count('`') % 2 == 0:
                tail_new = strip_line(tail)
                # 保留代码与注释之间的原始对齐空白；注释剥空则整体去掉
                new = (head + tail_new).rstrip() if tail_new != '//' else head.rstrip()
                changed.append((idx, ln, new))
            else:
                skipped.append(((idx, 0), 'TRAIL-AMBIG ' + ln.strip()[:70]))
        else:
            skipped.append(((idx, 0), 'STRING? ' + ln.strip()[:70]))
        # 状态机推进（本行处理后）
        if in_block and '*/' in ln:
            in_block = False
        elif not in_block:
            op = ln.find('/*')
            if op >= 0 and '*/' not in ln[op:]:
                in_block = True
    return changed, skipped

def main():
    apply = '--apply' in sys.argv
    total_c = total_s = 0
    for p in sorted(glob.glob(str(ROOT/'sidecar/**/*.py'), recursive=True)):
        if '/test_' in p or '/.venv/' in p or '__pycache__' in p:
            continue
        changed, skipped = apply_py(Path(p), dry=not apply)
        if changed or skipped:
            rel = Path(p).relative_to(ROOT)
            print(f"\n== {rel}  剥 {len(changed)} 行 / 跳过 {len(skipped)}")
            for r, old, new in changed[:400]:
                tag = 'DEL ' if new is None else '    '
                print(f"  {tag}L{r}: {old.strip()[:80]}")
                if new is not None:
                    print(f"      -> {new.strip()[:80]}")
            for pos, txt in skipped:
                print(f"  KEEP L{pos[0]}: {txt}")
            total_c += len(changed); total_s += len(skipped)
    for p in sorted(glob.glob(str(ROOT/'renderer/src/**/*.ts*'), recursive=True)):
        if '__tests__' in p:
            continue
        path = Path(p)
        changed, skipped = fe_changes(path)
        if changed or skipped:
            rel = path.relative_to(ROOT)
            print(f"\n== {rel}  剥 {len(changed)} 行 / 跳过 {len(skipped)}")
            for r, old, new in changed[:400]:
                tag = 'DEL ' if new is None else '    '
                print(f"  {tag}L{r}: {old.strip()[:80]}")
                if new is not None:
                    print(f"      -> {new.strip()[:80]}")
            for pos, txt in skipped:
                print(f"  KEEP L{pos[0]}: {txt}")
            if apply:
                lines = path.read_text(encoding='utf-8').split('\n')
                for r, old, new in changed:
                    lines[r - 1] = new
                path.write_text('\n'.join(l for l in lines if l is not None), encoding='utf-8')
            total_c += len(changed); total_s += len(skipped)
    print(f"\n{'='*60}\n合计：剥 {total_c} 行，保留(字符串/存疑) {total_s} 行"
          f"（{'已应用' if apply else 'dry-run，未改写'}）")

if __name__ == '__main__':
    main()
