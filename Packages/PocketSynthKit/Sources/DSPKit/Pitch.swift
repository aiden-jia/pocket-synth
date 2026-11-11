import Accelerate

/// Pitch detection (DESIGN §7): YIN (de Cheveigné & Kawahara) on the loudest stretch of
/// the sample. Used by keygroup auto-map to find each sample's root note.
public enum PitchDetect {
    /// Fundamental in Hz, or nil if nothing periodic was found. 40 Hz … 2 kHz.
    public static func hz(_ audio: AudioData, threshold: Float = 0.12) -> Double? {
        let x = audio.mono
        let sr = audio.sampleRate
        let window = min(x.count, Int(0.08 * sr))      // 80 ms
        guard window > 256 else { return nil }
        // Analyse after the attack: the loudest 80 ms, starting 10 ms past the peak.
        let peakIndex = Int(vDSP.indexOfMaximum(x.map { abs($0) }).0)
        let start = max(0, min(x.count - window, peakIndex + Int(0.01 * sr)))
        let frame = Array(x[start..<(start + window)])
        let maxLag = min(window / 2, Int(sr / 40)), minLag = max(2, Int(sr / 2000))
        guard maxLag > minLag else { return nil }
        let w = window - maxLag

        // Difference function d(τ) and its cumulative-mean-normalized form.
        var d = [Float](repeating: 0, count: maxLag + 1)
        frame.withUnsafeBufferPointer { p in
            var diff = [Float](repeating: 0, count: w)
            for tau in 1...maxLag {
                vDSP_vsub(p.baseAddress! + tau, 1, p.baseAddress!, 1, &diff, 1, vDSP_Length(w))
                var s: Float = 0
                vDSP_svesq(diff, 1, &s, vDSP_Length(w))
                d[tau] = s
            }
        }
        var cmnd = [Float](repeating: 1, count: maxLag + 1)
        var running: Float = 0
        for tau in 1...maxLag {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        // First dip under the threshold, then its local minimum.
        var tau = minLag
        while tau < maxLag, cmnd[tau] >= threshold { tau += 1 }
        if tau >= maxLag {
            tau = (minLag...maxLag).min { cmnd[$0] < cmnd[$1] }!
            guard cmnd[tau] < 0.35 else { return nil }
        }
        while tau + 1 < maxLag, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
        // Parabolic interpolation for sub-sample accuracy.
        var t = Double(tau)
        if tau > 1, tau + 1 <= maxLag {
            let a = Double(cmnd[tau - 1]), b = Double(cmnd[tau]), c = Double(cmnd[tau + 1])
            let den = a - 2 * b + c
            if abs(den) > 1e-12 { t += 0.5 * (a - c) / den }
        }
        return sr / t
    }

    /// Nearest MIDI note, or nil.
    public static func rootNote(_ audio: AudioData) -> Int? {
        hz(audio).map { Int((69 + 12 * log2($0 / 440)).rounded()) }
    }
}

extension PitchDetect {
    /// Tuner: the pitch of a short input frame; nil when it's too quiet or not pitched.
    public static func tunerHz(_ frame: [Float], sampleRate: Double, gateDB: Float = -50) -> Double? {
        guard frame.count >= 1024 else { return nil }
        guard vDSP.rootMeanSquare(frame) > pow(10, gateDB / 20) else { return nil }
        return hz(AudioData(mono: frame, sampleRate: sampleRate), threshold: 0.15)
    }

    /// Mic mode (SYNTH_SPEC §4): keep `seconds` from the first sound above `thresholdDB`
    /// (plus 10 ms before it), mono, with short fades. nil when nothing was loud enough.
    public static func micTake(_ audio: AudioData, keep seconds: Double = 1, thresholdDB: Float = -40) -> AudioData? {
        let x = audio.mono
        let gate = pow(10, thresholdDB / 20)
        guard let onset = x.firstIndex(where: { abs($0) > gate }) else { return nil }
        let start = max(0, onset - Int(0.01 * audio.sampleRate))
        let end = min(x.count, start + Int(seconds * audio.sampleRate))
        guard end - start > Int(0.05 * audio.sampleRate) else { return nil }
        var y = Array(x[start..<end])
        let fadeIn = min(y.count, Int(0.002 * audio.sampleRate)), fadeOut = min(y.count, Int(0.02 * audio.sampleRate))
        for i in 0..<fadeIn { y[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { y[y.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return AudioData(mono: y, sampleRate: audio.sampleRate)
    }

    /// Fractional MIDI pitch, e.g. 57.2 for a slightly sharp A3.
    public static func midiPitch(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }
}
