import Foundation
import Testing
import SynthDSP

// Helpers ------------------------------------------------------------------------

extension OfflineEngine {
    func pluckEnvelope() {
        ps_engine_set_param(engine, PS_PARAM_ATTACK_MS, 1)
        ps_engine_set_param(engine, PS_PARAM_DECAY_MS, 30)
        ps_engine_set_param(engine, PS_PARAM_SUSTAIN, 0)
        ps_engine_set_param(engine, PS_PARAM_RELEASE_MS, 20)
    }

    /// Mono sample filled by `value(frame)`.
    func makeSample(frames: Int, _ value: (Int) -> Float) -> OpaquePointer {
        let s = ps_sample_create(Int32(frames), 1, sampleRate)!
        let data = ps_sample_channel(s, 0)!
        for i in 0..<frames { data[i] = value(i) }
        return s
    }

    func setPad(_ pad: Int, _ configure: (inout PSPadParams) -> Void) {
        var p = PSPadParams()
        p.layerCount = 1
        p.oneShot = 1
        p.level = 1
        p.sustain = 1
        p.releaseMs = 1
        p.layers.0.level = 1
        p.layers.0.velocityLow = 0
        p.layers.0.velocityHigh = 127
        configure(&p)
        ps_sampler_set_pad(engine, Int32(pad), &p)
    }
}

/// Number of frames (from the start) until the signal goes and stays silent.
func audibleLength(_ x: [Float], threshold: Float = 1e-4) -> Int {
    (x.lastIndex { abs($0) > threshold } ?? -1) + 1
}

func window(_ x: [Float], _ from: Double, _ to: Double, sr: Double = 48_000) -> ArraySlice<Float> {
    x[Int(from * sr)..<Int(to * sr)]
}

// Synth engines --------------------------------------------------------------------

@Suite("Synth engines")
struct SynthEngineTests {
    @Test func fmPatchIsInTune() {
        let e = OfflineEngine()
        var p = PSPatch()
        p.engine = Int32(PS_ENGINE_FM.rawValue)
        p.fmRatio = 1
        p.fmIndex = 0.3
        p.gain = 1
        ps_engine_set_patch(e.engine, &p)
        ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 2)
        ps_engine_note_on(e.engine, 69, 1)
        let (l, _) = e.render(seconds: 1.1)
        #expect(abs(estimatedHz(window(l, 0.1, 1.1), sampleRate: e.sampleRate) - 440) <= 2)
    }

    @Test func octaveFieldTransposes() {
        let e = OfflineEngine()
        var p = PSPatch()
        p.engine = Int32(PS_ENGINE_ANALOG.rawValue)
        p.wave1 = Int32(PS_WAVE_SINE.rawValue)
        p.octave = -1
        p.gain = 1
        ps_engine_set_patch(e.engine, &p)
        ps_engine_note_on(e.engine, 69, 1)
        let (l, _) = e.render(seconds: 1.2)
        #expect(abs(estimatedHz(window(l, 0.2, 1.2), sampleRate: e.sampleRate) - 220) <= 2)
    }

    @Test(arguments: [PS_NOISE_WHITE, PS_NOISE_PINK, PS_NOISE_RESONANT, PS_NOISE_METALLIC])
    func noiseEnginesAreAudibleAndBounded(kind: PSNoiseKind) {
        let e = OfflineEngine()
        var p = PSPatch()
        p.engine = Int32(PS_ENGINE_NOISE.rawValue)
        p.noiseKind = Int32(kind.rawValue)
        p.noiseQ = 6
        p.gain = 1
        ps_engine_set_patch(e.engine, &p)
        ps_engine_note_on(e.engine, 60, 1)
        let (l, r) = e.render(seconds: 0.5)
        #expect(rms(window(l, 0.2, 0.5)) > 0.005)
        #expect((l + r).allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func glideSlidesBetweenNotes() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_WAVEFORM, Float(PS_WAVE_SINE.rawValue))
        ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 1)
        ps_engine_set_param(e.engine, PS_PARAM_GLIDE_MS, 300)
        ps_engine_note_on(e.engine, 57, 1)            // A3, 220 Hz
        _ = e.render(seconds: 0.3)
        ps_engine_note_off(e.engine, 57)
        ps_engine_note_on(e.engine, 69, 1)            // A4, 440 Hz
        let (l, _) = e.render(seconds: 1.0)
        let early = estimatedHz(window(l, 0.0, 0.06), sampleRate: e.sampleRate)
        let late = estimatedHz(window(l, 0.6, 1.0), sampleRate: e.sampleRate)
        #expect(early < 400, "early \(early)")
        #expect(abs(late - 440) < 6, "late \(late)")
    }

    @Test func pluckWithZeroSustainEndsByItself() {
        let e = OfflineEngine()
        e.pluckEnvelope()
        ps_engine_note_on(e.engine, 60, 1)
        _ = e.render(seconds: 0.5)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }
}

