import CoreGraphics
import SynthCore

/// Geometry of the synth play surface, shared by the drawing (SwiftUI) and the touch
/// handling (UIKit) so they can never disagree. Landscape layout:
///
///   ┌────────┬──────────────────────────────────┬──┐
///   │        │  status screen                    │W │
///   │  stick │  [KEY] [SOUND] [MODE]             │H │
///   │        │  [1] [2] [3] [4] [5] [6] [7]      │L │
///   └────────┴──────────────────────────────────┴──┘
public struct SynthSurfaceLayout: Equatable, Sendable {
    public enum Hit: Equatable, Sendable {
        case pad(Int)
        case menu(MenuKey)
        case joystick
        case wheel
    }

    public let size: CGSize
    public let joystick: CGRect
    public let screen: CGRect
    public let menuKeys: [MenuKey: CGRect]
    public let pads: [CGRect] // index 0 = pad 1
    public let wheel: CGRect

    public init(size: CGSize) {
        self.size = size
        let m: CGFloat = 12
        let w = size.width, h = size.height

        let wheelWidth: CGFloat = 40
        wheel = CGRect(x: w - wheelWidth - m, y: m, width: wheelWidth, height: h - 2 * m)

        let stickSide = min(h - 2 * m, w * 0.3)
        joystick = CGRect(x: m, y: h - m - stickSide, width: stickSide, height: stickSide)

        let left = joystick.maxX + 2 * m
        let right = wheel.minX - m
        let width = max(0, right - left)

        let padHeight = max(64, h * 0.36)
        let padTop = h - m - padHeight
        let gap: CGFloat = 8
        let padWidth = (width - gap * 6) / 7
        pads = (0..<7).map { i in
            CGRect(x: left + CGFloat(i) * (padWidth + gap), y: padTop, width: padWidth, height: padHeight)
        }

        let keyHeight: CGFloat = 40
        let keyTop = padTop - gap - keyHeight
        let keyWidth = min(120, (width - 2 * gap) / 3)
        var keys: [MenuKey: CGRect] = [:]
        for (i, k) in MenuKey.allCases.enumerated() {
            keys[k] = CGRect(x: left + CGFloat(i) * (keyWidth + gap), y: keyTop, width: keyWidth, height: keyHeight)
        }
        menuKeys = keys

        screen = CGRect(x: left, y: m, width: width, height: max(60, keyTop - gap - m))
    }

    public var stickRadius: CGFloat { joystick.width / 2 }

    /// Which control a touch-down at `p` belongs to. Small margins make edges forgiving.
    public func hit(_ p: CGPoint) -> Hit? {
        if let i = pads.firstIndex(where: { $0.insetBy(dx: -3, dy: -6).contains(p) }) { return .pad(i + 1) }
        for k in MenuKey.allCases where menuKeys[k]!.insetBy(dx: -3, dy: -4).contains(p) { return .menu(k) }
        if wheel.insetBy(dx: -8, dy: 0).contains(p) { return .wheel }
        let c = CGPoint(x: joystick.midX, y: joystick.midY)
        if hypot(p.x - c.x, p.y - c.y) <= stickRadius * 1.15 { return .joystick }
        return nil
    }
}
