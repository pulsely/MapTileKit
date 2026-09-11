// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MapTileKit",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "MapTileKit", targets: ["MapTileKit"])
    ],
    targets: [
        .target(
            name: "MapTileKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("compression")
            ]
        )
    ]
)
