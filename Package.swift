//
//  Package.swift
//  VetarAI — Local-first multi-agent orchestration application
//  Copyright (C) 2026 zero11924065-dev
//
//  This file is part of VetarAI.
//
//  VetarAI is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  VetarAI is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
//

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VetarAINative",
    platforms: [.macOS(.v14)],
    dependencies: [
        // P2-W1：bge-m3 分词器——项目零外部依赖纪律的唯一已论证例外
        // （pilot 论证：docs/pilot/W3_bge_m3_coreml_pilot.md §4；直接消费既有 tokenizer.json，
        //   特殊 token 由 TemplateProcessing 自动处理，无 C++/protobuf 依赖）。
        // 锁 revision = tag 1.3.4（c21fdcde）：供应链确定性，防上游移动。
        // 只用 Tokenizers 子产品（Hub/Jinja 传递依赖随包解析，代码面不触达）。
        .package(url: "https://github.com/huggingface/swift-transformers.git",
                 revision: "c21fdcde390313a6d98d8e33a346f2c3486c3ab0"),
        // P2-W3b：本地 OOXML 生成/读取库（Office 文档生成与解析原生化的载体）。
        .package(path: "Packages/VetarOOXML"),
        // .vmodel 集成：VetarModel 训练产物（.vmodel 容器）的安装/校验/解包 SDK。
        // 私有 git 版本锁定（私服 exact 0.2.0 = tag commit d8824a1，供应链确定性
        // 与 swift-transformers revision 锁同纪律）。URL 不带用户名/令牌——
        // 认证走 macOS 钥匙串（sdk-bot 令牌经 credential.helper 供给）。
        // 0.2.0 纯增量：v2 容器密钥服务（ModelKeyResolver/ModelKeyFetcher/
        // ModelKeychainCache + VModelLoader async 变体），0.1.0 调用面零改动。
        // 原本地路径 ../../beta2/VetarModelSDK 仅作开发回退（私服不可达时临时改回
        // path 口径，勿带此口径发版）。
        .package(url: "https://git.vetarai.com/vetar/vetar-model-sdk.git", exact: "0.2.0"),
        // ADR-0052 方案A：.vmodel 本机推理栈——MLX LLM 运行时（LoRA 适配器叠加
        // 底座 safetensors 为 .vmodel 原生格式；锁 revision = 上游 tag 3.31.4
        // （bd4b7434），供应链纪律同 swift-transformers）。只用 MLXLLM/MLXLMCommon
        // 两子产品（VLM/Embedders/Rerankers 不引——vl 走 Ollama 既有路、bge-m3
        // 走 CoreML 既有路）。
        // 零冲突论证：不依赖 swift-transformers（tokenizer 自包含 TokenizerLoader）；
        // 传递依赖 mlx-swift + swift-syntax（编译期宏，不进运行时）。
        // 留痕：spike 阶段曾因本机 git 协议到 github.com 不通临时落 /tmp/mlx-vendor
        // 本地路径（两级 manifest 本地化）；2026-09-26 回切 revision 锁正式口径——
        // 本机到 github.com 的 git 访问仍间歇被断（TCP 层），取数走
        // beta/vendor-mirrors/ 本地镜像（SPM set-mirror + 子模块 insteadOf +
        // protocol.file.allow，内容与上游逐 SHA 一致），锁定值与上游权威源逐字
        // 核对；网络恢复后删镜像配置即可无差别直连。细节录 docs DBG-172。
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git",
                 revision: "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"),
        // 0.7.9（契约 v1.10 §2.15）：Sparkle 2.x 应用内自动更新（EdDSA 验签，
        // 替换 v1.4 自研 JSON 端点 + DMG 引导安装链）。锁 exact 2.10.0 =
        // 与 VetarModel M27 同版（其 Package.resolved revision eef1a539）——
        // 供应链确定性纪律同 swift-transformers/mlx。Sparkle 为 binaryTarget
        // （xcframework 内含 Updater.app/XPC 服务；bin/sign_update 为发版
        // 签名工具，scripts/sign_update.sh 调用）。
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "VetarAINative",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers"),
                           .product(name: "Hub", package: "swift-transformers"),
                           .product(name: "VetarOOXML", package: "VetarOOXML"),
                           .product(name: "VetarModelSDK", package: "vetar-model-sdk"),
                           .product(name: "MLXLLM", package: "mlx-swift-lm"),
                           .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/VetarAINative"
        ),
        .testTarget(
            name: "VetarAINativeTests",
            dependencies: ["VetarAINative",
                           // P2-W3b 规格补测：直接消费 ZipArchiveReader/DocXBuilder 等
                           // 读写面造样本与读回断言（NativeToolOffice*Tests）。
                           .product(name: "VetarOOXML", package: "VetarOOXML"),
                           // .vmodel 集成测试：@testable 取 VModelFormat.deriveKey 造容器 fixture
                           // （与 SDK 自测 TestContainerWriter 同笔法，双向验证非自证）。
                           .product(name: "VetarModelSDK", package: "vetar-model-sdk")],
            path: "Tests/VetarAINativeTests",
            resources: [.process("Fixtures")]
        )
    ]
)
