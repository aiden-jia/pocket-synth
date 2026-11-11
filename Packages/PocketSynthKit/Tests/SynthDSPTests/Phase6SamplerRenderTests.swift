import Foundation
import Testing
import SynthDSP

extension OfflineEngine {
    func retroEvents() -> [PSRetroEvent] {
        var buf = [PSRetroEvent](repeating: PSRetroEvent(), count: 4096)
        let n = Int(ps_engine_poll_retro(engine, &buf, 4096))
        return Array(buf.prefix(n))
    }

    func arp(_ target: PSTarget, program: Int32 = 0, mode: PSArpMode = PS_ARP_UP, octaves: Int32 = 1,
             rate: Double = 0.5, gate: Float = 0.5, latch: Bool = false) {
        var a = PSArp(mode: Int32(mode.rawValue), octaves: octaves, rateBeats: rate, gate: gate, latch: latch ? 1 : 0)
        ps_arp_set(engine, Int32(target.rawValue), program, &a)
    }

    func midiNoteOns() -> [(note: UInt8, frame: UInt64)] {
        notes(midiOut()).filter { $0.status & 0xF0 == 0x90 }.map { ($0.data1, $0.hostTime) }
    }

    /// A clip: a mono sine of `seconds`.
    func clip(_ i: Int32, hz: Double = 220, seconds: Double = 2, mode: PSClipMode = PS_CLIP_LOOP,
              beats: Double = 0, group: Int32? = nil) {
        let s = makeSample(frames: Int(seconds * sampleRate)) { Float(0.5 * sin(2 * .pi * hz * Double($0) / 48_000)) }
        var p = PSClipParams(sample: s, mode: Int32(mode.rawValue), level: 1, beats: beats, group: group ?? i % 4)
        ps_clip_set(engine, i, &p)
    }

    func clipState(_ i: Int32) -> PSClipState { PSClipState(rawValue: UInt32(ps_clip_state(engine, i))) }
}

@Suite("Phase 6: track arpeggiator")
struct TrackArpTests {
    func midiEngine() -> OfflineEngine {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        return e
    }

    func live(_ e: OfflineEngine, _ notes: [Int32], velocity: Int32 = 100) {
        for n in notes { ps_live_note(e.engine, Int32(PS_TARGET_MIDI.rawValue), 0, n, velocity) }
    }

    @Test func liveNotesPlayUpOnTheGrid() {
        let e = midiEngine()
        e.arp(PS_TARGET_MIDI)                    // 1/8 at 120 BPM = 0.25 s
        live(e, [67, 60, 64])
        _ = e.render(seconds: 1.1)
        let ons = e.midiNoteOns()
        #expect(ons.map(\.note) == [60, 64, 67, 60, 64])
        let gaps = zip(ons.dropFirst(), ons).map { Double($0.frame - $1.frame) / 48_000 }
        #expect(gaps.allSatisfy { abs($0 - 0.25) < 0.002 }, "\(gaps)")
        // Releasing every note stops it.
        live(e, [67, 60, 64], velocity: 0)
        _ = e.render(seconds: 0.6)
        #expect(e.midiNoteOns().isEmpty)
    }

    @Test(arguments: [
        (PS_ARP_DOWN, Int32(1), [UInt8]([67, 64, 60, 67])),
        (PS_ARP_UPDOWN, Int32(1), [UInt8]([60, 64, 67, 64, 60, 64])),
        (PS_ARP_UPDOWN_INCL, Int32(1), [UInt8]([60, 64, 67, 67, 64, 60])),
        (PS_ARP_UP, Int32(2), [UInt8]([60, 64, 67, 72, 76, 79])),
        (PS_ARP_ORDER, Int32(1), [UInt8]([67, 60, 64, 67])),
    ])
    func patterns(mode: PSArpMode, octaves: Int32, expected: [UInt8]) {
        let e = midiEngine()
        e.arp(PS_TARGET_MIDI, mode: mode, octaves: octaves)
        live(e, [67, 60, 64])
        _ = e.render(seconds: 0.25 * Double(expected.count) - 0.1)
        #expect(e.midiNoteOns().map(\.note) == expected)
    }

