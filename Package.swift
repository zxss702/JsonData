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
        .library(name: "JsonData_Query", targets: ["JsonData_Query"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"604.0.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLite",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT")
            ]
        ),
        .target(
            name: "GRDB",
            dependencies: ["GRDBSQLite"],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT")
            ]
        ),
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
                "GRDB",
            ]
        ),
        .target(
            name: "JsonData",
            dependencies: [
                "JsonDataCore",
            ]
        ),
        .target(
            name: "JsonData_Query",
            dependencies: [
                "JsonDataCore",
            ]
        ),
        .testTarget(
            name: "JsonDataTests",
            dependencies: [
                "JsonDataCore",
                "JsonData",
                "JsonData_Query",
            ]
        )
    ]
)
