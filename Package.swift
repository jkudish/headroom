// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UsageMonitor", targets: ["UsageMonitor"])],
    targets: [
        .executableTarget(name: "UsageMonitor", resources: [.process("Resources")]),
        .testTarget(name: "UsageMonitorTests", dependencies: ["UsageMonitor"])
    ]
)