    @Test func latchKeepsPlayingUntilANewChord() {
        let e = midiEngine()
        e.arp(PS_TARGET_MIDI, latch: true)
        live(e, [60, 64])
        live(e, [60, 64], velocity: 0)
        _ = e.render(seconds: 0.9)
        #expect(e.midiNoteOns().map(\.note) == [60, 64, 60, 64])
        live(e, [72])
        _ = e.render(seconds: 0.4)
        #expect(Set(e.midiNoteOns().map(\.note)) == [72])
    }

    @Test func sequenceNotesGoThroughTheArpToo() {
        let e = midiEngine()
        e.arp(PS_TARGET_MIDI, rate: 0.25)
        var ev = [noteEvent(0, note: 60, target: PS_TARGET_MIDI, length: 960),
                  noteEvent(0, note: 63, target: PS_TARGET_MIDI, length: 960)]
        ps_engine_set_sequence(e.engine, ps_sequence_create(&ev, 2, 4 * 960, 1))
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.6) // the notes last one beat (0.5 s): 4 sixteenths
        #expect(e.midiNoteOns().map(\.note) == [60, 63, 60, 63])
        ps_arp_set(e.engine, Int32(PS_TARGET_MIDI.rawValue), 0, nil) // removed: plain notes again
        _ = e.render(seconds: 2.0)
        #expect(e.midiNoteOns().map(\.note).sorted() == [60, 63])
    }
}

@Suite("Phase 6: retrospective record and audio tracks")
struct RetroAudioTests {
    @Test func liveHitsAreReportedOnTheBeatClockWithoutRecording() {
        let e = OfflineEngine()
        _ = e.render(seconds: 1.0)                    // beat 2
        ps_sampler_trigger(e.engine, 5, 90)
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 3, 62, 70)
        _ = e.render(seconds: 0.25)
        ps_sampler_release(e.engine, 5)
        _ = e.render(seconds: 0.01)
        let r = e.retroEvents()
        #expect(r.count == 3)
        #expect(r[0].target == Int32(PS_TARGET_DRUM.rawValue) && r[0].note == 5 && r[0].velocity == 90)
        #expect(abs(r[0].beat - 2) < 0.01)
        #expect(r[1].target == Int32(PS_TARGET_KEYGROUP.rawValue) && r[1].program == 3 && r[1].note == 62)
        #expect(r[2].velocity == 0 && abs(r[2].beat - 2.5) < 0.01)
    }

    @Test func synthPanelNotesAreReportedToo() {
        let e = OfflineEngine()
        e.slot(1, [60, 64])
        _ = e.render(seconds: 0.01)
        let r = e.retroEvents()
        #expect(Set(r.map(\.note)) == [60, 64])
        #expect(r.allSatisfy { $0.target == Int32(PS_TARGET_SYNTH.rawValue) && $0.velocity > 0 })
    }

    @Test func audioRegionPlaysFromItsTickAndIsCutAtTheEventEnd() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 96_000) { Float(0.5 * sin(2 * .pi * 330 * Double($0) / 48_000)) }
        ps_audio_set_slot(e.engine, 2, s, 1, 0)
        // Starts on beat 1 (0.5 s), lasts one beat (0.5 s) although the sample is 2 s.
        var ev = [noteEvent(960, note: 2, target: PS_TARGET_AUDIO, length: 960)]
        ps_engine_set_sequence(e.engine, ps_sequence_create(&ev, 1, 8 * 960, 0))
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 1.5)
        #expect(rms(window(l, 0.1, 0.45)) < 1e-4)
        #expect(abs(estimatedHz(window(l, 0.55, 0.95), sampleRate: 48_000) - 330) < 5)
        #expect(rms(window(l, 1.1, 1.5)) < 1e-4)
    }
}

@Suite("Phase 6: clips")
struct ClipTests {
    @Test func firstLaunchWhileStoppedStartsAtOnceAndLoops() {
        let e = OfflineEngine()
        e.clip(0, seconds: 0.5)
        ps_clip_pad(e.engine, 0, 1)
        let (l, _) = e.render(seconds: 1.2)
        #expect(e.clipState(0) == PS_CLIP_PLAYING)
        #expect(rms(window(l, 0.0, 0.1)) > 0.1)
        #expect(rms(window(l, 0.9, 1.1)) > 0.1) // looped past its 0.5 s end
        ps_clip_pad(e.engine, 0, 1) // loop: a second press stops it at the next bar (beat 4 = 2 s)
        _ = e.render(seconds: 0.5)
        #expect(e.clipState(0) == PS_CLIP_STOPPING)
        let (after, _) = e.render(seconds: 0.6)
        #expect(e.clipState(0) == PS_CLIP_STOPPED)
        #expect(rms(window(after, 0.4, 0.6)) < 1e-4)
    }

