// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SQLiteo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SQLiteo", targets: ["SQLiteo"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        .package(url: "https://github.com/ZeeZide/CodeEditor.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SQLiteo",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CodeEditor", package: "CodeEditor"),
            ],
            exclude: ["Info.plist"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "SQLiteoTests",
            dependencies: ["SQLiteo"]
        ),
    ]
)
