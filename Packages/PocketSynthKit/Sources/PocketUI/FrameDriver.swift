import AudioEngine
import Foundation
import Observation
import SamplerCore
#if canImport(UIKit)
import UIKit
#endif

/// Calls `tick` once per screen refresh: a CADisplayLink on iOS (up to 120 Hz on
/// ProMotion screens), a 60 Hz task elsewhere. Playheads and pad lights move in step
/// with the screen instead of on a sleep loop that drifts against it.
@MainActor
final class FrameDriver {
    private let tick: (Double) -> Void
    #if canImport(UIKit)
    private var link: CADisplayLink?
    #else
    private var task: Task<Void, Never>?
    #endif

    init(tick: @escaping (Double) -> Void) {
        self.tick = tick
    }

    func start() {
        #if canImport(UIKit)
        guard link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common) // keeps firing while a list scrolls
        self.link = link
        #else
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.fire()
            }
        }
        #endif
    }

    func stop() {
        #if canImport(UIKit)
        link?.invalidate()
        link = nil
        #else
        task?.cancel()
        task = nil
        #endif
    }

    fileprivate func fire() { tick(AppModel.now) }

    #if canImport(UIKit)
    /// CADisplayLink retains its target; this weak hop lets the driver go away.
    /// The link is on the main run loop, so it calls `fire` on the main actor.
    @MainActor
    private final class Target: NSObject {
        weak var driver: FrameDriver?
        init(_ driver: FrameDriver) { self.driver = driver }

        @objc func fire() { driver?.fire() }
    }
    #endif
}

/// Sampler pads lit by hits the engine played: sequence playback, note repeat and live
/// hits. Touches light their pad straight away through `heldPads`; this adds the rest.
@MainActor
@Observable
final class PadLights {
    /// Lit pads (program index) and the velocity of the hit that lit them.
    private(set) var flashes: [Int: Int] = [:]

    /// How long a hit keeps its pad lit.
    static let flashSeconds = 0.08

    @ObservationIgnored private var counts = [UInt32](repeating: 0, count: DrumProgram.padCount)
    @ObservationIgnored private var velocities = [UInt8](repeating: 0, count: DrumProgram.padCount)
    @ObservationIgnored private var seen = [UInt32](repeating: 0, count: DrumProgram.padCount)
    @ObservationIgnored private var litUntil = [Double](repeating: 0, count: DrumProgram.padCount)
    @ObservationIgnored private var primed = false

    func flash(_ pad: Int) -> Int? { flashes[pad] }

    /// Reads the engine's hit counters; only touches `flashes` (and so redraws pads)
    /// when a light turns on, off, or changes brightness.
    func update(_ bridge: EngineBridge, now: Double) {
        bridge.readPadHits(counts: &counts, velocities: &velocities)
        var next: [Int: Int]?
        for i in counts.indices {
            let hit = primed && counts[i] != seen[i]
            seen[i] = counts[i]
            if hit {
                litUntil[i] = now + Self.flashSeconds
                let v = Int(velocities[i])
                if flashes[i] != v {
                    if next == nil { next = flashes }
                    next![i] = v
                }
            } else if litUntil[i] > 0, now >= litUntil[i] {
                litUntil[i] = 0
                if next == nil { next = flashes }
                next![i] = nil
            }
        }
        primed = true
        if let next { flashes = next }
    }
}
