import Foundation
import SamplerCore
import SynthCore
import SynthDSP
import Testing
@testable import AudioEngine

@MainActor
@Suite("Looper and sampling through the bridge")
struct LooperBridgeTests {
    func render(_ b: EngineBridge, seconds: Double) {
        let n = Int(48_000 * seconds)
        var l = [Float](repeating: 0, count: 256), r = l
        var i = 0
        while i < n {
            let count = min(256, n - i)
            ps_engine_render(b.engine, &l, &r, Int32(count))
            i += count
        }
    }

    func sync(_ c: SynthController, _ b: EngineBridge) {
        c.updateLooper(b.looperReports, length: b.looperLength, position: b.looperPosition)
    }

    @Test func oneBarTakeLoopsAndCanBeExported() {
        let b = EngineBridge(sampleRate: 48_000)
        var st = SynthState()
        st.loopBars = 1
        st.metronome = false
        let c = SynthController(state: st)
        c.send = { b.apply($0) }
        c.start()
        c.handle(.clickDown, at: 1); c.handle(.clickUp, at: 1)   // count-in 4 beats (2 s) + 1 bar (2 s)
        render(b, seconds: 2.5); sync(c, b)
        #expect(c.looper.tracks[0].state == .record)
        c.handle(.padDown(1), at: 2)
        render(b, seconds: 1); c.handle(.padUp(1), at: 3)
        render(b, seconds: 0.6); sync(c, b)
        #expect(c.looper.tracks[0].state == .play)
        #expect(b.looperLength == 96_000)
        #expect(c.looper.cursor == 1)
        let audio = b.loopAudio(track: 0)
        #expect(audio?.channels[0].count == 96_000)
        let energy = audio.map { $0.channels[0].map { $0 * $0 }.reduce(0, +) } ?? 0
        #expect(energy > 1)
        #expect(b.loopAudio(track: 1) == nil)
    }

    @Test func resampleTakesTheSynth() {
        let b = EngineBridge(sampleRate: 48_000)
        let c = SynthController()
        c.send = { b.apply($0) }
        c.start()
        b.armRecorder(source: Int(PS_SOURCE_SYNTH.rawValue), threshold: 0, preRollFrames: 0, maxSeconds: 2)
        c.handle(.padDown(1), at: 1)
        render(b, seconds: 0.5)
        #expect(b.recorderState == .recording)
        b.stopRecorder()
        render(b, seconds: 0.01)
        let take = b.takeRecording()
        #expect(take.map { abs($0.channels[0].count - 24_000) < 300 } == true)
        render(b, seconds: 0.01)
        #expect(b.recorderState == .idle)
    }

    @Test func writtenWAVLoadsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let data: [[Float]] = [(0..<1000).map { Float($0) / 1000 }, (0..<1000).map { -Float($0) / 1000 }]
        try SampleLibrary.writeWAV(data, sampleRate: 44_100, to: url)
        let b = EngineBridge(sampleRate: 48_000)
        let id = SampleID()
        let m = try b.samples.load(id: id, from: url)
        #expect(m.frames == 1000 && m.channels == 2 && m.sampleRate == 44_100)
        let back = try #require(b.samples.audio(for: id))
        #expect(abs(back.channels[1][500] + 0.5) < 1e-6)
    }
}
