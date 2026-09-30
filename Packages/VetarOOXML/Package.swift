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

// W2 pilot：全原生 OOXML 生成库（零外部依赖，仅系统 libz）。
// 独立本地包，避免与根包其他 pilot 分支的 WIP target 相互影响。
let package = Package(
    name: "VetarOOXML",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VetarOOXML", targets: ["VetarOOXML"]),
    ],
    targets: [
        .target(
            name: "VetarOOXML",
            path: "Sources/VetarOOXML",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "VetarOOXMLSampleGen",
            dependencies: ["VetarOOXML"],
            path: "Sources/SampleGen"
        ),
        .testTarget(
            name: "VetarOOXMLTests",
            dependencies: ["VetarOOXML"],
            path: "Tests/VetarOOXMLTests"
        ),
    ]
)
