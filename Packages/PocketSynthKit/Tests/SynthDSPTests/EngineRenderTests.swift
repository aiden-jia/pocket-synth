import Testing
import SynthDSP

/// Offline render harness: drive the C engine with commands, render, inspect samples.
final class OfflineEngine {
    let engine: OpaquePointer
    let sampleRate = 48_000.0

    init() { engine = ps_engine_create(sampleRate) }
    deinit { ps_engine_destroy(engine) }

    func render(seconds: Double) -> (left: [Float], right: [Float]) {
        let n = Int(seconds * sampleRate)
        var l = [Float](repeating: 0, count: n)
        var r = [Float](repeating: 0, count: n)
        let block = 256
        var i = 0
        while i < n {
            let count = min(block, n - i)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    ps_engine_render(engine, lp.baseAddress! + i, rp.baseAddress! + i, Int32(count))
                }
            }
            i += count
        }
        return (l, r)
    }
}

/// Upward zero crossings per second, as a pitch estimate.
func estimatedHz(_ x: ArraySlice<Float>, sampleRate: Double) -> Double {
    let mean = x.reduce(0, +) / Float(x.count)
    var crossings = 0
    var prev = x.first! - mean
    for s in x.dropFirst() {
        let v = s - mean
        if prev < 0, v >= 0 { crossings += 1 }
        prev = v
    }
    return Double(crossings) / (Double(x.count) / sampleRate)
}

func rms(_ x: ArraySlice<Float>) -> Float {
    (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot()
}

@Suite("Engine render")
struct EngineRenderTests {
    @Test(arguments: [PS_WAVE_SAW, PS_WAVE_SQUARE, PS_WAVE_TRIANGLE, PS_WAVE_SINE])
    func a440IsInTune(wave: PSWaveform) {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_WAVEFORM, Float(wave.rawValue))
        ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 5)
        ps_engine_note_on(e.engine, 69, 1)
        let (l, r) = e.render(seconds: 1.2)
        let hzL = estimatedHz(l[4800..<52800], sampleRate: e.sampleRate)
        #expect(abs(hzL - 440) <= 2, "left \(hzL) Hz")
        // Right channel is the +7 cent partner: ~441.8 Hz.
        let hzR = estimatedHz(r[4800..<52800], sampleRate: e.sampleRate)
        #expect(abs(hzR - 441.8) <= 2, "right \(hzR) Hz")
    }

    @Test func releaseFadesToSilence() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 5)
        ps_engine_set_param(e.engine, PS_PARAM_RELEASE_MS, 100)
        ps_engine_note_on(e.engine, 60, 1)
        let (on, _) = e.render(seconds: 0.3)
        #expect(rms(on[4800...]) > 0.05)
        #expect(ps_engine_active_voices(e.engine) == 1)
        ps_engine_note_off(e.engine, 60)
        let (off, _) = e.render(seconds: 0.5)
        #expect(rms(off[(off.count - 4800)...]) < 1e-3)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }

    @Test func chordUsesOneVoicePerNoteAndRetriggersDuplicates() {
        let e = OfflineEngine()
        for n in [60, 64, 67, 36] { ps_engine_note_on(e.engine, Int32(n), 1) }
        ps_engine_note_on(e.engine, 60, 1) // duplicate: retrigger, not a new voice
        _ = e.render(seconds: 0.05)
        #expect(ps_engine_active_voices(e.engine) == 4)
        ps_engine_all_notes_off(e.engine)
        _ = e.render(seconds: 3)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }

    @Test func voiceStealingCapsAt32() {
        let e = OfflineEngine()
        for n in 30..<80 { ps_engine_note_on(e.engine, Int32(n), 0.5) }
        let (l, _) = e.render(seconds: 0.2)
        #expect(ps_engine_active_voices(e.engine) == 32)
        #expect(l.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func lowPassReducesBrightness() {
        func brightness(filter: Bool) -> Double {
            let e = OfflineEngine()
            ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 1)
            ps_engine_set_param(e.engine, PS_PARAM_FILTER_ENABLED, filter ? 1 : 0)
            ps_engine_set_param(e.engine, PS_PARAM_CUTOFF_HZ, 300)
            ps_engine_note_on(e.engine, 45, 1) // 110 Hz saw, rich harmonics
            let (l, _) = e.render(seconds: 0.5)
            // Energy of the first difference ≈ high-frequency content.
            let d = zip(l.dropFirst(), l).map { $0 - $1 }
            return Double(rms(d[4800...]) / max(rms(l[4800...]), 1e-9))
        }
        #expect(brightness(filter: true) < 0.5 * brightness(filter: false))
    }

    @Test func volumeZeroIsSilent() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_VOLUME, 0)
        ps_engine_note_on(e.engine, 60, 1)
        _ = e.render(seconds: 0.2)
        let (l, _) = e.render(seconds: 0.1)
        #expect(rms(l[...]) < 1e-4)
    }
}
