// swiftpm-sandbox-testing
//
// Linker anchor for the in-process Seatbelt sandbox/tripwire bootstrap.
//
// This file is intended to live inside a SwiftPM executable or test target so
// the bootstrap C target is force-linked and its constructor runs for direct
// `swift run` / `swift test`.

import SwiftPMSandboxTestingBootstrap

private let _swiftpmSandboxTestingBootstrapAnchor: Void = swiftpmst_force_link()
