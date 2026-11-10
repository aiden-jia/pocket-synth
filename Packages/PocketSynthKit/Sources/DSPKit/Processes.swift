import Accelerate

/// Destructive sample processes (SAMPLER_SPEC §5.3). Each returns new audio.
public enum SampleProcess: Equatable, Sendable {
    case normalize(peakDB: Float = -0.3)
    case reverse
    case gain(dB: Float)
    case fadeIn(frames: Int, curve: FadeCurve = .exponential)
    case fadeOut(frames: Int, curve: FadeCurve = .exponential)
    case silence(Range<Int>)
    case insertSilence(at: Int, frames: Int)
    case crop(Range<Int>)
    case delete(Range<Int>)
    case removeDC
    case toMono
    case toStereo
    case pitchShift(semitones: Double)
    case timeStretch(ratio: Double)
    /// Lo-fi: `bits` 1...16, `downsample` ≥ 1 (sample-and-hold factor).
    case bitCrush(bits: Int, downsample: Int)
    /// Drops leading audio quieter than `thresholdDB`.
    case trimSilence(thresholdDB: Float = -50)

    public var label: String {
        switch self {
        case .normalize: "Normalize"
        case .reverse: "Reverse"
        case .gain: "Gain"
        case .fadeIn: "Fade in"
        case .fadeOut: "Fade out"
        case .silence: "Silence"
        case .insertSilence: "Insert silence"
        case .crop: "Crop"
        case .delete: "Delete"
        case .removeDC: "Remove DC"
        case .toMono: "To mono"
        case .toStereo: "To stereo"
        case .pitchShift: "Pitch shift"
        case .timeStretch: "Time stretch"
        case .bitCrush: "Bit crush"
        case .trimSilence: "Trim silence"
        }
    }
}

public enum FadeCurve: String, CaseIterable, Codable, Sendable {
    case linear, exponential, sCurve

    func value(_ x: Float) -> Float {
        switch self {
        case .linear: x
        case .exponential: x * x
        case .sCurve: x * x * (3 - 2 * x)
        }
    }
}

public extension AudioData {
    func applying(_ p: SampleProcess) -> AudioData {
        switch p {
        case .normalize(let db):
            let pk = peak
            guard pk > 0 else { return self }
            let g = Float.gain(dB: db) / pk
            return map { vDSP.multiply(g, $0) }
        case .reverse:
            return map { $0.reversed() }
        case .gain(let db):
            let g = Float.gain(dB: db)
            return map { vDSP.multiply(g, $0) }
        case .fadeIn(let n, let curve):
            let n = min(n, frames)
            return map { x in
                var y = x
                for i in 0..<n { y[i] *= curve.value(Float(i) / Float(max(1, n))) }
                return y
            }
        case .fadeOut(let n, let curve):
            let n = min(n, frames)
            return map { x in
                var y = x
                for i in 0..<n { y[frames - 1 - i] *= curve.value(Float(i) / Float(max(1, n))) }
                return y
            }
        case .silence(let range):
            let r = clamp(range)
            return map { x in
                var y = x
                for i in r { y[i] = 0 }
                return y
            }
        case .insertSilence(let at, let n):
            let at = max(0, min(frames, at))
            return map { Array($0[..<at]) + [Float](repeating: 0, count: max(0, n)) + Array($0[at...]) }
        case .crop(let range):
            return slice(range)
        case .delete(let range):
            let r = clamp(range)
            return map { Array($0[..<r.lowerBound]) + Array($0[r.upperBound...]) }
        case .removeDC:
            return map { x in
                // One-pole high-pass at ~5 Hz.
                let a = Float(exp(-2 * Double.pi * 5 / sampleRate))
                var y = x
                var px: Float = 0, py: Float = 0
                for i in x.indices {
                    py = x[i] - px + a * py
                    px = x[i]
                    y[i] = py
                }
                return y
            }
        case .toMono:
            return AudioData(mono: mono, sampleRate: sampleRate)
        case .toStereo:
            return channelCount == 2 ? self : AudioData(channels: [channels[0], channels[0]], sampleRate: sampleRate)
        case .pitchShift(let st):
            return PitchShift.shift(self, semitones: st)
        case .timeStretch(let ratio):
            return TimeStretch.stretch(self, ratio: ratio)
        case .bitCrush(let bits, let factor):
            let levels = Float(1 << max(1, min(16, bits - 1)))
            let k = max(1, factor)
            return map { x in
                var y = x
                var held: Float = 0
                for i in x.indices {
                    if i % k == 0 { held = (x[i] * levels).rounded() / levels }
                    y[i] = held
                }
                return y
            }
        case .trimSilence(let db):
            guard let start = Analysis.firstSound(self, thresholdDB: db) else { return self }
            return slice(start..<frames)
        }
    }
}
