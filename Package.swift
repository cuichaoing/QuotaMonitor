// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaMonitor",
    platforms: [
        .macOS(.v12)  // async test 需要 macOS 12+
    ],
    targets: [
        .executableTarget(
            name: "QuotaMonitor",
            path: "QuotaMonitor",
            exclude: [
                "Resources/Info.plist",
                "Resources/QuotaMonitor.entitlements"
            ]
        ),
        .testTarget(
            name: "QuotaMonitorTests",
            dependencies: ["QuotaMonitor"],
            path: "QuotaMonitorTests"
        )
    ]
)
