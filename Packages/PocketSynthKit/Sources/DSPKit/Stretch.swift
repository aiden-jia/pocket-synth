import Accelerate

/// Time stretch without changing pitch: WSOLA (waveform-similarity overlap-add).
/// Each output frame takes the input window, near its ideal position, that best lines up
/// with the natural continuation of the previous one, so periodic sounds don't phase.
/// Good on drums, loops and voice; our own implementation (no third-party code).
public enum TimeStretch {
    public static let frameSize = 2048
    static let tolerance = 512

    /// `ratio` > 1 makes it longer (slower). Output frames ≈ input × ratio.
    public static func stretch(_ audio: AudioData, ratio: Double) -> AudioData {
        let ratio = max(0.25, min(4, ratio))
        let n = frameSize, hs = n / 2
        let input = audio.frames
        let outFrames = Int((Double(input) * ratio).rounded())
        guard input > n * 2, abs(ratio - 1) > 1e-4 else { return resampleLength(audio, to: outFrames) }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let mono = audio.mono
        // Pad so every read stays in range.
        let pad = n + tolerance
        let padded = audio.channels.map { [Float](repeating: 0, count: pad) + $0 + [Float](repeating: 0, count: pad * 2) }
        let paddedMono = [Float](repeating: 0, count: pad) + mono + [Float](repeating: 0, count: pad * 2)

        var out = audio.channels.map { _ in [Float](repeating: 0, count: outFrames + n) }
        var norm = [Float](repeating: 0, count: outFrames + n)
        var prevStart = 0 // input position (unpadded) of the previous frame
        var k = 0
        while k * hs < outFrames {
            let ideal = Int(Double(k * hs) / ratio)
            var start = ideal
            if k > 0 {
                // Target: what would naturally follow the previous frame.
                let target = prevStart + hs
                start = bestMatch(paddedMono, pad: pad, target: target, around: ideal, length: n)
            }
            let o = k * hs
            for c in 0..<audio.channelCount {
                padded[c].withUnsafeBufferPointer { src in
                    for i in 0..<n { out[c][o + i] += src[pad + start + i] * window[i] }
                }
            }
            for i in 0..<n { norm[o + i] += window[i] }
            prevStart = start
            k += 1
        }
        for c in out.indices {
            for i in 0..<outFrames where norm[i] > 1e-3 { out[c][i] /= norm[i] }
            out[c].removeLast(out[c].count - outFrames)
        }
        return AudioData(channels: out, sampleRate: audio.sampleRate)
    }

    /// Offset near `around` whose window correlates best with the window at `target`.
    static func bestMatch(_ x: [Float], pad: Int, target: Int, around: Int, length n: Int) -> Int {
        let tol = tolerance
        let lo = max(-pad + 1, around - tol)
        let candidates = 2 * tol + 1
        let len = n / 2 // compare the first half: cheaper, enough for alignment
        var corr = [Float](repeating: 0, count: candidates)
        x.withUnsafeBufferPointer { p in
            let signal = p.baseAddress! + pad + lo
            let kernel = p.baseAddress! + pad + target
            vDSP_conv(signal, 1, kernel, 1, &corr, 1, vDSP_Length(candidates), vDSP_Length(len))
        }
        let best = vDSP.indexOfMaximum(corr).0
        return lo + Int(best)
    }

    /// Plain length change (changes pitch): cubic interpolation.
    public static func resampleLength(_ audio: AudioData, to frames: Int) -> AudioData {
        guard frames > 0, frames != audio.frames else { return audio }
        let step = Double(audio.frames - 1) / Double(max(1, frames - 1))
        return audio.map { x in
            var y = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let pos = Double(i) * step
                let j = Int(pos), f = Float(pos - Double(j))
                let xm1 = x[max(0, j - 1)], x0 = x[j], x1 = x[min(x.count - 1, j + 1)], x2 = x[min(x.count - 1, j + 2)]
                let c1 = 0.5 * (x1 - xm1)
                let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
                let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
                y[i] = ((c3 * f + c2) * f + c1) * f + x0
            }
            return y
        }
    }
}

/// Pitch shift that keeps the length: stretch by the pitch ratio, then resample back.
public enum PitchShift {
    public static func shift(_ audio: AudioData, semitones: Double) -> AudioData {
        guard abs(semitones) > 1e-3 else { return audio }
        let ratio = pow(2, semitones / 12)
        let longer = TimeStretch.stretch(audio, ratio: ratio)
        return TimeStretch.resampleLength(longer, to: audio.frames)
    }
}
