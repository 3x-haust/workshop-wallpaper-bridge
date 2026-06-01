// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WorkshopWallpaperBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkshopWallpaperCore", targets: ["WorkshopWallpaperCore"]),
        .executable(name: "WorkshopWallpaperBridge", targets: ["WorkshopWallpaperBridgeApp"]),
        .executable(name: "wwbctl", targets: ["wwbctl"])
    ],
    targets: [
        .target(name: "WorkshopWallpaperCore"),
        .executableTarget(
            name: "WorkshopWallpaperBridgeApp",
            dependencies: ["WorkshopWallpaperCore"]
        ),
        .executableTarget(
            name: "wwbctl",
            dependencies: ["WorkshopWallpaperCore"]
        ),
        .testTarget(
            name: "WorkshopWallpaperCoreTests",
            dependencies: ["WorkshopWallpaperCore"]
        ),
        .testTarget(
            name: "WorkshopWallpaperBridgeAppTests",
            dependencies: ["WorkshopWallpaperBridgeApp"]
        )
    ]
)
