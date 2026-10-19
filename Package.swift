// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lantern",
    defaultLocalization: "en",
    /* macOS 26+ renders apps linked against an older SDK in the legacy
       compatibility design (old-style traffic lights, pre-Liquid Glass
       chrome). This toolchain stamps the binary's LC_BUILD_VERSION sdk field
       from the deployment target, so the target must be >= 26 for the app
       to get the native current-OS appearance. */
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Lantern", targets: ["Lantern"]),
        /* The GIF encoder on its own, so benchmarks can link it. */
        .library(name: "LanternGIF", targets: ["LanternGIF"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .target(
            name: "LanternGIF",
            path: "Sources/LanternGIF",
            /* Optimized in debug builds too. The encoder is per-pixel loops
               (palette search, dithering, LZW) that run 6–50× slower
               unoptimized: an 8 s clip took 13 s instead of 2 s, so `swift
               run` and dev.sh misrepresented the app's speed. Release
               builds are -O already. */
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "Lantern",
            dependencies: [
                "LanternGIF",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Lantern",
            linkerSettings: [
                /* Two rpaths for the two places Sparkle.framework lives:
                   ../Frameworks for the bundled app (Scripts/bundle.sh embeds
                   it at Contents/Frameworks), and the executable's own dir
                   for `swift run` — Xcode 26's build system stages the
                   framework next to the binary but writes no rpath for it. */
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path",
                ])
            ]
        ),
        .testTarget(
            name: "LanternTests",
            dependencies: ["Lantern", "LanternGIF"],
            path: "Tests/LanternTests"
        )
    ]
)