// Effects ----------------------------------------------------------------------------

@Suite("Effects")
struct EffectsTests {
    @Test func delayEchoesAfterOneBeat() {
        func energyAtHalfSecond(delay: Bool, bass: Bool = false) -> Float {
            let e = OfflineEngine()
            e.pluckEnvelope()
            ps_engine_set_param(e.engine, PS_PARAM_TEMPO_BPM, 120)
            ps_engine_set_param(e.engine, PS_PARAM_FX_DELAY, delay ? 1 : 0) // 1/4 = 0.5 s
            ps_engine_note_on_ex(e.engine, 60, 1, bass ? 1 : 0)
            let (l, _) = e.render(seconds: 0.7)
            return rms(window(l, 0.49, 0.56))
        }
        #expect(energyAtHalfSecond(delay: false) < 1e-4)
        #expect(energyAtHalfSecond(delay: true) > 1e-3)
        #expect(energyAtHalfSecond(delay: true, bass: true) < 1e-4) // bass joins after the delay
    }

    @Test func reverbAddsATail() {
        func tail(_ type: Float) -> Float {
            let e = OfflineEngine()
            e.pluckEnvelope()
            ps_engine_set_param(e.engine, PS_PARAM_FX_REVERB, type)
            ps_engine_note_on(e.engine, 60, 1)
            let (l, _) = e.render(seconds: 1.0)
            return rms(window(l, 0.4, 0.6))
        }
        #expect(tail(0) < 1e-4)
        let e = OfflineEngine()
        e.pluckEnvelope()
        ps_engine_note_on(e.engine, 60, 1)
        let (l, _) = e.render(seconds: 0.1)
        let dry = rms(window(l, 0.0, 0.03))
        // Half a second after a 30 ms pluck: hall tail within 45 dB of the dry hit,
        // and the room (0.6 s RT60) has decayed far more than the hall (2.6 s).
        #expect(tail(2) > dry * 0.0056)
        #expect(tail(1) < tail(2) * 0.1)
        #expect(tail(5) > tail(2)) // AMBIENT is longest
    }

    @Test func tremoloModulatesLevel() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_WAVEFORM, Float(PS_WAVE_SINE.rawValue))
        ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 1)
        ps_engine_set_param(e.engine, PS_PARAM_TEMPO_BPM, 120)
        ps_engine_set_param(e.engine, PS_PARAM_FX_TREMOLO, 1) // 1/4 = 2 Hz
        ps_engine_note_on(e.engine, 69, 1)
        let (l, _) = e.render(seconds: 1.2)
        let levels = stride(from: 0.2, to: 1.1, by: 0.05).map { rms(window(l, $0, $0 + 0.04)) }
        #expect(levels.min()! < 0.6 * levels.max()!)
    }

    @Test func everyEffectTypeStaysFiniteAndAudible() {
        let effects: [(PSParam, Int)] = [
            (PS_PARAM_FX_DELAY, 5), (PS_PARAM_FX_CHORUS, 4), (PS_PARAM_FX_FLANGER, 4),
            (PS_PARAM_FX_DRIVE, 4), (PS_PARAM_FX_TAPE, 3), (PS_PARAM_FX_TREMOLO, 5),
            (PS_PARAM_FX_REVERB, 6),
        ]
        for (param, count) in effects {
            for type in 1...count {
                let e = OfflineEngine()
                ps_engine_set_param(e.engine, PS_PARAM_ATTACK_MS, 2)
                ps_engine_set_param(e.engine, param, Float(type))
                for n in [48, 60, 64, 67] { ps_engine_note_on(e.engine, Int32(n), 1) }
                let (l, r) = e.render(seconds: 0.6)
                #expect((l + r).allSatisfy { $0.isFinite && abs($0) <= 1 }, "\(param) \(type)")
                #expect(rms(window(l, 0.3, 0.6)) > 0.01, "\(param) \(type) silent")
            }
        }
    }
}

// Sampler ----------------------------------------------------------------------------

