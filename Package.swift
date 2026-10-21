// swift-tools-version:6.0
// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .executable(name: "Toth", targets: ["CaptureApp"]),
    ],
    targets: [
        // Modelo do documento e (de)serialização. Só Foundation: manter portável.
        .target(name: "CaptureCore"),
        .executableTarget(name: "CaptureApp", dependencies: ["CaptureCore"], resources: [.copy("Resources/toth-logo.png")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
    ]
)
