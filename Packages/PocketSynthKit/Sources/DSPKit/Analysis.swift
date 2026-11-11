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
        return backToZeroCrossing(x, i)
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

// MARK: - Smart slice

public extension Analysis {
    /// Smart slice (SAMPLER_SPEC §5.2): where the one new sound in `range` starts (a vocal
    /// coming in, a hit, a new note), on its first audible sample. Nil when nothing in the
    /// range stands out from what came before it.
    ///
    /// Each boundary in the range is scored on two steps measured over ~30 ms on each side:
    /// how much louder it gets (dB, so the score doesn't depend on the sample's level), and
    /// how much of the spectrum is new (catches a note change at the same level). The best
    /// boundary is then moved back to where the sound first leaves the quiet before it, so
    /// slow attacks (a voice fading in) get their real start, not their middle.
    ///
    /// The result can be up to ~50 ms before `range` when the sound started just before it.
    static func snapOnset(_ audio: AudioData, in range: Range<Int>) -> Int? {
        let x = audio.mono
        let r = audio.clamp(range)
        guard r.count >= 256 else { return nil }
        let peak = vDSP.maximumMagnitude(x)
        guard peak > 0 else { return nil }
        // Anything 60 dB under the loudest moment counts as silence: its wobbles aren't steps.
        let floorDB = 20 * log10(peak) - 60

        let block = 128, n = 1024
        let m = max(4, Int(0.03 * audio.sampleRate) / block) // blocks per side of a boundary
        let base = max(0, r.lowerBound - (m + 1) * block)
        let blocks = (min(x.count, r.upperBound + (m + 1) * block) - base) / block
        guard blocks > 2 * m else { return nil }

        let db: [Float] = x.withUnsafeBufferPointer { p in
            (0..<blocks).map { k in
                let s = UnsafeBufferPointer(rebasing: p[(base + k * block)..<(base + (k + 1) * block)])
                return max(floorDB, 10 * log10(vDSP.meanSquare(s) + 1e-20))
            }
        }

        let spectrum = MagnitudeSpectrum(size: n)
        var best = -1, bestScore: Float = 0
        for k in m...(blocks - m) {
            let b = base + k * block
            guard r.contains(b) else { continue }
            let before = db[(k - m)..<k].reduce(0, +) / Float(m)
            let after = db[k..<(k + m)].reduce(0, +) / Float(m)
            guard after > floorDB + 6 else { continue } // nothing audible starts here
            let novelty = b - n >= 0 && b + n <= x.count
                ? spectrum.newFraction(x, before: (b - n)..<b, after: b..<(b + n)) : 0
            let score = max(0, after - before) / 6 + max(0, novelty - 0.3) * 4
            if score > bestScore { bestScore = score; best = k }
        }
        guard best >= 0, bestScore >= 1 else { return nil }
        let k = best
        let boundary = base + k * block
        var onset = boundary
        // Peak-hold envelope (≈10 ms release) from 60 ms before the boundary: unlike a short
        // RMS it doesn't dip at every zero crossing of a low voice, and it rises on the
        // first sample. The quiet level comes from 30…60 ms before, since a slow attack
        // has usually begun in the 30 ms just before the boundary.
        let lo = max(0, boundary - 2 * m * block), hi = min(x.count, boundary + m * block)
        let release = Float(exp(log(0.5) / (0.01 * audio.sampleRate)))
        var env = [Float](repeating: 0, count: hi - lo)
        var e: Float = 0
        for i in env.indices { e = max(abs(x[lo + i]), e * release); env[i] = e }
        let toDB: (Float) -> Float = { max(floorDB, 20 * log10($0 + 1e-20)) }
        let split = boundary - lo
        let warm = min(split / 4, Int(0.005 * audio.sampleRate))
        let quietEnd = max(warm + 1, split - m * block)
        let before = env[warm..<quietEnd].sorted()
        let quiet = toDB(before[Int(Double(before.count - 1) * 0.9)]) // the bed's usual peaks
        let loudest = env[split...].indices.max { env[$0] < env[$1] }!
        let loud = toDB(env[loudest])
        if loud - quiet >= 6 {
            // Walk back from the loudest point to the last moment still near the quiet
            // level (a low bar: better a hair early than clipping the attack)
            // — the sound starts on the next sample.
            let threshold = Float.gain(dB: quiet + max(3, 0.15 * (loud - quiet)))
            var i = loudest
            while i > warm, env[i - 1] >= threshold { i -= 1 }
            onset = lo + i
        }
        return backToZeroCrossing(x, onset)
    }

    /// Steps back (at most 2 ms) to the zero crossing just before `i`, so a cut there
    /// doesn't click.
    internal static func backToZeroCrossing(_ x: [Float], _ i: Int) -> Int {
        guard !x.isEmpty else { return 0 }
        var j = max(0, min(i, x.count - 1))
        let limit = max(0, j - 96)
        while j > limit, x[j - 1] != 0, (x[j - 1] > 0) == (x[j] > 0) { j -= 1 }
        return j
    }
}

/// Hann-windowed magnitude spectra for comparing two stretches of audio.
private final class MagnitudeSpectrum {
    let n: Int
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private let zeros: [Float]
    private var frame: [Float], re: [Float], im: [Float]

    init(size: Int) {
        n = size
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        zeros = [Float](repeating: 0, count: size)
        frame = zeros; re = zeros; im = zeros
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func magnitudes(_ x: [Float], _ r: Range<Int>) -> [Float] {
        x.withUnsafeBufferPointer { p in vDSP.multiply(UnsafeBufferPointer(rebasing: p[r]), window, result: &frame) }
        vDSP_DFT_Execute(setup, frame, zeros, &re, &im)
        return (0..<(n / 2)).map { (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
    }

    /// The share of `after`'s spectrum that wasn't in `before` (0 = same sound, 1 = all new).
    func newFraction(_ x: [Float], before: Range<Int>, after: Range<Int>) -> Float {
        let a = magnitudes(x, after), b = magnitudes(x, before)
        var new: Float = 0, total: Float = 0
        for i in a.indices { new += max(0, a[i] - b[i]); total += a[i] }
        return total > 0 ? new / total : 0
    }
}