@Suite("Sampler")
struct SamplerRenderTests {
    @Test func oneShotPlaysWholeSampleThenStops() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 4800) { _ in 0.3 }
        e.setPad(0) { $0.layers.0.sample = s }
        ps_sampler_trigger(e.engine, 0, 127)
        let (l, _) = e.render(seconds: 0.2)
        #expect(abs(audibleLength(l) - 4800) <= 4)
        #expect(abs(l[100] - tanhf(0.3)) < 0.01) // full velocity, centre pan = unity gain
        #expect(ps_sampler_active_voices(e.engine) == 0)
    }

    @Test func noteOnModeStopsOnRelease() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 48_000) { _ in 0.3 }
        e.setPad(0) { $0.layers.0.sample = s; $0.oneShot = 0 }
        ps_sampler_trigger(e.engine, 0, 100)
        _ = e.render(seconds: 0.05)
        ps_sampler_release(e.engine, 0)
        _ = e.render(seconds: 0.05)
        #expect(ps_sampler_active_voices(e.engine) == 0)
    }

    @Test func tuneAndTrimChangeLength() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 4800) { _ in 0.3 }
        e.setPad(0) { $0.layers.0.sample = s; $0.layers.0.tuneSemitones = 12 }
        e.setPad(1) { $0.layers.0.sample = s; $0.layers.0.start = 1000; $0.layers.0.end = 2000 }
        ps_sampler_trigger(e.engine, 0, 127)
        let (a, _) = e.render(seconds: 0.2)
        #expect(abs(audibleLength(a) - 2400) <= 4)
        ps_sampler_trigger(e.engine, 1, 127)
        let (b, _) = e.render(seconds: 0.2)
        #expect(abs(audibleLength(b) - 1000) <= 4)
    }

    @Test func reversePlaysBackwards() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 4800) { Float($0) / 4800 * 0.5 } // rising ramp
        e.setPad(0) { $0.layers.0.sample = s; $0.layers.0.reverse = 1 }
        ps_sampler_trigger(e.engine, 0, 127)
        let (l, _) = e.render(seconds: 0.1)
        #expect(l[10] > l[2000])
        #expect(l[10] > 0.4)
    }

    @Test func muteGroupChokesAndMonoRetriggers() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 48_000) { _ in 0.2 }
        e.setPad(0) { $0.layers.0.sample = s; $0.muteGroup = 1 } // e.g. open hat
        e.setPad(1) { $0.layers.0.sample = s; $0.muteGroup = 1 } // closed hat
        e.setPad(2) { $0.layers.0.sample = s; $0.mono = 1 }
        ps_sampler_trigger(e.engine, 0, 127)
        _ = e.render(seconds: 0.05)
        ps_sampler_trigger(e.engine, 1, 127)
        _ = e.render(seconds: 0.01)
        #expect(ps_sampler_active_voices(e.engine) == 1)
        ps_sampler_trigger(e.engine, 2, 127)
        ps_sampler_trigger(e.engine, 2, 127)
        ps_sampler_trigger(e.engine, 2, 127)
        _ = e.render(seconds: 0.01)
        #expect(ps_sampler_active_voices(e.engine) == 2) // pad 1 + one voice of pad 2
    }

    @Test func velocityPicksTheMatchingLayer() {
        let e = OfflineEngine()
        let soft = e.makeSample(frames: 9600) { _ in 0.1 }
        let hard = e.makeSample(frames: 9600) { _ in -0.1 }
        e.setPad(0) { p in
            p.layerCount = 2
            p.layers.0.sample = soft
            p.layers.0.velocityHigh = 63
            p.layers.1 = p.layers.0
            p.layers.1.sample = hard
            p.layers.1.velocityLow = 64
            p.layers.1.velocityHigh = 127
        }
        ps_sampler_trigger(e.engine, 0, 40)
        let (a, _) = e.render(seconds: 0.25)
        ps_sampler_trigger(e.engine, 0, 120)
        let (b, _) = e.render(seconds: 0.25)
        #expect(a[100] > 0)
        #expect(b[100] < 0)
        #expect(abs(b[100]) > abs(a[100])) // louder hit
    }

    @Test func releasedSamplesAreDroppedThenFreed() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 48_000) { _ in 0.2 }
        e.setPad(0) { $0.layers.0.sample = s }
        ps_sampler_trigger(e.engine, 0, 127)
        _ = e.render(seconds: 0.01)
        #expect(ps_sampler_active_voices(e.engine) == 1)
        ps_engine_release_sample(e.engine, s)
        _ = e.render(seconds: 0.01)
        #expect(ps_sampler_active_voices(e.engine) == 0)
        #expect(ps_engine_collect_garbage(e.engine) == 1)
        ps_sampler_trigger(e.engine, 0, 127) // pad no longer references it: silent, no crash
        let (l, _) = e.render(seconds: 0.01)
        #expect(rms(l[...]) == 0)
    }

    @Test func mixerLevelsScaleEachSide() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 48_000) { _ in 0.2 }
        e.setPad(0) { $0.layers.0.sample = s }
        ps_engine_set_param(e.engine, PS_PARAM_SAMPLER_LEVEL, 0)
        ps_engine_note_on(e.engine, 60, 1)
        ps_engine_set_param(e.engine, PS_PARAM_SYNTH_LEVEL, 0)
        ps_sampler_trigger(e.engine, 0, 127)
        _ = e.render(seconds: 0.1)
        let (l, _) = e.render(seconds: 0.05)
        #expect(rms(l[...]) < 1e-4)
    }
}
