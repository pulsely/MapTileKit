//
//  Gunzip.swift
//  MapTileKit
//
//  Minimal gzip (RFC 1952) decompressor. mbtiles vector tile blobs are
//  gzip-compressed Mapbox Vector Tile protobuf data; Apple's Compression
//  framework only speaks raw DEFLATE, so this strips the gzip header/trailer
//  and hands the raw deflate stream to it.
//

import Foundation
import Compression

enum Gunzip {
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18 else { return nil }
        let base = data.startIndex
        guard data[base] == 0x1f, data[base + 1] == 0x8b, data[base + 2] == 8 else {
            return nil // not gzip, or not deflate-compressed
        }

        let flags = data[base + 3]
        var offset = base + 10 // fixed header: ID1 ID2 CM FLG MTIME(4) XFL OS

        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= data.endIndex else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }

        let trailerStart = data.endIndex - 8
        guard offset < trailerStart else { return nil }

        // ISIZE: size of the original uncompressed input, mod 2^32 - a useful
        // hint for sizing the output buffer, but untrusted input (a
        // corrupted or unexpectedly-framed blob) can make it anywhere up to
        // ~4.3 billion. This app's tiles are at most a few hundred KB
        // decompressed, so the hint is capped well below that: trusting it
        // unconditionally previously caused a multi-gigabyte array
        // allocation attempt, which crashed rather than just failing this
        // one tile's decode.
        let isize = UInt32(data[trailerStart])
            | (UInt32(data[trailerStart + 1]) << 8)
            | (UInt32(data[trailerStart + 2]) << 16)
            | (UInt32(data[trailerStart + 3]) << 24)

        let deflateCount = trailerStart - offset
        guard deflateCount > 0 else { return nil }

        let maxReasonableCapacity = 32 * 1024 * 1024 // 32 MB; largest real tile seen is ~550 KB
        let destinationCapacity = min(max(Int(isize), deflateCount * 4, 1024), maxReasonableCapacity)
        var destinationBuffer = [UInt8](repeating: 0, count: destinationCapacity)

        // Read straight out of `data`'s own storage instead of copying the
        // compressed payload into a separate buffer first - this runs once
        // per tile, and tiles can contain many features, so avoiding the
        // extra copy here matters.
        let decodedCount = destinationBuffer.withUnsafeMutableBufferPointer { destPtr -> Int in
            data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int in
                let srcPtr = rawPtr.baseAddress!.advanced(by: offset - base)
                    .assumingMemoryBound(to: UInt8.self)
                return compression_decode_buffer(
                    destPtr.baseAddress!, destinationCapacity,
                    srcPtr, deflateCount,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount > 0 else { return nil }
        return Data(destinationBuffer.prefix(decodedCount))
    }
}
