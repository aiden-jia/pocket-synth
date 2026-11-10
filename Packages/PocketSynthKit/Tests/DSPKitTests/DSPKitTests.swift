import Foundation
import Testing
@testable import DSPKit

let sr = 48_000.0

func sine(_ hz: Double, seconds: Double, amp: Float = 0.5) -> AudioData {
    AudioData(mono: (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }, sampleRate: sr)
}

/// Decaying noise bursts ("hits") at the given times.
func hits(at times: [Double], seconds: Double, amps: [Float]? = nil) -> AudioData {
    var x = [Float](repeating: 0, count: Int(seconds * sr))
    var seed: UInt32 = 12345
    for (k, t) in times.enumerated() {
        let start = Int(t * sr)
        let a = amps?[k] ?? 0.8
        for i in 0..<Int(0.12 * sr) where start + i < x.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            x[start + i] += a * n * Float(exp(-Double(i) / (0.02 * sr)))
        }
    }
    return AudioData(mono: x, sampleRate: sr)
}

func zeroCrossingHz(_ x: [Float]) -> Double {
    var c = 0
    for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 { c += 1 }
    return Double(c) / (Double(x.count) / sr)
}

@Suite("Processes")
struct ProcessTests {
    @Test func levelProcesses() {
        let a = sine(100, seconds: 0.5, amp: 0.25)
        #expect(abs(a.applying(.normalize(peakDB: 0)).peak - 1) < 1e-3)
        #expect(abs(a.applying(.gain(dB: 6)).peak - 0.25 * Float.gain(dB: 6)) < 1e-3)
        let r = a.applying(.reverse)
        #expect(r.channels[0].first == a.channels[0].last)
        let f = a.applying(.fadeIn(frames: 4800))
        #expect(abs(f.channels[0][1]) < 1e-6 && f.channels[0][10_000] == a.channels[0][10_000])
        let o = a.applying(.fadeOut(frames: 4800))
        #expect(abs(o.channels[0].last!) < 1e-4)
    }

    @Test func editProcesses() {
        let a = sine(100, seconds: 1)
        #expect(a.applying(.crop(1000..<5000)).frames == 4000)
        #expect(a.applying(.delete(1000..<5000)).frames == 44_000)
        #expect(a.applying(.insertSilence(at: 10, frames: 100)).frames == 48_100)
        let s = a.applying(.silence(0..<24_000))
        #expect(s.channels[0][..<24_000].allSatisfy { $0 == 0 })
        let st = a.applying(.toStereo)
        #expect(st.channelCount == 2 && st.applying(.toMono).channelCount == 1)
    }

    @Test func trimSilenceAndDC() {
        var x = [Float](repeating: 0, count: 4800) + sine(200, seconds: 0.2).channels[0]
        let t = AudioData(mono: x, sampleRate: sr).applying(.trimSilence(thresholdDB: -40))
        #expect(t.frames == 9599) // 4800 zeros + the sine's own first zero sample trimmed
        x = sine(200, seconds: 1).channels[0].map { $0 + 0.3 }
        let dc = AudioData(mono: x, sampleRate: sr).applying(.removeDC)
        let tail = dc.channels[0][24_000...]
        #expect(abs(tail.reduce(0, +) / Float(tail.count)) < 0.01)
    }

    @Test func bitCrushQuantizes() {
        let c = sine(100, seconds: 0.1).applying(.bitCrush(bits: 3, downsample: 4))
        let levels = Set(c.channels[0].map { ($0 * 1000).rounded() })
        #expect(levels.count <= 9)
        #expect(c.channels[0][1] == c.channels[0][0] && c.channels[0][3] == c.channels[0][0])
    }
}

@Suite("Stretch and pitch")
struct StretchTests {
    @Test(arguments: [0.5, 0.8, 1.5, 2.0])
    func stretchKeepsPitch(ratio: Double) {
        let a = sine(440, seconds: 1)
        let s = a.applying(.timeStretch(ratio: ratio))
        #expect(abs(s.frames - Int(48_000 * ratio)) <= 1)
        let mid = Array(s.channels[0][(s.frames / 4)..<(s.frames * 3 / 4)])
        #expect(abs(zeroCrossingHz(mid) - 440) < 6, "ratio \(ratio): \(zeroCrossingHz(mid)) Hz")
        #expect(s.peak < 0.75)
    }

    @Test func pitchShiftKeepsLength() {
        let a = sine(440, seconds: 1)
        let up = a.applying(.pitchShift(semitones: 12))
        #expect(up.frames == a.frames)
        let mid = Array(up.channels[0][12_000..<36_000])
        #expect(abs(zeroCrossingHz(mid) - 880) < 12, "\(zeroCrossingHz(mid)) Hz")
        let down = a.applying(.pitchShift(semitones: -7))
        #expect(abs(zeroCrossingHz(Array(down.channels[0][12_000..<36_000])) - 293.7) < 8)
    }

