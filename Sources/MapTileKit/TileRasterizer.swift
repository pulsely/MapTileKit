//
//  TileRasterizer.swift
//  MapTileKit
//
//  Renders a tile's decoded Mapbox Vector Tile layers into PNG image data -
//  the format MKTileOverlay.loadTile(at:result:) hands back to MapKit, which
//  then decodes and caches it like any other raster tile.
//

import UIKit

enum TileRasterizer {
    static let tileSize: CGFloat = 256

    static func renderPNG(layers: [MVTLayer], scale: CGFloat) -> Data? {
        let rect = CGRect(x: 0, y: 0, width: tileSize, height: tileSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        let image = renderer.image { ctx in
            let context = ctx.cgContext
            context.setFillColor(TileLayerStyle.backgroundColor.cgColor)
            context.fill(rect)
            drawLayers(layers, in: rect, context: context)
        }
        return image.pngData()
    }

    private static func drawLayers(_ layers: [MVTLayer], in rect: CGRect, context: CGContext) {
        for layer in layers {
            let style = TileLayerStyle.style(forLayerNamed: layer.name)
            guard style.isVisible, layer.extent > 0 else { continue }

            for feature in layer.features {
                guard let path = path(for: feature, extent: layer.extent, rect: rect) else { continue }

                context.saveGState()

                switch feature.type {
                case .polygon:
                    context.addPath(path)
                    context.setFillColor(style.fillColor.cgColor)
                    context.fillPath(using: .evenOdd)
                    if let strokeColor = style.strokeColor {
                        context.addPath(path)
                        context.setStrokeColor(strokeColor.cgColor)
                        context.setLineWidth(style.lineWidth)
                        context.strokePath()
                    }

                case .lineString:
                    if let strokeColor = style.strokeColor {
                        context.addPath(path)
                        context.setStrokeColor(strokeColor.cgColor)
                        context.setLineWidth(style.lineWidth)
                        context.strokePath()
                    }

                case .point, .unknown:
                    break
                }

                context.restoreGState()
            }
        }
    }

    /// Decodes an MVT feature's geometry command stream (spec 2.1 §4.3) into a
    /// path in the tile's pixel space. Tile-local coordinates run 0...extent
    /// with the same top-left, Y-down origin the rendering context already
    /// uses, so this is a straight scale + offset, no flip.
    private static func path(for feature: MVTFeature, extent: UInt32, rect: CGRect) -> CGPath? {
        guard !feature.geometry.isEmpty else { return nil }

        let scaleX = rect.width / CGFloat(extent)
        let scaleY = rect.height / CGFloat(extent)

        let path = CGMutablePath()
        var x: Int32 = 0
        var y: Int32 = 0
        var i = 0
        let commands = feature.geometry
        var ringStart: CGPoint?

        while i < commands.count {
            let commandInteger = commands[i]
            i += 1
            let commandId = commandInteger & 0x7
            let commandCount = Int(commandInteger >> 3)

            switch commandId {
            case 1, 2: // MoveTo, LineTo
                for _ in 0..<commandCount {
                    guard i + 1 < commands.count else { break }
                    x += zigzagDecode(commands[i]); i += 1
                    y += zigzagDecode(commands[i]); i += 1

                    let point = CGPoint(x: rect.minX + CGFloat(x) * scaleX, y: rect.minY + CGFloat(y) * scaleY)

                    if commandId == 1 {
                        path.move(to: point)
                        ringStart = point
                    } else {
                        path.addLine(to: point)
                    }
                }

            case 7: // ClosePath
                if let start = ringStart {
                    path.addLine(to: start)
                    path.closeSubpath()
                }

            default:
                return path // malformed command; draw what we decoded so far
            }
        }

        return path
    }
}

private func zigzagDecode(_ n: UInt32) -> Int32 {
    Int32(bitPattern: n >> 1) ^ -Int32(n & 1)
}

private struct TileLayerStyle {
    let isVisible: Bool
    let fillColor: UIColor
    let strokeColor: UIColor?
    let lineWidth: CGFloat

    static let backgroundColor = UIColor(red: 0.73, green: 0.84, blue: 0.92, alpha: 1.0) // ocean

    static func style(forLayerNamed name: String) -> TileLayerStyle {
        switch name {
        case "country", "state":
            return TileLayerStyle(
                isVisible: true,
                fillColor: UIColor(white: 0.85, alpha: 1.0),
                strokeColor: UIColor(white: 0.6, alpha: 1.0),
                lineWidth: 0.5
            )
        case "land-border-country", "geo-lines":
            return TileLayerStyle(
                isVisible: true,
                fillColor: .clear,
                strokeColor: UIColor(white: 0.4, alpha: 1.0),
                lineWidth: 0.75
            )
        default:
            // e.g. "country-name": point labels aren't rendered yet.
            return TileLayerStyle(isVisible: false, fillColor: .clear, strokeColor: nil, lineWidth: 0)
        }
    }
}
