import AVFoundation
import ChordTheory
import Foundation
import SamplerCore
import SynthCore
import SynthDSP
import Testing
@testable import AudioEngine

/// Writes a mono 48 kHz WAV containing a decaying 220 Hz tone.
func writeTestWAV(frames: Int = 24_000, channels: AVAudioChannelCount = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for ch in 0..<Int(channels) {
        for i in 0..<frames {
            let t = Double(i) / 48_000
            buffer.floatChannelData![ch][i] = Float(0.5 * sin(2 * .pi * 220 * t) * exp(-3 * t))
        }
    }
    try file.write(from: buffer)
    return url
}

@MainActor
@Suite("Sampler bridge & library")
struct SamplerBridgeTests {
    func render(_ b: EngineBridge, seconds: Double) -> [Float] {
        let n = Int(48_000 * seconds)
        var l = [Float](repeating: 0, count: n), r = l
        ps_engine_render(b.engine, &l, &r, Int32(n))
        return l
    }

    @Test func importDecodesAndComputesPeaks() throws {
        let url = try writeTestWAV(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let id = SampleID()
        let meta = try b.samples.load(id: id, from: url)
        #expect(meta.frames == 24_000)
        #expect(meta.channels == 2)
        #expect(meta.sampleRate == 48_000)
        let peaks = try #require(b.samples.peaks[id])
        #expect(peaks.count == 1024)
        #expect(peaks.max.max()! > 0.4)
        #expect(peaks.min.min()! < -0.4)
    }

    @Test func padPlaysLoadedSample() throws {
        let url = try writeTestWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let c = SamplerController()
        c.send = { b.apply($0) }
        let id = SampleID()
        let meta = try b.samples.load(id: id, from: url)
        c.addSamples([SampleInfo(id: id, name: "tone", fileName: "x.wav", frames: meta.frames,
                                 sampleRate: meta.sampleRate, channels: meta.channels)])
        c.padDown(gridIndex: 0, y: 0)
        let out = render(b, seconds: 0.6)
        #expect(rms(out[0..<12_000]) > 0.05)
        #expect(rms(out[24_100...]) < 1e-4) // one-shot ended with the sample
        #expect(ps_sampler_active_voices(b.engine) == 0)
    }

    @Test func unloadFreesAfterEngineReleases() throws {
        let url = try writeTestWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let id = SampleID()
        try b.samples.load(id: id, from: url)
        b.samples.unload(id)
        #expect(!b.samples.isLoaded(id))
        _ = render(b, seconds: 0.01)
        #expect(ps_engine_collect_garbage(b.engine) == 1)
    }

    @Test func unsupportedFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        #expect(throws: (any Error).self) { try b.samples.load(id: SampleID(), from: url) }
    }

    @Test func everySoundPatchIsAudibleAndBounded() {
        for (i, sound) in SoundCatalog.all.enumerated() {
            let b = EngineBridge(sampleRate: 48_000)
            b.apply(.sound(index: i, engine: sound.engine))
            b.apply(.envelope(sound.defaultEnvelope.envelope))
            let v = Voicing(notes: [60, 64, 67], bass: 36, chord: .init(root: 0, type: .major), name: "C")
            b.apply(.chord(slot: 1, voicing: v))
            let out = render(b, seconds: 1.0)
            #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 }, "\(sound.name)")
            // Loudest 50 ms window: covers slow pads (800 ms attack) and short clicks alike.
            let loudest = stride(from: 0, to: out.count - 2400, by: 1200).map { rms(out[$0..<$0 + 2400]) }.max()!
            #expect(loudest > 0.01, "\(sound.name) is silent")
        }
    }

    @Test func fxAndMixerCommandsReachTheEngine() {
        let b = EngineBridge(sampleRate: 48_000)
        b.apply(.fx(.reverb, 2))
        b.apply(.fx(.lfo, 3))
        b.apply(.glide(.long))
        var m = SamplerMixer()
        m.masterLevel = 0
        b.apply(SamplerCommand.mixer(m))
        let v = Voicing(notes: [60], bass: nil, chord: .init(root: 0, type: .major), name: "C")
        b.apply(.chord(slot: 1, voicing: v))
        _ = render(b, seconds: 0.1)
        let out = render(b, seconds: 0.05)
        #expect(rms(out[...]) < 1e-4) // master at 0
    }
}

func rms(_ x: ArraySlice<Float>) -> Float {
    (x.map { $0 * $0 }.reduce(0, +) / Float(max(x.count, 1))).squareRoot()
}
