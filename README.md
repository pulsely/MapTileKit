# MapTileKit

![MapTileKit running on iPad Screenshot](screenshot_ipad.png)

A MapKit `MKTileOverlay` that renders vector tiles straight out of a local [MBTiles](https://github.com/mapbox/mbtiles-spec) SQLite file — no tile server, no network access, no dependency on Apple's own live basemap.

Point it at an `.mbtiles` file whose tiles are gzip-compressed [Mapbox Vector Tile](https://github.com/mapbox/vector-tile-spec) (MVT) protobuf data, add it to an `MKMapView`, and it handles the rest: reading the right row out of the database, decompressing it, parsing the vector geometry, and rasterizing it into the map.

## Requirements

- iOS 12+
- Swift tools version 5.9

## Installation

### Swift Package Manager

In Xcode: **File > Add Package Dependencies...** and enter this repository's URL.

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pulsely/MapTileKit.git", from: "1.0.0")
]
```

## Usage

```swift
import MapKit
import MapTileKit

let mbtilesURL = Bundle.main.url(forResource: "mytiles", withExtension: "mbtiles")!
let tileOverlay = TileOverlay(mbtilesURL: mbtilesURL)
mapView.addOverlay(tileOverlay)
```

And in your `MKMapViewDelegate`:

```swift
func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    guard let tileOverlay = overlay as? TileOverlay else { return MKOverlayRenderer(overlay: overlay) }
    return MKTileOverlayRenderer(overlay: tileOverlay)
}
```

No custom renderer is needed — `TileOverlay` is a standard `MKTileOverlay`, so the stock `MKTileOverlayRenderer` handles drawing it.

## Example

[**pulsely/MapTileKit-Example**](https://github.com/pulsely/MapTileKit-Example) is a minimal iOS app demonstrating this package end to end — one screen, one `MKMapView`, one `TileOverlay`, bundling a small sample MBTiles file. It's the easiest way to see the integration above in a complete, runnable project.

## How it works

MBTiles stores each `(zoom, column, row)` tile as a blob in a SQLite database. For each tile MapKit asks for, `TileOverlay`:

1. Looks up the matching row (converting MapKit's XYZ tile coordinates to the TMS row numbering MBTiles uses: `row = 2^zoom - y - 1`).
2. Gunzips the blob.
3. Parses it as MVT protobuf — layer names, extents, geometry types, and geometry command streams.
4. Rasterizes each feature into a `CGPath` and draws it into a PNG tile image, using a small built-in style table (fills/strokes for polygon and line layers).

Decoded tiles are cached in memory, and `canReplaceMapContent` is set so MapKit never loads its own network basemap underneath — the point of this package is to need nothing but the local file.

Since MapKit can request many tiles from one burst (a screen's worth at launch, or a whole zoom level after a pinch gesture), only the actual SQLite read is serialized (a single connection isn't safe across threads); decoding and rasterizing run on a bounded concurrent queue so a burst of requests doesn't pile up single-file, and doesn't spike memory by running unboundedly in parallel either.

## Configuration

- **`fillsMissingTilesWithBackground`** (default `true`) — some tilesets omit tiles that have nothing to draw (e.g. open ocean). With this on, a missing tile renders as a plain background tile so the map stays fully offline everywhere; set it `false` to let MapKit fall back to its own live basemap for just those tiles instead.

## Known limitations

- **Vector tiles only.** Raster (PNG/JPEG) MBTiles files aren't supported — tile blobs are assumed to be gzip-compressed MVT protobuf.
- **Zoom range is currently fixed at `0...6`** (`minimumZ`/`maximumZ`, set in `TileOverlay.init`). If your data covers a different range, edit those values before use.
- **Style is fixed.** Layers named `country`/`state` are filled and stroked, `land-border-country`/`geo-lines` are stroked only, everything else (including point/label layers) isn't drawn. There's no per-consumer styling API yet.
- Feature attributes (tags/keys/values) in the MVT data aren't parsed — only geometry.

## License

MIT — see [LICENSE](LICENSE).
