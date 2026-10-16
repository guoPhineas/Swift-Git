// swift-tools-version: 6.4
//
//  Package.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import PackageDescription

let package = Package(
    name: "Swift-Git",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Swift-Git", targets: ["Swift_Git"]),
        .executable(name: "swift-git-benchmark", targets: ["SwiftGitBenchmark"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "Swift_Git", dependencies: ["CZlib"]),
        .executableTarget(name: "SwiftGitBenchmark", dependencies: ["Swift_Git"]),
        .testTarget(name: "Swift_GitTests", dependencies: ["Swift_Git"]),
    ],
    swiftLanguageModes: [.v6]
)
