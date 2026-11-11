import SynthCore
import SynthDSP

/// Synth patches for every sound in `SoundCatalog`.
///
/// Sounds the spec lists as sample-based (piano, strings, guitars…) are **synthesized
/// stand-ins** for now. They get replaced with recorded multisamples once we have our own
/// sample set; the sampler engine already exists for that.
public enum SoundPatches {
    public static func patch(forSound index: Int) -> PSPatch {
        patch(named: SoundCatalog.all[index].name)
    }

    public static func patch(named name: String) -> PSPatch {
        switch name {
        case "Saw": return analog(.saw)
        case "Saw Bass": return analog(.saw, .square, mix: 0.4, detune: -12, octave: -1, tone: 2500)
        case "Piano": return fm(ratio: 1, index: 2.2, decay: 600, sustain: 0.15, tone: 6000)
        case "Tine EP": return fm(ratio: 1, index: 1.8, decay: 300, sustain: 0.1)
        case "Organ": return analog(.sine, .square, mix: 0.25, detune: 12, tone: 3000, gain: 1.1)
        case "Strings": return analog(.saw, .saw, mix: 0.5, detune: 0.1, tone: 4000)
        case "Horns": return analog(.saw, .square, mix: 0.3, detune: 0.05, tone: 1800, gain: 1.2)
        case "Brass": return analog(.saw, .saw, mix: 0.5, detune: 0.08, tone: 2500)
        case "E Guitar": return fm(ratio: 3, index: 1.2, decay: 200, sustain: 0.05, feedback: 0.3)
        case "Clarinet": return analog(.square, tone: 2000, gain: 0.9)
        case "Flute": return hybrid(.sine, noise: .white, level: 0.05, cutoff: 3000)
        case "Grand": return fm(ratio: 1, index: 2.8, decay: 800, sustain: 0.1, tone: 7000)
        case "Retro EP": return fm(ratio: 1, index: 1.0, decay: 600, sustain: 0.2)
        case "Choir Ah": return analog(.saw, .saw, mix: 0.5, detune: 0.12, tone: 1200, gain: 1.3)
        case "Vibes": return fm(ratio: 4, index: 1.2, decay: 150, sustain: 0.1)
        case "FM EP": return fm(ratio: 1, index: 2.0, decay: 350, sustain: 0.2)
        case "Acoustic": return fm(ratio: 2, index: 1.5, decay: 180, sustain: 0.05, feedback: 0.2, tone: 5000)
        case "Harp": return fm(ratio: 2, index: 0.9, decay: 300, sustain: 0.05)
        case "Reed Organ": return analog(.square, .saw, mix: 0.5, tone: 2200)
        case "Hum Choir": return analog(.triangle, .sine, mix: 0.2, detune: 12, tone: 900, gain: 1.3)
        case "Sine": return analog(.sine, gain: 1.1)
        case "FM Sweep": return fm(ratio: 2, index: 6, decay: 1500, sustain: 0.3, feedback: 0.2)
        case "Synth Bass": return analog(.square, .saw, mix: 0.5, detune: -12, octave: -1, tone: 1200, gain: 1.2)
        case "Click Perc": return fm(ratio: 7.1, index: 4, decay: 30, sustain: 0, gain: 0.8)
        case "Triangle": return analog(.triangle, gain: 1.1)
        case "Square": return analog(.square, gain: 0.8)
        case "Saw+Square": return analog(.saw, .square, mix: 0.5, detune: 0.05)
        case "Sea Pad": return hybrid(.sine, noise: .pink, level: 0.3, cutoff: 800, q: 2, noiseKind: .resonant)
        case "FM Piano": return fm(ratio: 1, index: 3, decay: 500, sustain: 0.1, feedback: 0.1)
        case "Wind": return noise(.resonant, cutoff: 0, q: 8, gain: 1.6)
        case "Mic Sample": return base(PS_ENGINE_SAMPLE, gain: 2.5)
        default: return analog(.saw)
        }
    }

    // MARK: Builders

    enum Wave { case saw, square, triangle, sine
        var c: Int32 {
            switch self {
            case .saw: Int32(PS_WAVE_SAW.rawValue)
            case .square: Int32(PS_WAVE_SQUARE.rawValue)
            case .triangle: Int32(PS_WAVE_TRIANGLE.rawValue)
            case .sine: Int32(PS_WAVE_SINE.rawValue)
            }
        }
    }

    enum NoiseKind { case white, pink, resonant, metallic
        var c: Int32 {
            switch self {
            case .white: Int32(PS_NOISE_WHITE.rawValue)
            case .pink: Int32(PS_NOISE_PINK.rawValue)
            case .resonant: Int32(PS_NOISE_RESONANT.rawValue)
            case .metallic: Int32(PS_NOISE_METALLIC.rawValue)
            }
        }
    }

    static func base(_ engine: PSEngineKind, gain: Float) -> PSPatch {
        var p = PSPatch()
        p.engine = Int32(engine.rawValue)
        p.noiseQ = 4
        p.gain = gain
        return p
    }

    static func analog(_ w1: Wave, _ w2: Wave? = nil, mix: Float = 0, detune: Float = 0,
                       octave: Float = 0, tone: Float = 0, gain: Float = 1) -> PSPatch {
        var p = base(PS_ENGINE_ANALOG, gain: gain)
        p.wave1 = w1.c
        p.wave2 = (w2 ?? w1).c
        p.mix2 = w2 == nil ? 0 : mix
        p.detune2 = detune
        p.octave = octave
        p.toneCutoffHz = tone
        return p
    }

    static func fm(ratio: Float, index: Float, decay: Float, sustain: Float, feedback: Float = 0,
                   tone: Float = 0, gain: Float = 1) -> PSPatch {
        var p = base(PS_ENGINE_FM, gain: gain)
        p.fmRatio = ratio
        p.fmIndex = index
        p.fmIndexDecayMs = decay
        p.fmIndexSustain = sustain
        p.fmFeedback = feedback
        p.toneCutoffHz = tone
        return p
    }

    static func hybrid(_ w: Wave, noise: NoiseKind, level: Float, cutoff: Float, q: Float = 4,
                       noiseKind: NoiseKind? = nil) -> PSPatch {
        var p = analog(w)
        p.engine = Int32(PS_ENGINE_HYBRID.rawValue)
        p.noiseKind = (noiseKind ?? noise).c
        p.noiseLevel = level
        p.noiseCutoffHz = cutoff
        p.noiseQ = q
        return p
    }

    static func noise(_ kind: NoiseKind, cutoff: Float, q: Float, gain: Float) -> PSPatch {
        var p = base(PS_ENGINE_NOISE, gain: gain)
        p.noiseKind = kind.c
        p.noiseCutoffHz = cutoff
        p.noiseQ = q
        return p
    }
}
