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
        .package(url: "https://github.com/huggingface/swift-transformers.git",
                 revision: "c21fdcde390313a6d98d8e33a346f2c3486c3ab0"),
        .package(path: "Packages/VetarOOXML"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git",
                 revision: "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "VetarAINative",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers"),
                           .product(name: "Hub", package: "swift-transformers"),
                           .product(name: "VetarOOXML", package: "VetarOOXML"),
                           .product(name: "MLXLLM", package: "mlx-swift-lm"),
                           .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/VetarAINative"
        ),
        .testTarget(
            name: "VetarAINativeTests",
            dependencies: ["VetarAINative",
                           .product(name: "VetarOOXML", package: "VetarOOXML")],
            path: "Tests/VetarAINativeTests",
            resources: [.process("Fixtures")]
        )
    ]
)
