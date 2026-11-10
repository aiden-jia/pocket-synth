import Foundation
import SamplerCore
import SynthCore
import SynthDSP
import Testing
@testable import AudioEngine

@MainActor
@Suite("Offline export")
struct ExportTests {
    @Test func offlineEngineRendersTheSequenceWithSharedSamples() throws {
        let url = try writeTestWAV(frames: 2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let live = EngineBridge(sampleRate: 48_000)
        let id = SampleID()
        _ = try live.samples.load(id: id, from: url)
        var pad = Pad()
        pad.layers = [PadLayer(sampleID: id)]

        let offline = EngineBridge(sampleRate: 48_000, sharing: live.samples)
        offline.apply(SamplerCommand.pad(0, pad))
        var seq = PadSequence(name: "S", bars: 1)
        seq.add(tick: 960, length: 100, pad: 0, velocity: 127)
        seq.loop = false
        offline.apply(SamplerCommand.sequence(seq))
        offline.apply(SamplerCommand.transport(playing: true, startTick: 0, countInBeats: 0))
        let out = offline.renderOffline(frames: 48_000)
        let first = out[0].firstIndex { abs($0) > 0.01 }
        #expect(first.map { abs($0 - 24_000) < 64 } == true, "\(String(describing: first))")
        // The live engine still owns the sample after the offline one is gone.
        #expect(live.samples.isLoaded(id))
    }

    @Test func wavBitDepths() throws {
        for depth in [16, 24, 32] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try SampleLibrary.writeWAV([[0.5, -0.5, 0.25], [0.5, -0.5, 0.25]], sampleRate: 48_000, to: url, bitDepth: depth)
            let b = EngineBridge(sampleRate: 48_000)
            let id = SampleID()
            _ = try b.samples.load(id: id, from: url)
            let back = try #require(b.samples.audio(for: id))
            #expect(abs(back.channels[0][1] + 0.5) < 1e-3, "\(depth)-bit")
        }
    }
}
