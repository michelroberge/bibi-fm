import Foundation
import Testing

// Nothing a test does may touch the real ~/Library/Application Support/bibi.
setenv("BIBI_HOME", NSTemporaryDirectory() + "bibi-tests-" + UUID().uuidString, 1)

// Entry point for `swift run bibi-tests`; accepts swift-testing options such as --filter.
await Testing.__swiftPMEntryPoint() as Never
