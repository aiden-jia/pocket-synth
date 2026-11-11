import Foundation
import Testing
import SynthDSP

extension OfflineEngine {
    /// A 1 s mono sine at `hz`, at this engine's rate.
    func sineSample(hz: Double, seconds: Double = 1) -> OpaquePointer {
        let n = Int(seconds * sampleRate)
        let s = ps_sample_create(Int32(n), 1, sampleRate)!
        let p = ps_sample_channel(s, 0)!
        for i in 0..<n { p[i] = Float(0.8 * sin(2 * Double.pi * hz * Double(i) / sampleRate)) }
        return s
    }

    func samplePatch() {
        var p = PSPatch()
        p.engine = Int32(PS_ENGINE_SAMPLE.rawValue)
        p.gain = 1
        p.noiseQ = 4
        ps_engine_set_patch(engine, &p)
        ps_engine_set_param(engine, PS_PARAM_ATTACK_MS, 1)
        ps_engine_set_param(engine, PS_PARAM_STEREO, 0)
    }

    /// Feeds `seconds` of input in tap-sized bursts while rendering.
    func renderWithInput(seconds: Double, input: (Int) -> Float) -> [Float] {
        var out: [Float] = []
        var t = 0
        let burst = 1024
        while Double(out.count) < seconds * sampleRate {
            var x = (0..<burst).map { input(t + $0) }
            x.withUnsafeBufferPointer { ps_engine_push_input(engine, $0.baseAddress!, $0.baseAddress!, Int32(burst)) }
            t += burst
            out += render(seconds: Double(burst) / sampleRate).left
        }
        return out
    }
}

@Suite("Phase 6: sample voice")
struct SampleVoiceTests {
    @Test func playsTheSampleTransposedFromItsRoot() {
        let e = OfflineEngine()
        e.samplePatch()
        // A 220 Hz sample whose root is A3 (57): note 69 (A4) plays it an octave up.
        ps_synth_set_sample(e.engine, e.sineSample(hz: 220), 57)
        ps_engine_note_on(e.engine, 69, 1)
        let (l, _) = e.render(seconds: 0.4)
        let hz = estimatedHz(window(l, 0.05, 0.35), sampleRate: e.sampleRate)
        #expect(abs(hz - 440) < 6, "\(hz) Hz")
    }

    @Test func voiceStopsAtTheEndOfTheSample() {
        let e = OfflineEngine()
        e.samplePatch()
        ps_synth_set_sample(e.engine, e.sineSample(hz: 220, seconds: 0.25), 57)
        ps_engine_note_on(e.engine, 57, 1) // held: the sample still ends after 0.25 s
        let (l, _) = e.render(seconds: 0.5)
        #expect(rms(window(l, 0.05, 0.2)) > 0.01)
        #expect(rms(window(l, 0.3, 0.5)) < 0.0005)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }

    @Test func releasingTheSampleSilencesIt() {
        let e = OfflineEngine()
        e.samplePatch()
        let s = e.sineSample(hz: 220, seconds: 2)
        ps_synth_set_sample(e.engine, s, 57)
        ps_engine_note_on(e.engine, 57, 1)
        _ = e.render(seconds: 0.1)
        ps_engine_release_sample(e.engine, s)
        _ = e.render(seconds: 0.05)
        #expect(ps_engine_collect_garbage(e.engine) == 1)
        let (l, _) = e.render(seconds: 0.2)
        #expect(rms(window(l, 0.05, 0.2)) < 0.0005)
    }
}

@Suite("Phase 6: vocoder")
struct VocoderTests {
    /// A held saw chord through the vocoder, with the mic modulator on for 0.5 s then off.
    @Test func micModulatorGatesTheSynth() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_WAVEFORM, Float(PS_WAVE_SAW.rawValue))
        ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 1)
        ps_engine_set_param(e.engine, PS_PARAM_FX_VOCODER, 1)
        for n in [48, 55, 60, 64] { ps_engine_note_on(e.engine, Int32(n), 1) }
        var rng = SystemRandomNumberGenerator()
        let speechLike = (0..<48_000).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
        let sr = Int(e.sampleRate)
        let out = e.renderWithInput(seconds: 1.0) { t in t < sr / 2 ? speechLike[t % speechLike.count] : 0 }
        let loud = rms(out[Int(0.15 * e.sampleRate)..<Int(0.45 * e.sampleRate)])
        let quiet = rms(out[Int(0.75 * e.sampleRate)..<Int(0.95 * e.sampleRate)])
        #expect(loud > 0.03, "vocoded level \(loud)")
        #expect(quiet < loud * 0.05, "\(quiet) vs \(loud)")
    }

    @Test func offPassesTheSynthUnchanged() {
        func level(vocoder: Float) -> Float {
            let e = OfflineEngine()
            ps_engine_set_param(e.engine, PS_PARAM_WAVEFORM, Float(PS_WAVE_SAW.rawValue))
            ps_engine_set_param(e.engine, PS_PARAM_FX_VOCODER, vocoder)
            ps_engine_note_on(e.engine, 60, 1)
            return rms(window(e.render(seconds: 0.4).left, 0.2, 0.4))
        }
        #expect(level(vocoder: 0) > 0.02)
        #expect(level(vocoder: 1) < 0.001) // no mic input: silent
    }
}
