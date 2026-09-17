// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyNoteCore",
    // macOS is listed so the whole sync engine can be unit-tested from the
    // command line in CI, without booting a simulator.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MyNoteCore", targets: ["MyNoteCore"])
    ],
    targets: [
        .target(name: "MyNoteCore"),
        .testTarget(name: "MyNoteCoreTests", dependencies: ["MyNoteCore"]),
    ]
)
