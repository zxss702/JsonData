// swift-tools-version: 6.1
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "JsonData",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "JsonData", targets: ["JsonData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"604.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .macro(
            name: "JsonDataMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        .target(
            name: "JsonDataCore",
            dependencies: [
                "JsonDataMacros",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "JsonData",
            dependencies: [
                "JsonDataCore",
            ]
        ),
        .testTarget(
            name: "JsonDataTests",
            dependencies: [
                "JsonDataCore",
                "JsonData",
            ]
        )
    ]
)
