// swift-tools-version: 5.9
//
//  Package.swift
//  ParametricEQ
//
//  SwiftPM manifest. EQCore is a pure library (no AppKit/CoreAudio), the
//  executable contains the app + Core Audio engine, and EQCoreSelfTest is a
//  standalone test harness because Command Line Tools do not ship XCTest.
//
import PackageDescription

let package = Package(
    name: "ParametricEQ",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ParametricEQ", targets: ["ParametricEQ"])
    ],
    targets: [
        .target(
            name: "EQCore",
            path: "Sources/EQCore"
        ),
        .executableTarget(
            name: "ParametricEQ",
            dependencies: ["EQCore"],
            path: "Sources/ParametricEQ"
        ),
        .executableTarget(
            name: "EQCoreSelfTest",
            dependencies: ["EQCore"],
            path: "Tests/EQCoreSelfTest"
        )
    ]
)
