#if canImport(UIKit)
import SwiftUI
import SynthCore
import UIKit

/// Transparent multitouch layer over the synth panel. Each touch belongs to the control
/// it started on, so combos like "hold a pad + flick the stick + tap SOUND" work.
struct SynthTouchSurface: UIViewRepresentable {
    let layout: SynthSurfaceLayout
    let onEvent: (ControlEvent, Double) -> Void
    let onStickOffset: (CGVector?) -> Void

    func makeUIView(context: Context) -> SynthTouchView {
        let v = SynthTouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ view: SynthTouchView, context: Context) {
        view.layout = layout
        view.onEvent = onEvent
        view.onStickOffset = onStickOffset
    }
}

final class SynthTouchView: UIView {
    var layout = SynthSurfaceLayout(size: .zero)
    var onEvent: (ControlEvent, Double) -> Void = { _, _ in }
    var onStickOffset: (CGVector?) -> Void = { _ in }

    /// Tap shorter than this inside the deadzone = click; longer = held click.
    static let clickTime = 0.25

    private enum Owner {
        case pad(Int)
        case menu(MenuKey)
        case stick
        case wheel(lastY: CGFloat)
    }

    private var owners: [ObjectIdentifier: Owner] = [:]
    private var quantizer = StickQuantizer()
    private var stickTouch: ObjectIdentifier?
    private var stickOrigin: CGPoint = .zero
    private var stickStart = 0.0
    private var stickLeftDeadzone = false
    private var clickHeld = false
    private var clickTimer: Timer?
    private let haptics = UISelectionFeedbackGenerator()

    /// Touches that miss every control fall through to SwiftUI (the looper menu on the screen).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        layout.hit(point) == nil && owners.isEmpty ? nil : super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            let id = ObjectIdentifier(t)
            switch layout.hit(p) {
            case .pad(let n)?:
                owners[id] = .pad(n)
                onEvent(.padDown(n), t.timestamp)
            case .menu(let k)?:
                owners[id] = .menu(k)
                onEvent(.menuDown(k), t.timestamp)
            case .joystick? where stickTouch == nil:
                owners[id] = .stick
                beginStick(id, at: p, time: t.timestamp)
            case .wheel?:
                owners[id] = .wheel(lastY: p.y)
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            let p = t.location(in: self)
            switch owners[id] {
            case .stick?:
                moveStick(to: p, time: t.timestamp)
            case .wheel(let lastY)?:
                let delta = Double((lastY - p.y) / max(layout.wheel.height, 1))
                owners[id] = .wheel(lastY: p.y)
                if delta != 0 { onEvent(.wheel(delta), t.timestamp) }
            default:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            let id = ObjectIdentifier(t)
            switch owners.removeValue(forKey: id) {
            case .pad(let n)?: onEvent(.padUp(n), t.timestamp)
            case .menu(let k)?: onEvent(.menuUp(k), t.timestamp)
            case .stick?: endStick(time: t.timestamp)
            case .wheel?, nil: break
            }
        }
    }

    // MARK: Joystick

    private func beginStick(_ id: ObjectIdentifier, at p: CGPoint, time: Double) {
        stickTouch = id
        stickOrigin = p // relative stick: wherever the thumb lands is center
        stickStart = time
        stickLeftDeadzone = false
        clickHeld = false
        quantizer.reset()
        haptics.prepare()
        onStickOffset(.zero)
        clickTimer?.invalidate()
        clickTimer = Timer.scheduledTimer(withTimeInterval: Self.clickTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stickTouch != nil, !self.stickLeftDeadzone else { return }
                self.clickHeld = true
                self.onEvent(.clickDown, ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func moveStick(to p: CGPoint, time: Double) {
        let dx = Double(p.x - stickOrigin.x), dy = Double(p.y - stickOrigin.y)
        let radius = Double(layout.stickRadius)
        let before = quantizer.current
        let dir = quantizer.update(dx: dx, dy: dy, radius: radius)
        if dir != nil { stickLeftDeadzone = true }
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        let clamped = min(len, radius * 0.6)
        onStickOffset(CGVector(dx: dx / len * clamped, dy: dy / len * clamped))
        if dir != before {
            if dir != nil { haptics.selectionChanged() }
            onEvent(.stick(dir), time)
        }
    }

    private func endStick(time: Double) {
        clickTimer?.invalidate()
        clickTimer = nil
        if quantizer.current != nil { onEvent(.stick(nil), time) }
        if clickHeld {
            onEvent(.clickUp, time)
        } else if !stickLeftDeadzone, time - stickStart < Self.clickTime {
            onEvent(.clickDown, time)
            onEvent(.clickUp, time)
        }
        quantizer.reset()
        stickTouch = nil
        clickHeld = false
        onStickOffset(nil)
    }
}
#endif
