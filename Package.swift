// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MicMux",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/n0-computer/iroh-ffi.git", exact: "1.1.0")
  ],
  targets: [
    .target(
      name: "MicMuxShared",
      path: "Shared",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "MicMux",
      dependencies: [
        "MicMuxShared",
        .product(name: "IrohLib", package: "iroh-ffi"),
      ],
      path: "Sources/MicMux",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "MicMuxTests",
      dependencies: [
        "MicMux",
        "MicMuxShared",
        .product(name: "IrohLib", package: "iroh-ffi"),
      ],
      path: "Tests/MicMuxTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
