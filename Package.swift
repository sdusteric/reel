// swift-tools-version: 6.4
import PackageDescription

// Static libraries built by scripts/deps.sh. Their headers are synced into
// Sources/CReelDeps/include so Swift never picks up Homebrew's FFmpeg headers.
let vendorLib = Context.packageDirectory + "/vendor/prefix/lib"

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Reel", targets: ["Reel"]),
        .executable(name: "reelctl", targets: ["reelctl"]),
    ],
    dependencies: [
        // Auto-update (app-updates CONTRACT.md). Only the Reel app target links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CReelDeps",
            path: "Sources/CReelDeps",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L\(vendorLib)"]),
                .linkedLibrary("ass"),
                .linkedLibrary("harfbuzz"),
                .linkedLibrary("freetype"),
                .linkedLibrary("fribidi"),
                .linkedLibrary("avformat"),
                .linkedLibrary("avcodec"),
                .linkedLibrary("swscale"),
                .linkedLibrary("swresample"),
                .linkedLibrary("avutil"),
                .linkedLibrary("dav1d"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"), // harfbuzz is C++
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security"),
            ]
        ),
        .target(name: "ReelCore"),
        // Objective-C exception guards for AVFoundation (Swift cannot catch NSException).
        .target(name: "ReelObjCSupport"),
        // Test doubles that raise; linked by tests only.
        .target(name: "ReelObjCTestSupport"),
        .target(name: "ReelEngine", dependencies: ["CReelDeps", "ReelCore", "ReelObjCSupport"]),
        .target(name: "ReelUI", dependencies: ["ReelCore"], swiftSettings: mainActorByDefault),
        .executableTarget(
            name: "Reel",
            dependencies: ["ReelUI", "ReelEngine", "ReelCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(name: "reelctl", dependencies: ["ReelEngine", "ReelCore", "CReelDeps"]),
        .testTarget(name: "ReelCoreTests", dependencies: ["ReelCore"]),
        .testTarget(name: "ReelEngineTests", dependencies: ["ReelEngine", "ReelCore", "CReelDeps", "ReelObjCSupport", "ReelObjCTestSupport"]),
        .testTarget(name: "ReelUITests", dependencies: ["ReelUI", "ReelCore"]),
        // The app's own wiring (Now Playing, media keys, Picture in Picture) through fakes only.
        // It links Sparkle through Reel but never creates an Updater.
        .testTarget(name: "ReelTests", dependencies: ["Reel", "ReelUI", "ReelCore"], swiftSettings: mainActorByDefault),
    ],
    swiftLanguageModes: [.v6]
)
