import Accelerate

/// Analysis for chopping (SAMPLER_SPEC §5.2): transient detection, BPM, silence.
public enum Analysis {
    public static let fftSize = 1024
    public static let hop = 256

    /// Spectral flux per hop (normalized to 0…1): how much new energy each frame brings.
    public static func spectralFlux(_ audio: AudioData) -> [Float] {
        let x = audio.mono
        let n = fftSize
        guard x.count >= n else { return [] }
        let frames = (x.count - n) / hop + 1
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        guard let dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(dft) }
        let zeros = [Float](repeating: 0, count: n)
        var prev = [Float](repeating: 0, count: n / 2)
        var flux = [Float](repeating: 0, count: frames)
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var frame = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            let start = f * hop
            x.withUnsafeBufferPointer { p in
                vDSP.multiply(UnsafeBufferPointer(rebasing: p[start..<(start + n)]), window, result: &frame)
            }
            vDSP_DFT_Execute(dft, frame, zeros, &re, &im)
            var sum: Float = 0
            for b in 0..<(n / 2) {
                // Square-root compression: evens out the spectrum but keeps loud vs. quiet
                // hits apart (a log would make any sound after silence look the same).
                let mag = (re[b] * re[b] + im[b] * im[b]).squareRoot().squareRoot()
                sum += max(0, mag - prev[b])
                prev[b] = mag
            }
            flux[f] = sum
        }
        // Frame 0 has no previous frame: everything in it looks "new". It isn't a hit to
        // find (slice 0 always starts there), and it would dwarf the real ones.
        flux[0] = 0
        if let mx = flux.max(), mx > 0 { vDSP.multiply(1 / mx, flux, result: &flux) }
        return flux
    }

    /// Transient positions in frames (always starting with 0).
    /// `sensitivity` 0…1: higher finds more (softer) hits. `minLength` in frames.
    ///
    /// The flux is summed over ~40 ms first, so slow attacks (pads, bowed sounds, synth
    /// chords with a 100 ms attack) add up to one clear peak instead of a smear.
    public static func onsets(_ audio: AudioData, sensitivity: Double, minLength: Int) -> [Int] {
        let raw = spectralFlux(audio)
        guard !raw.isEmpty else { return [0] }
        let span = 8
        var flux = [Float](repeating: 0, count: raw.count)
        var acc: Float = 0
        for i in raw.indices {
            acc += raw[i]
            if i >= span { acc -= raw[i - span] }
            flux[i] = acc
        }
        if let mx = flux.max(), mx > 0 { vDSP.multiply(1 / mx, flux, result: &flux) }

        let delta = Float(0.30 - 0.28 * max(0, min(1, sensitivity)))
        let x = audio.mono
        // Hits quieter than −34 dB of the loudest moment are tails and noise, not slices.
        let floor = 0.02 * vDSP.maximumMagnitude(x)
        var out = [0]
        let w = 24
        for i in 1..<flux.count {
            let lo = max(0, i - w), hi = min(flux.count, i + w + 1)
            let local = flux[lo..<hi]
            let mean = local.reduce(0, +) / Float(local.count)
            guard flux[i] > mean + delta, flux[i] >= local.max()!, flux[i] > flux[i - 1] else { continue }
            // The rise happened in the last `span` hops: look for the attack there.
            let from = max(0, (i - span) * hop)
            let to = min(x.count, i * hop + fftSize)
            guard to > from, vDSP.maximumMagnitude(Array(x[from..<to])) >= floor else { continue }
            let pos = refine(x, from: from, to: to)
            if pos - out.last! >= minLength { out.append(pos) }
        }
        return out
    }

    /// The attack inside a window: just before the first sample that reaches 30 % of the
    /// window's peak, backed up to a zero crossing.
    static func refine(_ x: [Float], from: Int, to: Int) -> Int {
        guard to > from else { return from }
        var peak: Float = 0
        for i in from..<to { peak = max(peak, abs(x[i])) }
        var i = from
        while i < to, abs(x[i]) < 0.3 * peak { i += 1 }
        // Back up to the zero crossing just before it (at most 2 ms; stop at true zeros).
        var j = min(i, x.count - 1)
        let limit = max(0, j - 96)
        while j > limit, x[j - 1] != 0, (x[j - 1] > 0) == (x[j] > 0) { j -= 1 }
        return j
    }

    /// Tempo from the onset envelope's autocorrelation, constrained to 60…200 BPM. If the
    /// sample is close to a whole number of bars at that tempo, it snaps to the exact value.
    public static func bpm(_ audio: AudioData) -> Double? {
        let flux = spectralFlux(audio)
        guard flux.count > 64 else { return nil }
        let framesPerSecond = audio.sampleRate / Double(hop)
        let minLag = Int(framesPerSecond * 60 / 200), maxLag = min(flux.count / 2, Int(framesPerSecond * 60 / 60))
        guard maxLag > minLag else { return nil }
        let mean = flux.reduce(0, +) / Float(flux.count)
        let centered = flux.map { $0 - mean }
        var best = 0, bestScore = -Float.infinity
        for lag in minLag...maxLag {
            var s: Float = 0
            centered.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(centered.count - lag))
            }
            s /= Float(centered.count - lag)
            // Gentle preference for 80…160 BPM, where most music sits.
            let bpm = 60 * framesPerSecond / Double(lag)
            let weight: Float = (80...160).contains(bpm) ? 1.0 : 0.85
            if s * weight > bestScore { bestScore = s * weight; best = lag }
        }
        guard best > 0 else { return nil }
        var tempo = 60 * framesPerSecond / Double(best)
        // Snap to the loop length: beats = duration × tempo / 60, near a multiple of 4.
        let beats = audio.duration * tempo / 60
        let bars = (beats / 4).rounded()
        if bars >= 1, abs(beats - bars * 4) / (bars * 4) < 0.04 {
            tempo = bars * 4 * 60 / audio.duration
        }
        return (tempo * 100).rounded() / 100
    }

    /// First frame above `thresholdDB` (any channel), or nil if it's all quieter.
    public static func firstSound(_ audio: AudioData, thresholdDB: Float) -> Int? {
        let t = Float.gain(dB: thresholdDB)
        var first: Int?
        for c in audio.channels {
            if let i = c.firstIndex(where: { abs($0) >= t }) { first = min(first ?? i, i) }
        }
        return first
    }
}

/// Slice markers for the Regions and BPM chop methods.
public enum Slicing {
    /// `count` equal slices.
    public static func regions(frames: Int, count: Int) -> [Int] {
        let n = max(1, min(128, count))
        return (0..<n).map { $0 * frames / n }
    }

    /// A slice every `beats` at `bpm`.
    public static func grid(frames: Int, sampleRate: Double, bpm: Double, beats: Double) -> [Int] {
        let step = 60 / max(1, bpm) * beats * sampleRate
        guard step >= 1 else { return [0] }
        var out: [Int] = []
        var t = 0.0
        while Int(t) < frames, out.count < 128 {
            out.append(Int(t))
            t += step
        }
        return out
    }
}
