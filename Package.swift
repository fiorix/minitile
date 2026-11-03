// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "minitile",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "minitile", targets: ["minitile"]),
        .executable(name: "mntl", targets: ["mntl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(name: "MinitileCore", dependencies: ["MinitileIPC", .product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .target(name: "MinitileIPC"),
        .target(name: "CSkyLight", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]),
        .executableTarget(name: "minitile", dependencies: ["MinitileCore", "MinitileIPC", "CSkyLight"]),
        .executableTarget(name: "mntl", dependencies: ["MinitileIPC"]),
        .testTarget(name: "MinitileCoreTests", dependencies: ["MinitileCore"]),
        .testTarget(name: "MinitileIPCTests", dependencies: ["MinitileIPC"]),
    ],
    swiftLanguageModes: [.v6]
)
