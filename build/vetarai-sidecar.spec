# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_submodules, collect_data_files

hiddenimports = ['et_xmlfile', 'email.mime.text']
hiddenimports += collect_submodules('sidecar')
hiddenimports += collect_submodules('uvicorn')
# TS-120 阶段二：懒加载依赖显式声明（函数内 import，静态分析不追踪）：
# jieba 分词（含词典数据）/ onnxruntime / tokenizers（bge-m3 本地嵌入推理）
hiddenimports += collect_submodules('jieba')
hiddenimports += ['onnxruntime', 'tokenizers']
# 0.4.6：Office 文档解析/生成依赖（全部函数内懒加载，必须显式声明，
# 否则冻结后附件解析静默失败、create_document 工具不可用——0.4.5 实测暴露的根因）
hiddenimports += collect_submodules('pypdf')
hiddenimports += collect_submodules('docx')
hiddenimports += collect_submodules('openpyxl')
hiddenimports += collect_submodules('pptx')

# jieba 词典必须随包（缺词典时 jieba 静默退化为逐字匹配，关键词检索精度崩塌）
_datas = collect_data_files('jieba')
# python-pptx 内置默认模板/主题资源（生成 PPT 必需，缺了会报模板缺失）
_datas += collect_data_files('pptx')

# 冻结包目录结构补齐（2026-09-07 真机定位，0.4.11 修复）。
# 根因：纯 Python 模块被编进 PYZ 归档后，模块所在目录在磁盘上**不存在**，而
# python-docx / python-pptx 用「自身 __file__ + 相对路径」定位内置模板：
#   docx/parts/hdrftr.py → os.path.split(__file__)[0] + "../templates/default-footer.xml"
# 拼出 _internal/docx/parts/../templates/... ；parts/ 组件缺失 → 路径解析 ENOENT，
# 而模板文件本身就在 _internal/docx/templates/ 里。
# 官方 hook-docx.py 用 collect_data_files("docx")，默认 include_py_files=False，
# 只收数据文件、**不建子包目录** —— 这正是缺陷根源。
# 后果：打包版 create_document 必失败（页眉/页脚/样式/设置/批注共 5 处），
# pptx 的 parse_from_template 同样失败（共 3 处）；venv 开发环境因目录真实存在而
# 永远正常，故此缺陷只在安装包中暴露（0.4.6 页脚页码域上线起，所有安装包 docx 生成均坏）。
# 修法：仅收各子包 __init__.py（约 33KB，对比全量源码 2.68MB）以建出目录骨架。
# ** 通配覆盖嵌套子包，依赖升级新增子包时自动跟随，无需维护清单。
# ⛔ 不得改为运行时 os.makedirs 预建目录：那会往 /Applications/VetarAI.app/ 内写入，
#    改动已签名应用包、破坏签名封印（Developer ID 签名后会导致公证/Gatekeeper 校验失败）。
for _pkg in ('docx', 'pptx'):
    _datas += collect_data_files(_pkg, include_py_files=True,
                                 includes=['**/__init__.py'])


a = Analysis(
    ['../sidecar/launcher_prod.py'],
    pathex=['.'],
    binaries=[],
    datas=_datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='vetarai-sidecar',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='vetarai-sidecar',
)
