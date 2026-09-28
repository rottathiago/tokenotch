// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokenotch",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Tokenotch", targets: ["Tokenotch"]),
        .executable(name: "TokenotchHook", targets: ["TokenotchHook"])
    ],
    targets: [
        .target(name: "TokenotchCore", path: "sources/Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "TokenotchHook", dependencies: ["TokenotchCore"], path: "sources/Hook"),
        .executableTarget(name: "Tokenotch", dependencies: ["TokenotchCore"], path: "sources",
                          exclude: ["Core", "Hook", "Resources"]),
        .testTarget(name: "TokenotchTests", dependencies: ["Tokenotch", "TokenotchCore"], path: "tests")
    ],
    swiftLanguageModes: [.v5]
)
