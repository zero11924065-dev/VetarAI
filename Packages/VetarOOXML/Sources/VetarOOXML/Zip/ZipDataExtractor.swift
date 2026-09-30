//
//  ZipDataExtractor.swift
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
import zlib

/// ZIP 条目数据提取（P2-W3b 读取侧）：按 central directory 的 localHeaderOffset
/// 定位 local header，跳过 name/extra 后取压缩流；method 8 走 libz raw inflate
/// （windowBits = -15，与 ZipWriter 的 deflate 侧互逆），method 0 原样返回。
/// 解压后按 CRC32 校验（对齐 Python zipfile 的坏档检测语义——CRC 不符即抛错）。
public enum ZipExtractError: Error, Equatable {
    case entryNotFound(String)
    case badLocalHeader(String)
    case unsupportedMethod(UInt16)
    case inflateFailed(Int32)
    case sizeMismatch(expected: UInt32, actual: Int)
    case crcMismatch(String)
}

extension ZipArchiveReader {

    /// 按文件名取解压后数据（重复名取第一个，与 zipfile.read 同语义）。
    public func data(named name: String, from zipData: Data) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw ZipExtractError.entryNotFound(name)
        }
        return try data(for: entry, from: zipData)
    }

    /// 按条目取解压后数据。
    public func data(for entry: EntryInfo, from zipData: Data) throws -> Data {
        let bytes = [UInt8](zipData)
        let off = Int(entry.localHeaderOffset)
        guard off + 30 <= bytes.count,
              Self.u32(bytes, off) == 0x0403_4B50 else {
            throw ZipExtractError.badLocalHeader(entry.name)
        }
        let nameLen = Int(Self.u16(bytes, off + 26))
        let extraLen = Int(Self.u16(bytes, off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= bytes.count else {
            throw ZipExtractError.badLocalHeader(entry.name)
        }
        let raw = Data(bytes[dataStart..<dataEnd])

        let out: Data
        switch entry.method {
        case 0:
            out = raw
        case 8:
            out = try ZipDataExtractor.inflateRaw(raw, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipExtractError.unsupportedMethod(entry.method)
        }
        guard out.count == Int(entry.uncompressedSize) else {
            throw ZipExtractError.sizeMismatch(expected: entry.uncompressedSize, actual: out.count)
        }
        guard CRC32.checksum(out) == entry.crc32 else {
            throw ZipExtractError.crcMismatch(entry.name)
        }
        return out
    }
}

/// raw inflate（无 zlib 头尾），与 ZipWriter.deflateRaw 互逆。
enum ZipDataExtractor {
    static func inflateRaw(_ data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, ZLIB_VERSION,
                                       Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw ZipExtractError.inflateFailed(initResult) }
        defer { inflateEnd(&stream) }

        var out = Data()
        out.reserveCapacity(max(expectedSize, 0))
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        return try data.withUnsafeBytes { srcBuf in
            stream.next_in = UnsafeMutablePointer(mutating: srcBuf.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            while true {
                let result: Int32 = chunk.withUnsafeMutableBytes { dstBuf in
                    stream.next_out = dstBuf.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                out.append(contentsOf: chunk[0..<produced])
                if result == Z_STREAM_END { break }
                guard result == Z_OK || result == Z_BUF_ERROR else {
                    throw ZipExtractError.inflateFailed(result)
                }
                // 输入耗尽但未结束 → 坏档
                if stream.avail_in == 0 && result != Z_STREAM_END && produced == 0 {
                    throw ZipExtractError.inflateFailed(Z_DATA_ERROR)
                }
            }
            return out
        }
    }
}
