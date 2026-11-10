import ChordTheory
import Foundation
import SynthCore
import SynthDSP
import Testing
@testable import AudioEngine

@MainActor
@Suite("Engine bridge")
struct EngineBridgeTests {
    func render(_ b: EngineBridge, ms: Double = 20) {
        let n = Int(48 * ms)
        var l = [Float](repeating: 0, count: n), r = l
        ps_engine_render(b.engine, &l, &r, Int32(n))
    }

    func voicing(_ notes: [Int], bass: Int? = nil) -> Voicing {
        Voicing(notes: notes, bass: bass, chord: Chord(root: 0, type: .major), name: "")
    }

    @Test func slotDiffKeepsSharedNotesAndRefCountsAcrossSlots() {
        let b = EngineBridge(sampleRate: 48_000)
        b.apply(.envelope(Envelope(attackMs: 1, decayMs: 1, sustain: 1, releaseMs: 0.1)))
        b.apply(.chord(slot: 1, voicing: voicing([60, 64, 67])))
        render(b)
        #expect(ps_engine_active_voices(b.engine) == 3)
        b.apply(.chord(slot: 1, voicing: voicing([60, 64, 67, 70])))   // C → C7
        render(b)
        #expect(ps_engine_active_voices(b.engine) == 4)
        b.apply(.chord(slot: 2, voicing: voicing([60, 65, 69], bass: 41))) // shares C
        render(b)
        #expect(ps_engine_active_voices(b.engine) == 7)                   // C counted once
        b.apply(.chord(slot: 1, voicing: nil))
        render(b)
        #expect(ps_engine_active_voices(b.engine) == 4)                   // C kept by slot 2
        b.apply(.allNotesOff)
        render(b)
        #expect(ps_engine_active_voices(b.engine) == 0)
    }

    @Test func controllerDrivesEngineEndToEnd() {
        let b = EngineBridge(sampleRate: 48_000)
        let c = SynthController()
        c.send = { b.apply($0) }
        c.start()
        c.handle(.padDown(1), at: 1)
        render(b)
        #expect(ps_engine_active_voices(b.engine) == 3)
    }

    @Test func realAudioHostRunsRenderOffMainActor() async throws {
        let host = AudioHost()
        let sr = host.prepareSession()
        let b = EngineBridge(sampleRate: sr)
        // Stop the device before `b` (and its engine) goes away, or its thread renders freed memory.
        defer { host.stop() }
        do {
            try host.start(rendering: b.engine)
        } catch {
            return // no output device (CI): nothing to check
        }
        b.apply(.volume(0)) // silent
        b.apply(.chord(slot: 1, voicing: voicing([60, 64, 67])))
        try await Task.sleep(for: .milliseconds(400))
        #expect(ps_engine_active_voices(b.engine) == 3) // render thread really ran
        b.apply(.allNotesOff)
    }
}
