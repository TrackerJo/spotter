// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SpotterCore", platforms: [.macOS(.v14)],
    products: [.library(name: "SpotterCore", targets: ["SpotterCore"])],
    targets: [
        .target(name: "SpotterCore", path: "spotter", exclude: ["Views", "ChatGPT", "ContentView.swift", "spotterApp.swift", "Sync/CloudSync.swift", "Info.plist", "spotter.entitlements", "Assets.xcassets"], sources: ["Core", "Store.swift", "Sync/NearbySync.swift"], resources: [.copy("exercises.json")]),
        .testTarget(name: "SpotterCoreTests", dependencies: ["SpotterCore"], path: "Tests/SpotterCoreTests", resources: [.copy("PlanImportSample.csv"), .copy("WorkoutImportSample.csv")])
    ], swiftLanguageModes: [.v5])