    @Test func launchesWaitForTheBarWhileTheTransportPlays() {
        let e = OfflineEngine()
        e.clip(1)
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.3)
        ps_clip_pad(e.engine, 1, 1)
        _ = e.render(seconds: 0.05)
        #expect(e.clipState(1) == PS_CLIP_QUEUED)
        let (l, _) = e.render(seconds: 2.0)         // the bar line is at 2.0 s
        #expect(rms(window(l, 0.0, 1.6)) < 1e-4)
        #expect(rms(window(l, 1.7, 1.95)) > 0.1)
        #expect(e.clipState(1) == PS_CLIP_PLAYING)
    }

    @Test func oneClipPerGroupAndBeatQuantize() {
        let e = OfflineEngine()
        ps_clip_set_quantize(e.engine, 1)
        e.clip(0, group: 0)
        e.clip(4, hz: 440, group: 0)
        ps_clip_pad(e.engine, 0, 1)
        _ = e.render(seconds: 0.2)
        ps_clip_pad(e.engine, 4, 1)                 // same group: swaps at the next beat (0.5 s)
        _ = e.render(seconds: 0.4)
        #expect(e.clipState(0) == PS_CLIP_STOPPED)
        #expect(e.clipState(4) == PS_CLIP_PLAYING)
        let (l, _) = e.render(seconds: 0.3)
        #expect(abs(estimatedHz(l[...], sampleRate: 48_000) - 440) < 6)
    }

    @Test func gatePlaysWhileHeldAndBeatsSetTheSpeed() {
        let e = OfflineEngine()
        ps_clip_set_quantize(e.engine, 0)
        // 1 s of 220 Hz played over 1 beat at 120 BPM (0.5 s): twice as fast → 440 Hz.
        e.clip(2, hz: 220, seconds: 1, mode: PS_CLIP_GATE, beats: 1)
        ps_clip_pad(e.engine, 2, 1)
        let (l, _) = e.render(seconds: 0.3)
        #expect(abs(estimatedHz(window(l, 0.02, 0.28), sampleRate: 48_000) - 440) < 6)
        ps_clip_pad(e.engine, 2, 0)
        _ = e.render(seconds: 0.05)
        #expect(e.clipState(2) == PS_CLIP_STOPPED)
    }

    @Test func liveLaunchesAreRecordedAsClipNotes() {
        let e = OfflineEngine()
        ps_clip_set_quantize(e.engine, 0)
        e.clip(3)
        ps_transport_set_recording(e.engine, 1, 0)
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.5)
        ps_clip_pad(e.engine, 3, 1)
        _ = e.render(seconds: 0.5)
        ps_clip_pad(e.engine, 3, 1)
        _ = e.render(seconds: 0.1)
        var buf = [PSRecordedEvent](repeating: PSRecordedEvent(), count: 16)
        let n = Int(ps_engine_poll_recorded(e.engine, &buf, 16))
        let hits = buf.prefix(n).filter { $0.target == Int32(PS_TARGET_CLIP.rawValue) }
        #expect(hits.map(\.velocity) == [100, 0])
        #expect(hits.map(\.pad) == [3, 3])
        #expect(abs(Int(hits[0].tick) - 960) < 40 && abs(Int(hits[1].tick) - 1920) < 40)
    }

    @Test func sequencedClipStartsAtTheEventAndStopsAtItsEnd() {
        let e = OfflineEngine()
        e.clip(5)
        var ev = [noteEvent(960, note: 5, target: PS_TARGET_CLIP, length: 960)]
        ps_engine_set_sequence(e.engine, ps_sequence_create(&ev, 1, 8 * 960, 0))
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 1.4)
        #expect(rms(window(l, 0.1, 0.45)) < 1e-4)
        #expect(rms(window(l, 0.6, 0.95)) > 0.1)
        #expect(rms(window(l, 1.1, 1.4)) < 1e-4)
    }
}
