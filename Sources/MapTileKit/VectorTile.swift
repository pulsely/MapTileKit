//
//  VectorTile.swift
//  MapTileKit
//
//  Minimal protobuf wire-format reader plus a Mapbox Vector Tile (MVT) spec
//  2.1 parser, covering just what's needed to render tile geometry: layer
//  name, extent, and per-feature geometry type + command stream. Feature
//  attributes (keys/values/tags) aren't parsed since nothing here styles by
//  attribute yet.
//

import Foundation

struct ProtobufReader {
    // Holds a slice of the tile's decoded bytes rather than a copy: Data
    // slices share their parent's storage, so recursing into sub-messages
    // (a layer, then each of its features, then each feature's geometry) is
    // zero-copy all the way down instead of duplicating the buffer at every
    // level - tiles with many features made that add up.
    private let data: Data
    private var index: Int

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var isAtEnd: Bool { index >= data.endIndex }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let tag = readVarint() else { return nil }
        return (Int(tag >> 3), Int(tag & 0x7))
    }

    mutating func readLengthDelimited() -> Data? {
        guard let length = readVarint(), index + Int(length) <= data.endIndex else { return nil }
        let slice = data[index..<(index + Int(length))]
        index += Int(length)
        return slice
    }

    mutating func readPackedVarints() -> [UInt32] {
        guard let payload = readLengthDelimited() else { return [] }
        var reader = ProtobufReader(payload)
        var result: [UInt32] = []
        while !reader.isAtEnd {
            guard let value = reader.readVarint() else { break }
            result.append(UInt32(truncatingIfNeeded: value))
        }
        return result
    }

    mutating func skip(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: index += 8
        case 2: _ = readLengthDelimited()
        case 5: index += 4
        default: break
        }
    }
}

enum MVTGeometryType: UInt64 {
    case unknown = 0
    case point = 1
    case lineString = 2
    case polygon = 3
}

struct MVTFeature {
    let type: MVTGeometryType
    let geometry: [UInt32]
}

struct MVTLayer {
    let name: String
    let extent: UInt32
    let features: [MVTFeature]
}

enum MVTParser {
    /// Parses a Tile message's top-level `layers` field (field 3).
    static func parseLayers(_ data: Data) -> [MVTLayer] {
        var reader = ProtobufReader(data)
        var layers: [MVTLayer] = []

        while let (field, wireType) = reader.readTag() {
            if field == 3, wireType == 2, let layerData = reader.readLengthDelimited() {
                if let layer = parseLayer(layerData) {
                    layers.append(layer)
                }
            } else {
                reader.skip(wireType: wireType)
            }
        }
        return layers
    }

    private static func parseLayer(_ data: Data) -> MVTLayer? {
        var reader = ProtobufReader(data)
        var name = ""
        var extent: UInt32 = 4096
        var features: [MVTFeature] = []

        while let (field, wireType) = reader.readTag() {
            switch (field, wireType) {
            case (1, 2): // name
                if let d = reader.readLengthDelimited() {
                    name = String(data: d, encoding: .utf8) ?? ""
                }
            case (2, 2): // features
                if let d = reader.readLengthDelimited(), let feature = parseFeature(d) {
                    features.append(feature)
                }
            case (5, 0): // extent
                if let v = reader.readVarint() { extent = UInt32(truncatingIfNeeded: v) }
            default:
                reader.skip(wireType: wireType)
            }
        }

        guard !name.isEmpty else { return nil }
        return MVTLayer(name: name, extent: extent, features: features)
    }

    private static func parseFeature(_ data: Data) -> MVTFeature? {
        var reader = ProtobufReader(data)
        var type: MVTGeometryType = .unknown
        var geometry: [UInt32] = []

        while let (field, wireType) = reader.readTag() {
            switch (field, wireType) {
            case (3, 0): // geometry type
                if let v = reader.readVarint() { type = MVTGeometryType(rawValue: v) ?? .unknown }
            case (4, 2): // geometry commands (packed varints)
                geometry = reader.readPackedVarints()
            default:
                reader.skip(wireType: wireType)
            }
        }

        return MVTFeature(type: type, geometry: geometry)
    }
}
