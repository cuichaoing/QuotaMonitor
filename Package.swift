// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaMonitor",
    platforms: [
        .macOS(.v13)  // SMAppService 需要 macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "QuotaMonitor",
            path: "QuotaMonitor",
            exclude: [
                "Resources/Info.plist",
                "Resources/QuotaMonitor.entitlements"
            ],
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "QuotaMonitorTests",
            dependencies: ["QuotaMonitor"],
            path: "QuotaMonitorTests"
        )
    ]
)
