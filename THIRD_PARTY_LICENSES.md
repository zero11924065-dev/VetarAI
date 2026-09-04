# THIRD_PARTY_LICENSES — VetarAI 第三方依赖许可清单
# Third-Party License Inventory

> 本文件记录 VetarAI 所依赖的全部第三方组件及其许可证，作为项目合规的存档证明。
> 扫描日期：2026-09-04（v0.4.2）。
>
> This document records every third-party component VetarAI depends on and its license,
> as the project's compliance record. Scan date: 2026-09-04 (v0.4.2).

---

## 1. 许可兼容性总述 / License Compatibility Summary

VetarAI 本身采用 **GNU GPL v3.0** 许可（见仓库根目录 `LICENSE`）。

经过对 **前端 209 个包** 与 **后端 35 个包** 的逐一扫描，所有**随安装包分发**的运行时依赖
均为 **MIT / BSD / Apache-2.0 / ISC / MPL-2.0** 等宽松型许可证，**与 GPL-3.0 完全兼容**，
可合法地包含在本项目的发行版中。未发现任何会污染 GPL 的专有（proprietary）或强复制性许可依赖。

VetarAI itself is licensed under **GNU GPL v3.0** (see `LICENSE` at the repo root).
After scanning all **209 frontend** and **35 backend** packages, every runtime dependency
**distributed with the installer** uses a **permissive license (MIT / BSD / Apache-2.0 / ISC / MPL-2.0)**,
which is **fully compatible with GPL-3.0** and may legally be included in this distribution.
No proprietary or strongly-copyleft dependency that would conflict with GPL was found.

> 扫描方法：遍历 `renderer/node_modules` 与后端虚拟环境中每个包的 `package.json` /
> PyPI 元数据（`License` 与 `License-Expression` 字段），逐一归类。
> Method: walked each package's `package.json` / PyPI metadata (`License` and
> `License-Expression` fields) in `renderer/node_modules` and the backend venv, classifying each.

---

## 2. 应用外壳 / Application Shell

| 组件 Component | 版本 Version | 许可证 License | 版权 Copyright |
|---|---|---|---|
| Electron | 随仓库锁定 | MIT | Copyright (c) Electron contributors; (c) 2013-2020 GitHub Inc. |

Electron 随安装包分发，其 Chromium 组件另见安装包内 `LICENSES.chromium.html`。
Electron ships with the installer; its Chromium component is additionally covered by
`LICENSES.chromium.html` inside the app bundle.

---

## 3. 前端运行时依赖（打包进应用）/ Frontend Runtime (bundled)

核心直接依赖及其许可证（传递依赖经扫描均为宽松许可）：
Key direct dependencies and their licenses (all transitive deps scanned as permissive):

| 组件 Component | 许可证 License | 说明 Note |
|---|---|---|
| react / react-dom | MIT | Copyright (c) Meta Platforms, Inc. and affiliates |
| react-markdown | MIT | Markdown 渲染 / Markdown rendering |
| remark-gfm | MIT | GitHub 风格 Markdown 扩展 / GFM extension |

其余 200+ 传递依赖的许可证分布：**MIT ×189、Apache-2.0 ×6、ISC ×4、BSD ×4、MPL-2.0 ×2、
MIT-0 ×2、BlueOak-1.0 ×1、CC0-1.0 ×1**。其中 2 个 MPL-2.0 包（lightningcss 及其平台二进制）
仅为**构建期工具**，不进入最终安装包。
The remaining 200+ transitive dependencies distribute as: **MIT ×189, Apache-2.0 ×6, ISC ×4,
BSD ×4, MPL-2.0 ×2, MIT-0 ×2, BlueOak-1.0 ×1, CC0-1.0 ×1**. The 2 MPL-2.0 packages
(lightningcss and its platform binary) are **build-time tools only** and are not shipped in the installer.

---

## 4. 后端运行时依赖（冻结进侧车二进制）/ Backend Runtime (frozen into sidecar)

