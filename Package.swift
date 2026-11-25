// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenLedger",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TokenLedger", targets: ["TokenLedger"])],
    targets: [
        .target(name: "LedgerCore"),
        .executableTarget(name: "TokenLedger", dependencies: ["LedgerCore"], resources: [.process("Resources")]),
        .testTarget(name: "TokenLedgerTests", dependencies: ["LedgerCore", "TokenLedger"]),
    ])
