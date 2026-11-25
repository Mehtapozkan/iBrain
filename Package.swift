// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IBrain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IBrain", targets: ["IBrain"]),
        .library(name: "IBrainSemantics", targets: ["IBrainSemantics"]),
        .library(name: "IBrainRetrieval", targets: ["IBrainRetrieval"]),
        .library(name: "IBrainVision", targets: ["IBrainVision"])
    ],
    targets: [
        .target(name: "IBrain"),
        .target(name: "IBrainSemantics", dependencies: ["IBrain"]),
        .target(name: "IBrainRetrieval", dependencies: ["IBrain", "IBrainSemantics"]),
        .target(name: "IBrainVision", dependencies: ["IBrain", "IBrainSemantics"]),
        .executableTarget(name: "SavedPlaceEvaluation", dependencies: ["IBrain", "IBrainRetrieval"], path: "Evaluation"),
        .testTarget(name: "SavedPlaceTests", dependencies: ["IBrain", "IBrainRetrieval"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "LinkedContextTests", dependencies: ["IBrain", "IBrainSemantics", "IBrainRetrieval"],
                    resources: [.copy("Fixtures")])
    ]
)
