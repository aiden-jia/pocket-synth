import Foundation
import SamplerCore
import SynthCore
import SynthDSP
import Testing
@testable import AudioEngine

@MainActor
@Suite("Sampler extras through the bridge")
struct SamplerExtrasBridgeTests {
    func render(_ b: EngineBridge, seconds: Double) -> [Float] { b.renderOffline(frames: Int(48_000 * seconds))[0] }

    func midiNoteOns(_ b: EngineBridge) -> [UInt8] {
        var buf = [PSMidiEvent](repeating: PSMidiEvent(), count: 512)
        let n = Int(ps_engine_poll_midi_out(b.engine, &buf, 512))
        return buf.prefix(n).filter { $0.status & 0xF0 == 0x90 }.map(\.data1)
    }

    @Test func arpOnATrackArpeggiatesLiveNotes() {
        let b = EngineBridge(sampleRate: 48_000)
        let c = SamplerController()
        c.send = { b.apply($0) }
        b.apply(EngineCommand.midiOut(true))
        ps_engine_set_param(b.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        c.addTrack(.midi(channel: 1))
        c.setTrackArp(c.trackIndex) { $0.on = true; $0.rate = .eighth }
        c.padDown(gridIndex: 0)   // Pad Perform: C3 (48)
        c.padDown(gridIndex: 4)   // E3 (52)
        _ = render(b, seconds: 0.9)
        #expect(midiNoteOns(b) == [48, 52, 48, 52])
        c.setTrackArp(c.trackIndex) { $0.on = false }
        _ = render(b, seconds: 0.6)
        #expect(midiNoteOns(b).isEmpty) // the arp is gone: held notes no longer step
    }

    @Test func audioTrackPlaysItsClipWithTheSequence() throws {
        let url = try writeTestWAV(frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let c = SamplerController()
        c.send = { b.apply($0) }
        let id = SampleID()
        let m = try b.samples.load(id: id, from: url)
        c.addAudioTrack(SampleInfo(id: id, name: "a", fileName: "a.wav", frames: m.frames, sampleRate: 48_000, channels: 1),
                        startTick: 960)
        c.play()
        let out = render(b, seconds: 1.0)
        #expect(out[..<23_000].allSatisfy { abs($0) < 1e-4 })     // starts on beat 2 (0.5 s)
        #expect(out[24_200..<30_000].contains { abs($0) > 0.1 })
        c.setTrackMute(true)
        let events = EngineBridge.engineEvents(c.sequence)
        #expect(!events.contains { $0.target == Int32(PS_TARGET_AUDIO.rawValue) })
    }

    @Test func clipProgramLaunchesFromThePads() throws {
        let url = try writeTestWAV(frames: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = EngineBridge(sampleRate: 48_000)
        let c = SamplerController()
        c.send = { b.apply($0) }
        let id = SampleID()
        let m = try b.samples.load(id: id, from: url)
        c.addSamples([SampleInfo(id: id, name: "l", fileName: "l.wav", frames: m.frames, sampleRate: 48_000, channels: 1)],
                     autoAssign: false)
        c.updateClips { $0.pads[2] = ClipPad(sampleID: id) }
        c.addTrack(.clip)
        c.padDown(gridIndex: 2)
        let out = render(b, seconds: 0.2)
        #expect(out.contains { abs($0) > 0.1 })
        c.updateClipStates(b.clipStates)
        #expect(c.clipStates[2] == .playing)
    }

    @Test func retroEventsMapToDestinations() {
        let b = EngineBridge(sampleRate: 48_000)
        b.apply(SamplerCommand.trigger(pad: 7, velocity: 80))
        b.apply(SamplerCommand.liveNote(.midi(channel: 3), note: 61, velocity: 90))
        _ = render(b, seconds: 0.01)
        let r = b.pollRetro(time: 5)
        #expect(r.map(\.destination) == [.pad, .midi(channel: 3)])
        #expect(r.map(\.note) == [7, 61] && r.allSatisfy { $0.time == 5 })
    }
}
