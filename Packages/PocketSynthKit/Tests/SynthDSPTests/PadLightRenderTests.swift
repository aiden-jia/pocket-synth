import Foundation
import Testing
import SynthDSP

/// Pad lights: the engine counts every pad that sounds, so the UI can light pads that
/// the sequence (not a finger) plays.
@Suite("Pad hit counters")
struct PadLightRenderTests {
    private func hits(_ e: OfflineEngine) -> (counts: [UInt32], velocities: [UInt8]) {
        var c = [UInt32](repeating: 0, count: Int(PS_SAMPLER_PADS))
        var v = [UInt8](repeating: 0, count: Int(PS_SAMPLER_PADS))
        ps_sampler_pad_hits(e.engine, &c, &v, Int32(PS_SAMPLER_PADS))
        return (c, v)
    }

    @Test func liveHitsCountWithVelocity() {
        let e = OfflineEngine()
        e.clickPad(3)
        ps_sampler_trigger_ex(e.engine, 3, 90, 0)
        _ = e.render(seconds: 0.05)
        ps_sampler_trigger_ex(e.engine, 3, 40, 0)
        _ = e.render(seconds: 0.05)
        let h = hits(e)
        #expect(h.counts[3] == 2)
        #expect(h.velocities[3] == 40)
        #expect(h.counts[4] == 0)
    }

    @Test func sequencedHitsCount() {
        let e = OfflineEngine()
        e.clickPad(0)
        e.clickPad(1)
        // 120 BPM: pad 0 on beats 1 and 3, pad 1 on beat 2 of a one-bar loop.
        e.setSequence([event(0, pad: 0), event(960, pad: 1, velocity: 70), event(1920, pad: 0)], length: 3840)
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 1.9) // beats at 0, 0.5, 1.0 s; the loop wraps at 2 s
        let h = hits(e)
        #expect(h.counts[0] == 2)
        #expect(h.counts[1] == 1)
        #expect(h.velocities[1] == 70)
    }

    @Test func emptyPadsDoNotLight() {
        let e = OfflineEngine()
        ps_sampler_trigger_ex(e.engine, 5, 100, 0) // no sample on pad 5
        _ = e.render(seconds: 0.05)
        #expect(hits(e).counts[5] == 0)
    }
}
