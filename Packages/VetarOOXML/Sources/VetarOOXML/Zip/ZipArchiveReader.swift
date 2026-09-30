//
//  ZipArchiveReader.swift
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

import Foundation

/// 只读 ZIP 解析器：从 EOCD 定位 central directory 并解析条目，
/// 供 XCTest 读回自产 ZIP 做结构自验（不依赖系统 unzip）。
public struct ZipArchiveReader {

    public struct EntryInfo: Equatable {
        public let name: String
        public let compressedSize: UInt32
        public let uncompressedSize: UInt32
        public let crc32: UInt32
        public let method: UInt16
        /// P2-W3b：central directory 记录的 local header 偏移（数据提取定位用）。
        public let localHeaderOffset: UInt32
    }

    public let entries: [EntryInfo]

    public init(data: Data) throws {
        // 找 EOCD：从尾部向前扫 0x06054B50
        let bytes = [UInt8](data)
        var eocdOffset: Int? = nil
        if bytes.count >= 22 {
            var i = bytes.count - 22
            while i >= 0 {
                if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
                    eocdOffset = i
                    break
                }
                i -= 1
            }
        }
        guard let eocd = eocdOffset else { throw NSError(domain: "ZipArchiveReader", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "EOCD not found"]) }

        let count = Int(Self.u16(bytes, eocd + 10))
        let cdSize = Int(Self.u32(bytes, eocd + 12))
        let cdOffset = Int(Self.u32(bytes, eocd + 16))
        guard cdOffset + cdSize <= eocd else { throw NSError(domain: "ZipArchiveReader", code: 2) }

        var parsed: [EntryInfo] = []
        var p = cdOffset
        for _ in 0..<count {
            guard Self.u32(bytes, p) == 0x0201_4B50 else {
                throw NSError(domain: "ZipArchiveReader", code: 3)
            }
            let method = Self.u16(bytes, p + 10)
            let crc = Self.u32(bytes, p + 16)
            let csize = Self.u32(bytes, p + 20)
            let usize = Self.u32(bytes, p + 24)
            let nameLen = Int(Self.u16(bytes, p + 28))
            let extraLen = Int(Self.u16(bytes, p + 30))
            let commentLen = Int(Self.u16(bytes, p + 32))
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let lhOffset = Self.u32(bytes, p + 42)
            parsed.append(EntryInfo(name: name, compressedSize: csize,
                                    uncompressedSize: usize, crc32: crc, method: method,
                                    localHeaderOffset: lhOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = parsed
    }

    static func u16(_ b: [UInt8], _ off: Int) -> UInt16 {
        UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }
    static func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
}
