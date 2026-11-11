import Foundation

/// Keeps the last ~170 ms of mic input (mono) for analysis on the main thread (the tuner).
/// The input tap writes; anyone reads. A lock is fine here: the tap runs on its own
/// thread, not the real-time render thread.
public final class InputMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float]
    private var write = 0
    private var filled = 0

    public init(capacity: Int = 8192) { ring = Array(repeating: 0, count: capacity) }

    public func push(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = ring.count
        for i in 0..<frames {
            ring[write] = 0.5 * (left[i] + right[i])
            write = (write + 1) % n
        }
        filled = min(n, filled + frames)
    }

    /// The newest `count` samples, oldest first (fewer if not filled yet).
    public func latest(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, filled, ring.count)
        return (0..<n).map { ring[(write - n + $0 + ring.count) % ring.count] }
    }

    public func clear() {
        lock.lock()
        filled = 0
        lock.unlock()
    }
}
