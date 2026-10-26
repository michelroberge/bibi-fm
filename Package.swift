// swift-tools-version: 6.2
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), swift-testing lives outside the default search paths.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingFlags: (swift: [SwiftSetting], linker: [LinkerSetting]) =
    FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
    ? ([.unsafeFlags(["-F", cltFrameworks])],
       [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                      "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"])])
    : ([], [])

let package = Package(
    name: "bibi",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "bibi", targets: ["bibi"])],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        // Already pulled in by Hummingbird; named here because the server uses their types directly.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "BibiCore"),
        .target(name: "BibiSkills", dependencies: ["BibiCore"]),
        .target(
            name: "BibiWeb",
            dependencies: [
                "BibiCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.copy("Static")]
        ),
        // The embedded Info.plist carries the usage descriptions macOS needs before it asks for Calendars,
        // Reminders and Contacts access (a command-line tool has no bundle to hold them).
        .executableTarget(
            name: "bibi",
            dependencies: ["BibiCore", "BibiSkills", "BibiWeb"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", Context.packageDirectory + "/Sources/bibi/Info.plist"])]
        ),
        // Tests run as an executable (`swift run bibi-tests` / `make test`): with only the Command Line Tools,
        // `swift test` builds swift-testing suites but its runner never starts them.
        .executableTarget(
            name: "bibi-tests",
            dependencies: ["BibiCore", "BibiSkills", "BibiWeb", .product(name: "HummingbirdTesting", package: "hummingbird")],
            path: "Tests/BibiTests",
            resources: [.copy("Fixtures")],
            swiftSettings: testingFlags.swift + [.unsafeFlags(["-enable-testing"])],
            linkerSettings: testingFlags.linker
        ),
    ]
)
