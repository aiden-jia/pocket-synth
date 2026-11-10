import Foundation
import SamplerCore
import SynthCore
import SynthDSP
import Testing
@testable import AudioEngine

@MainActor
@Suite("Sequencer through the bridge")
struct SequencerBridgeTests {
    func render(_ b: EngineBridge, seconds: Double) -> [Float] {
        let n = Int(48_000 * seconds)
        var l = [Float](repeating: 0, count: n), r = l
        var i = 0
        while i < n { // app-like 256-frame buffers
            let count = min(256, n - i)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    ps_engine_render(b.engine, lp.baseAddress! + i, rp.baseAddress! + i, Int32(count))
                }
            }
            i += count
        }
        return l
    }

    func firstOnset(_ x: [Float], after: Double = 0, threshold: Float = 0.01) -> Double? {
        let start = Int(after * 48_000)
        return x[start...].firstIndex { abs($0) > threshold }.map { Double($0) / 48_000 }
    }

    @Test func recordedHitPlaysBackOnTheNextLoop() throws {
        let url = try writeTestWAV(frames: 4_800)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let c = SamplerController()
        c.send = { b.apply($0) }
        let id = SampleID()
        let meta = try b.samples.load(id: id, from: url)
        c.addSamples([SampleInfo(id: id, name: "tone", fileName: "x.wav", frames: meta.frames,
                                 sampleRate: meta.sampleRate, channels: meta.channels)])
        c.start()
        c.setBars(1)                       // 2 s at 120 BPM
        c.setMetronome(false)
        c.setCountIn(bars: 0)
        c.record()
        _ = render(b, seconds: 0.51)       // just after beat 2
        c.padDown(gridIndex: 0, y: 0)      // late hit, corrected to 960 ticks
        _ = render(b, seconds: 0.1)
        c.padUp(gridIndex: 0)
        _ = render(b, seconds: 0.05)
        c.poll(hits: b.pollRecorded(), position: b.transportTicks, enginePlaying: b.transportPlaying)
        let events = c.sequence.tracks[0].events
        #expect(events.count == 1)
        #expect(events.first?.tick == 960)
        // The next pass plays it at 2 s + 0.5 s.
        let rest = render(b, seconds: 2.2) // 0.66 s → 2.86 s
        let onset = try #require(firstOnset(rest, after: 0.5))
        #expect(abs(onset + 0.66 - 2.5) < 0.003, "onset at \(onset + 0.66) s")
        c.stop()
        #expect(c.history.undoLabel == "Record")
    }

    @Test func noteRepeatThroughTheBridgeFollowsTempo() throws {
        let url = try writeTestWAV(frames: 2_400)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let synth = SynthController()
        synth.send = { b.apply($0) }
        synth.start()
        synth.setTempo(60)
        let c = SamplerController()
        c.send = { b.apply($0) }
        let id = SampleID()
        let meta = try b.samples.load(id: id, from: url)
        c.addSamples([SampleInfo(id: id, name: "tone", fileName: "x.wav", frames: meta.frames,
                                 sampleRate: meta.sampleRate, channels: meta.channels)])
        c.start()
        c.setNoteRepeat(true)
        c.setRepeatRate(.eighth)          // 0.5 s at 60 BPM
        _ = render(b, seconds: 0.01)
        let beat = ps_engine_beat(b.engine)
        // Wait for the next grid step so the first hit is on the grid.
        let wait = (0.5 - beat.truncatingRemainder(dividingBy: 0.5)) * 1.0 + 0.001
        _ = render(b, seconds: wait)
        c.padDown(gridIndex: 0, y: 0)
        let x = render(b, seconds: 1.2)
        var hits: [Double] = []
        var quiet = 10_000
        for (i, s) in x.enumerated() {
            if abs(s) > 0.01 { if quiet > 4_800 { hits.append(Double(i) / 48_000) }; quiet = 0 } else { quiet += 1 }
        }
        #expect(hits.count == 3, "\(hits)")
        if hits.count == 3 {
            #expect(abs((hits[1] - hits[0]) - 0.5) < 0.003)
            #expect(abs((hits[2] - hits[1]) - 0.5) < 0.003)
        }
        c.padUp(gridIndex: 0)
    }
}
