// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Rondelle",
    platforms: [.macOS(.v13)],
    targets: [
        // Open-source encoders built into the app (see PROVENANCE.md in each folder): WebP and MP3 output.
        .target(name: "CWebP", path: "Sources/CWebP",
                exclude: ["COPYING", "PATENTS", "PROVENANCE.md"],
                cSettings: [.headerSearchPath(".")]),
        .target(name: "CLame", path: "Sources/CLame",
                exclude: ["COPYING", "LICENSE", "PROVENANCE.md"],
                cSettings: [.headerSearchPath("."), .headerSearchPath("include"), .define("HAVE_CONFIG_H")]),
        .executableTarget(name: "Rondelle", dependencies: ["CWebP", "CLame"], path: "Sources/Rondelle"),
        // The update check, a separate process with network access, unlike the app.
        .executableTarget(name: "UpdateCheck", path: "Sources/UpdateCheck"),
        // The contact form, another separate process: only what is written there, only to its address.
        .executableTarget(name: "FeedbackSend", path: "Sources/FeedbackSend"),
    ]
)
