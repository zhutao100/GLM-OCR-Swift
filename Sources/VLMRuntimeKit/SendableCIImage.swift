import CoreImage

/// Minimal `@unchecked Sendable` wrapper for `CIImage`, used to move images across concurrency domains.
///
/// Core Image images are immutable/value-like; this wrapper is used to satisfy Swift 6 strict concurrency checks.
public struct SendableCIImage: @unchecked Sendable {
    public let value: CIImage

    public init(_ value: CIImage) {
        self.value = value
    }
}
