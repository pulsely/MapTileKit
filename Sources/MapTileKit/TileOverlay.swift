//
//  TileOverlay.swift
//  MapTileKit
//
//  MKTileOverlay backed by an mbtiles sqlite database whose tile_data blobs
//  are gzip-compressed Mapbox Vector Tile (MVT) protobuf, not raster images.
//  Subclassing MKTileOverlay (rather than a plain MKOverlay with a custom
//  MKOverlayRenderer) matters for two reasons: `canReplaceMapContent` lets
//  MapKit skip loading its own network-dependent base map entirely, which a
//  bare MKOverlay has no way to request; and MapKit renders/caches
//  MKTileOverlay tiles through its own bounded tile cache instead of
//  whatever a custom MKOverlayRenderer happens to retain per zoom scale.
//

import MapKit

/// Holds one tile's decoded vector layers so a tile MapKit re-requests
/// (e.g. at a different content scale) doesn't repeat the DB read, gunzip,
/// and protobuf parse.
private final class CachedTileLayers {
    let layers: [MVTLayer]
    init(layers: [MVTLayer]) { self.layers = layers }
}

public final class TileOverlay: MKTileOverlay {

    let mbtilesURL: URL

    /// Whether a tile missing from the mbtiles file (this tileset omits
    /// tiles with nothing to draw, e.g. open ocean) renders as a plain
    /// background tile (`true`, the default) or is left unhandled (`false`),
    /// which lets MapKit fall back to its own live network basemap for just
    /// that tile. Note this only covers tiles absent from the file - it does
    /// not affect Apple's separate place-name label layer, which
    /// `canReplaceMapContent` does not suppress; hiding that requires
    /// configuring the hosting `MKMapView` directly (e.g.
    /// `pointOfInterestFilter`).
    public var fillsMissingTilesWithBackground = true

    private let database: FMDatabase
    // Only the actual SQLite call is serialized here (a shared connection
    // isn't safe to drive from multiple threads at once); the CPU-bound
    // gunzip/parse/rasterize work for each tile runs on renderQueue below,
    // so MapKit's many simultaneous tile requests decode in parallel
    // instead of one at a time. Funneling *all* of that work through a
    // single serial queue was turning a screen's worth of tiles (dozens,
    // requested near-simultaneously) into a long serial pile-up.
    private let databaseQueue = DispatchQueue(label: "MapTileKit.TileOverlay.database")

    // Bounded, rather than DispatchQueue.global directly: MapKit can request
    // dozens of tiles in one burst (a screen's worth at launch, or a whole
    // new zoom level after a pinch), and each in-flight tile briefly holds a
    // decompression buffer, a parsed feature array, and a full-resolution
    // CGContext bitmap (a 256pt tile at 3x scale is ~2.4MB uncompressed).
    // Letting all of them run fully in parallel spiked memory hard enough to
    // crash on a real device; capping concurrency keeps peak memory bounded
    // while still decoding well ahead of the old fully-serial approach.
    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let tileCache: NSCache<NSString, CachedTileLayers> = {
        let cache = NSCache<NSString, CachedTileLayers>()
        cache.countLimit = 200
        return cache
    }()

    public init(mbtilesURL: URL) {
        self.mbtilesURL = mbtilesURL
        self.database = FMDatabase(path: mbtilesURL.path)
        super.init(urlTemplate: nil)

        canReplaceMapContent = true
        tileSize = CGSize(width: TileRasterizer.tileSize, height: TileRasterizer.tileSize)
        // This app's mbtiles data only has zoom levels 0...6; MapKit
        // automatically substitutes the nearest available tile for zooms
        // outside this range once it's told the bounds.
        minimumZ = 0
        maximumZ = 6

        if !database.open() {
            NSLog("MapTileKit: unable to open db at \(mbtilesURL.path)")
        }
    }

    public override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        renderQueue.addOperation {
            let data = self.renderedTile(z: path.z, osmCol: path.x, osmRow: path.y, scale: path.contentScaleFactor)
            result(data, nil)
        }
    }

    private func renderedTile(z: Int, osmCol: Int, osmRow: Int, scale: CGFloat) -> Data? {
        let cacheKey = "\(z)/\(osmCol)/\(osmRow)" as NSString

        if let cached = tileCache.object(forKey: cacheKey) {
            return TileRasterizer.renderPNG(layers: cached.layers, scale: scale)
        }

        // This tileset only includes tiles that have something to draw - a
        // missing row means open ocean, not missing data. When
        // fillsMissingTilesWithBackground is true, those render as a plain
        // (empty-layers) tile so canReplaceMapContent stays in effect for
        // them; returning nil instead lets MapKit fall back to its own live
        // network basemap for that one tile.
        guard let compressedData = fetchCompressedTileData(z: z, osmCol: osmCol, osmRow: osmRow),
              let tileData = Gunzip.decompress(compressedData) else {
            guard fillsMissingTilesWithBackground else { return nil }
            tileCache.setObject(CachedTileLayers(layers: []), forKey: cacheKey)
            return TileRasterizer.renderPNG(layers: [], scale: scale)
        }

        let layers = MVTParser.parseLayers(tileData)
        tileCache.setObject(CachedTileLayers(layers: layers), forKey: cacheKey)
        return TileRasterizer.renderPNG(layers: layers, scale: scale)
    }

    private func fetchCompressedTileData(z: Int, osmCol: Int, osmRow: Int) -> Data? {
        // Conversion code from OSM to MBTiles, stolen from
        // https://github.com/rpcarver/osm2mbtiles/blob/master/osm2mbtiles_1_1.m
        let row = Int(pow(2.0, Double(z))) - osmRow - 1
        let col = osmCol

        let queryString = "select tile_data FROM map JOIN images WHERE map.zoom_level=? AND map.tile_column=? AND map.tile_row=? AND map.tile_id=images.tile_id;"

        return databaseQueue.sync {
            guard let resultSet = database.executeQuery(queryString, bindings: [Int32(z), Int32(col), Int32(row)]) else { return nil }
            guard resultSet.next() else { return nil }
            return resultSet.data(forColumn: "tile_data")
        }
    }
}
