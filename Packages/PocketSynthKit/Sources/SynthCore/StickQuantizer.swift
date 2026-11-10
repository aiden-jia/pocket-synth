import ChordTheory
import Foundation

/// Turns a touch offset from the joystick's origin into one of 8 directions, with a
/// deadzone and angular hysteresis so the direction doesn't flicker on a boundary
/// (DESIGN §4).
public struct StickQuantizer: Sendable {
    /// Fraction of the joystick radius that counts as centered.
    public var deadzone = 0.3
    /// Extra degrees a finger must travel past a sector edge before switching.
    public var hysteresisDegrees = 6.0
    public private(set) var current: StickDirection?

    public init() {}

    /// `dx`/`dy` are screen offsets (y grows downward). Returns the new direction.
    @discardableResult
    public mutating func update(dx: Double, dy: Double, radius: Double) -> StickDirection? {
        let distance = (dx * dx + dy * dy).squareRoot()
        // Slightly smaller release zone than engage zone.
        let threshold = deadzone * radius * (current == nil ? 1.0 : 0.8)
        guard distance >= threshold, radius > 0 else {
            current = nil
            return nil
        }
        let angle = Self.normalize(atan2(-dy, dx) * 180 / .pi) // 0 = right, 90 = up
        if let c = current, Self.angularDistance(angle, Self.center(of: c)) <= 22.5 + hysteresisDegrees {
            return c
        }
        let order: [StickDirection] = [.right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight]
        current = order[Int((angle / 45).rounded()) % 8]
        return current
    }

    public mutating func reset() { current = nil }

    static func center(of d: StickDirection) -> Double {
        switch d {
        case .right: 0
        case .upRight: 45
        case .up: 90
        case .upLeft: 135
        case .left: 180
        case .downLeft: 225
        case .down: 270
        case .downRight: 315
        }
    }

    static func normalize(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a) - normalize(b))
        return min(d, 360 - d)
    }
}
