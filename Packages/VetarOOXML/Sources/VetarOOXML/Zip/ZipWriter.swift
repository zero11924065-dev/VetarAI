//
//  ZipWriter.swift
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

/// 纯 Swift ZIP writer：local file header + deflate 数据 + central directory + EOCD。
/// 压缩走系统 libz 的 raw deflate（windowBits = -15，无 zlib 头），CRC32 用自实现。
public struct ZipWriter {

    public enum Error: Swift.Error {
        case deflateFailed(Int32)
        case nameNotUTF8
    }

    private struct Entry {
        let name: [UInt8]          // UTF-8 文件名
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private var buffer = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        // DOS 时间：bit 31-25 年(1980 起) / 24-21 月 / 20-16 日；15-11 时 / 10-5 分 / 4-0 秒/2
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
    }

    /// 追加一个文件条目（立即压缩并写入 local header + 数据）。
    public mutating func addFile(name: String, data: Data) throws {
        guard let nameBytes = name.data(using: .utf8) else { throw Error.nameNotUTF8 }
        let compressed = try ZipWriter.deflateRaw(data)
        let crc = CRC32.checksum(data)
        let offset = UInt32(buffer.count)

        buffer.appendFixed32(0x0403_4B50)      // local file header 签名
        buffer.appendFixed16(20)               // version needed
        buffer.appendFixed16(0x0800)           // flags: bit11 = UTF-8 文件名
        buffer.appendFixed16(8)                // method: deflate
        buffer.appendFixed16(dosTime)
        buffer.appendFixed16(dosDate)
        buffer.appendFixed32(crc)
        buffer.appendFixed32(UInt32(compressed.count))
        buffer.appendFixed32(UInt32(data.count))
        buffer.appendFixed16(UInt16(nameBytes.count))
        buffer.appendFixed16(0)                // extra length
        buffer.append(nameBytes)
        buffer.append(compressed)

        entries.append(Entry(name: [UInt8](nameBytes), crc32: crc,
                             compressedSize: UInt32(compressed.count),
                             uncompressedSize: UInt32(data.count),
                             localHeaderOffset: offset,
                             dosTime: dosTime, dosDate: dosDate))
    }

    /// 收尾：写 central directory + EOCD，返回完整 ZIP 字节。
    public func finalize() -> Data {
        var out = buffer
        let cdOffset = UInt32(out.count)
        for e in entries {
            out.appendFixed32(0x0201_4B50)     // central directory 签名
            out.appendFixed16(20)              // version made by
            out.appendFixed16(20)              // version needed
            out.appendFixed16(0x0800)          // flags
            out.appendFixed16(8)               // method
            out.appendFixed16(e.dosTime)
            out.appendFixed16(e.dosDate)
            out.appendFixed32(e.crc32)
            out.appendFixed32(e.compressedSize)
            out.appendFixed32(e.uncompressedSize)
            out.appendFixed16(UInt16(e.name.count))
            out.appendFixed16(0)               // extra
            out.appendFixed16(0)               // comment
            out.appendFixed16(0)               // disk number
            out.appendFixed16(0)               // internal attrs
            out.appendFixed32(0)               // external attrs
            out.appendFixed32(e.localHeaderOffset)
            out.append(contentsOf: e.name)
        }
        let cdSize = UInt32(out.count) - cdOffset
        out.appendFixed32(0x0605_4B50)         // EOCD 签名
        out.appendFixed16(0)
        out.appendFixed16(0)
        out.appendFixed16(UInt16(entries.count))
        out.appendFixed16(UInt16(entries.count))
        out.appendFixed32(cdSize)
        out.appendFixed32(cdOffset)
        out.appendFixed16(0)                   // comment length
        return out
    }

    /// raw deflate（无 zlib 头尾），windowBits = -15。
    static func deflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                       -15, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw Error.deflateFailed(initResult) }
        defer { deflateEnd(&stream) }

        var out = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        return try data.withUnsafeBytes { srcBuf in
            stream.next_in = UnsafeMutablePointer(mutating: srcBuf.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            var flush = data.isEmpty ? Z_FINISH : Z_NO_FLUSH
            repeat {
                if stream.avail_in == 0 { flush = Z_FINISH }
                let result: Int32 = chunk.withUnsafeMutableBytes { dstBuf in
                    stream.next_out = dstBuf.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, flush)
                }
                guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else {
                    throw Error.deflateFailed(result)
                }
                let produced = chunkSize - Int(stream.avail_out)
                out.append(contentsOf: chunk[0..<produced])
            } while stream.avail_out == 0 || flush != Z_FINISH
            return out
        }
    }
}

extension Data {
    mutating func appendFixed16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendFixed32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