| 组件 Component | 版本 Version | 许可证 License | 版权/作者 Author |
|---|---|---|---|
| fastapi | 0.141.x | MIT | Sebastián Ramírez |
| uvicorn | 0.52.x | BSD-3-Clause | Tom Christie (encode) |
| httpx / httpcore | 0.28.x / 1.0.x | BSD-3-Clause | Tom Christie (encode) |
| pydantic / pydantic_core | 2.13.x / 2.46.x | MIT | Samuel Colvin et al. |
| starlette | 1.6.x | BSD-3-Clause | encode |
| anyio | 4.14.x | MIT | Alex Grönholm |
| jieba | 0.42.1 | MIT | Sun, Junyi（中文分词 / Chinese word segmentation） |
| onnxruntime | 1.29.0 | MIT | Microsoft Corporation（嵌入模型推理 / embedding inference） |
| tokenizers | 0.23.2 | Apache-2.0 | Hugging Face |
| numpy | 2.5.x | BSD-3-Clause (+0BSD/MIT/Zlib/CC0) | Travis E. Oliphant et al. |
| protobuf | 7.36.x | BSD-3-Clause | Google |
| PyYAML | 6.0.x | MIT | Ingy döt Net / Kirill Simonov |
| certifi | 2026.x | MPL-2.0 | Kenneth Reitz（Mozilla CA 证书束 / Mozilla CA bundle） |
| idna | 3.19 | BSD-3-Clause | Kim Davies |
| pypdf | — | BSD-3-Clause | PDF 解析（懒加载）/ PDF parsing (lazy-loaded) |
| python-docx | — | MIT | Word 解析（懒加载）/ DOCX parsing (lazy-loaded) |
| openpyxl | — | MIT | Excel 解析（懒加载）/ XLSX parsing (lazy-loaded) |

> 说明：pypdf / python-docx / openpyxl 在 `sidecar/attachments/parser.py` 中**函数级懒加载**，
> 缺失时优雅降级（附件以文件名标注），不阻塞核心功能。
> Note: pypdf / python-docx / openpyxl are **lazily imported** at function level in
> `sidecar/attachments/parser.py`; if absent, parsing degrades gracefully (attachment
> recorded by filename) without blocking core features.

---

## 5. 内置模型 / Bundled Model

| 组件 Component | 许可证 License | 说明 Note |
|---|---|---|
| bge-m3 ONNX INT8 (gpahal/bge-m3-onnx-int8) | MIT | 语义嵌入模型，随安装包分发 / Semantic embedding model shipped in the installer |

该模型基于 BAAI/bge-m3，由 gpahal 导出为 ONNX INT8 三合一（dense / sparse / ColBERT）。
其 MIT 许可条款**独立于本项目**，在 README 与安装包中已单独声明。
This model is derived from BAAI/bge-m3, exported to ONNX INT8 tri-mode by gpahal.
Its MIT license applies **independently of this project** and is noted separately in the
README and the installer.

---

## 6. 构建/开发期依赖（不随安装包分发）/ Build & Dev Dependencies (not distributed)

以下依赖仅存在于开发机，**不会**随安装包分发，其许可证不构成对发行版的约束：
The following are used on the development machine only and are **not** shipped with the
installer, so their licenses do not constrain the distribution:

| 组件 Component | 许可证 License | 用途 Purpose |
|---|---|---|
| PyInstaller | GPLv2-or-later（含特殊豁免） | 冻结侧车二进制；其特殊豁免明确允许产出**任意许可**的程序，与本项目的 GPL 输出无冲突 |
| vite | MIT | 前端构建 / frontend build |
| typescript | Apache-2.0 | 类型检查 / type checking |
| vitest / @testing-library/* / jsdom | MIT | 测试 / testing |

> PyInstaller note: PyInstaller is GPLv2+ **with a special exception** explicitly permitting
> the creation of executables under any license; building the GPL-licensed sidecar with it
> is fully compliant and creates no conflict.

---

## 7. 结论 / Conclusion

- **运行时依赖**：全部宽松许可，与 GPL-3.0 兼容，可合法分发。✅
- **内置模型**：MIT，独立声明。✅
- **构建工具**：不随发行版分发，无约束。✅
- **未发现**任何专有许可或与 GPL 冲突的强复制性依赖。✅

- **Runtime dependencies**: all permissive, GPL-3.0 compatible, legally distributable. ✅
- **Bundled model**: MIT, separately declared. ✅
- **Build tools**: not distributed, no constraint. ✅
- **No** proprietary or GPL-conflicting copyleft dependency found. ✅

*本清单由自动化扫描生成并经人工复核。若上游许可证发生变更，请以最新扫描为准。*
*This inventory was generated by automated scanning with manual review. If upstream
licenses change, re-run the scan for the latest result.*