    @Test func stereoStaysAligned() {
        let a = AudioData(channels: [sine(300, seconds: 0.5).channels[0], sine(300, seconds: 0.5).channels[0]], sampleRate: sr)
        let s = a.applying(.timeStretch(ratio: 1.3))
        #expect(s.channels[0] == s.channels[1])
    }
}

@Suite("Analysis")
struct AnalysisTests {
    @Test func findsHits() {
        let times = [0.0, 0.25, 0.5, 0.875, 1.25]
        let a = hits(at: times, seconds: 1.6)
        let found = Analysis.onsets(a, sensitivity: 0.5, minLength: 2400)
        #expect(found.count == times.count, "\(found.map { Double($0) / sr })")
        for (f, t) in zip(found, times) { #expect(abs(Double(f) / sr - t) < 0.006, "\(Double(f) / sr) vs \(t)") }
    }

    @Test func sensitivityControlsSoftHits() {
        let a = hits(at: [0, 0.3, 0.6, 0.9], seconds: 1.2, amps: [0.9, 0.05, 0.9, 0.05])
        let low = Analysis.onsets(a, sensitivity: 0.0, minLength: 2400)
        let high = Analysis.onsets(a, sensitivity: 1.0, minLength: 2400)
        #expect(low.count < high.count, "\(low.count) vs \(high.count)")
        #expect(high.count == 4)
    }

    @Test func findsSoftAttacks() {
        // Chords that fade in over 100 ms, like the synth's SHORT envelope.
        var x = [Float](repeating: 0, count: Int(3 * sr))
        for start in [0.0, 1.0, 2.0] {
            let s0 = Int(start * sr)
            for i in 0..<Int(0.95 * sr) {
                let t = Double(i) / sr
                let env = min(1, t / 0.1) * exp(-max(0, t - 0.1) * 8) // decays out before the next
                let v = sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 392 * t)
                x[s0 + i] += Float(0.2 * env * v)
            }
        }
        let found = Analysis.onsets(AudioData(mono: x, sampleRate: sr), sensitivity: 0.5, minLength: 4800)
        #expect(found.count == 3, "\(found.map { Double($0) / sr })")
        for (f, t) in zip(found, [0.0, 1.0, 2.0]) { #expect(abs(Double(f) / sr - t) < 0.06) }
    }

    @Test func minimumLengthPreventsDoubles() {
        let a = hits(at: [0, 0.3, 0.32], seconds: 0.8)
        #expect(Analysis.onsets(a, sensitivity: 1, minLength: Int(0.1 * sr)).count == 2)
    }

    @Test(arguments: [90.0, 120.0, 140.0])
    func detectsTempo(bpm: Double) {
        let beat = 60 / bpm
        let times = (0..<16).map { Double($0) * beat }
        let a = hits(at: times, seconds: 16 * beat)
        let found = Analysis.bpm(a)
        #expect(found.map { abs($0 - bpm) < 0.5 } == true, "\(String(describing: found))")
    }

    @Test func slicingHelpers() {
        #expect(Slicing.regions(frames: 1000, count: 4) == [0, 250, 500, 750])
        // 1/4 note at 120 BPM = 0.5 s.
        #expect(Slicing.grid(frames: 96_000, sampleRate: sr, bpm: 120, beats: 1) == [0, 24_000, 48_000, 72_000])
    }
}

@Suite("Pitch detection")
struct PitchTests {
    @Test(arguments: [55.0, 110.0, 261.63, 440.0, 987.77])
    func sineRoots(hz: Double) {
        let found = PitchDetect.hz(sine(hz, seconds: 0.5)) ?? 0
        #expect(abs(found - hz) / hz < 0.01, "\(found) vs \(hz)")
    }

    @Test func harmonicToneFindsTheFundamental() {
        // A sawtooth-ish tone at A3 with a decaying envelope, like a plucked sample.
        let n = Int(0.6 * sr)
        let x = (0..<n).map { i -> Float in
            let t = Double(i) / sr
            let v = (1...8).reduce(0.0) { $0 + sin(2 * .pi * 220 * Double($1) * t) / Double($1) }
            return Float(0.3 * v * exp(-t * 3))
        }
        #expect(PitchDetect.rootNote(AudioData(mono: x, sampleRate: sr)) == 57)
    }

    @Test func noiseHasNoPitch() {
        var seed: UInt32 = 7
        let x = (0..<24_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.5
        }
        #expect(PitchDetect.hz(AudioData(mono: x, sampleRate: sr)) == nil)
    }
}
