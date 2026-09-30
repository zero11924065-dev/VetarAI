# THIRD_PARTY_LICENSES — VetarAI 第三方依赖许可清单
# Third-Party License Inventory

> 本文件记录 VetarAI 所依赖的第三方组件及其许可证，作为项目合规的存档证明。
> 扫描日期：2026-09-30（v0.7.15，全原生 Swift 架构）。
>
> This document records the third-party components VetarAI depends on and their licenses,
> as the project's compliance record. Scan date: 2026-09-30 (v0.7.15, fully native Swift architecture).

---

## 1. 许可兼容性总述 / License Compatibility Summary

VetarAI 本身采用 **GNU GPL v3.0** 许可（见仓库根目录 `LICENSE`）。

全部第三方依赖均为 **MIT / Apache-2.0** 等宽松型许可证，**与 GPL-3.0 完全兼容**，可合法地包含在本项目的发行版中。未发现任何会污染 GPL 的专有（proprietary）或强复制性许可依赖。

VetarAI itself is licensed under **GNU GPL v3.0** (see `LICENSE` at the repo root).
All third-party dependencies carry permissive licenses (MIT / Apache-2.0), fully compatible with GPL-3.0. No proprietary or strong-copyleft dependencies found.

---

## 2. SwiftPM 直接依赖 / Direct SwiftPM Dependencies

| 组件 / Component | 版本 / Version | 许可 / License | 用途 / Purpose |
|---|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT | 应用内自动更新框架 / In-app auto-update framework |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)（含 mlx-swift） | 锁定 revision | MIT | Apple Silicon MLX 本地推理 / On-device MLX inference |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 锁定 revision | Apache-2.0 | 分词器与模型工具 / Tokenizers & model tooling |
| VetarOOXML（仓库内置本地包 / vendored local package） | — | GPL-3.0（随本项目 / with this project） | 自研 OOXML 文档生成（docx / pptx / xlsx） |

## 3. SwiftPM 间接依赖 / Transitive Dependencies

随上述直接依赖引入（以各自仓库 LICENSE 为准 / governed by their own LICENSE files）：

- Apple 系列（**Apache-2.0**）：swift-collections / swift-numerics / swift-syntax / swift-asn1 / swift-crypto / swift-argument-parser
- 其他 / Others：yyjson（**MIT**）、eventsource（**MIT**）、swift-huggingface（**Apache-2.0**）、swift-jinja（**Apache-2.0**）

## 4. 随安装包分发的二进制组件 / Bundled Binaries in the Installer

| 组件 / Component | 许可 / License | 用途 / Purpose |
|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT | 本地推理驱动（GGUF 模型） / Local inference driver (GGUF) |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | MIT | 语义嵌入推理运行时 / Semantic embedding runtime |

另使用 macOS 系统框架（NaturalLanguage、CryptoKit、SwiftUI 等），属 Apple 系统组件，不随项目分发。

## 5. 模型组件（按需下载，不随仓库分发）/ Models (Downloaded On Demand, Not in This Repo)

| 模型 / Model | 许可 / License | 用途 / Purpose |
|---|---|---|
| bge-m3（BAAI，ONNX INT8 三合一） | MIT | 语义检索嵌入模型，首次启动按需下载 / Semantic embedding, downloaded on first launch |
| SenseVoiceSmall（INT8） | MIT | 语音识别模型包 / Speech recognition model pack |
| Qwen2.5 0.5B Instruct（Q4_K_M） | Apache-2.0 | 本地对话模型包 / Local chat model pack |

> 注 / Note：上述模型的许可条款独立于本项目；模型文件不存放于本仓库。
> The models above carry their own licenses, independent of this project; model files are not stored in this repository.
