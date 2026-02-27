// swift-tools-version: 6.1
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "JsonData",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "JsonData", targets: ["JsonData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.0"),
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
            name: "JsonData",
            dependencies: [
                "JsonDataMacros",
            ]
        )
    ]
)
