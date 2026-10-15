import Foundation

/// Moves a non-Sendable value across a boundary the caller guarantees is safe.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// A value handed from a worker thread back to the waiting caller.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func set(_ value: T) {
        lock.withLock { stored = value }
    }

    var value: T? {
        lock.withLock { stored }
    }
}
