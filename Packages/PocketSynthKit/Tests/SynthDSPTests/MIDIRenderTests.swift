import Foundation
import Testing
import SynthDSP

extension OfflineEngine {
    func midiOut() -> [PSMidiEvent] {
        var buf = [PSMidiEvent](repeating: PSMidiEvent(), count: 4096)
        let n = Int(ps_engine_poll_midi_out(engine, &buf, 4096))
        return Array(buf.prefix(n))
    }

    func notes(_ events: [PSMidiEvent]) -> [PSMidiEvent] { events.filter { $0.status & 0xE0 == 0x80 } } // 8x / 9x
}

@Suite("MIDI out and in")
struct MIDIRenderTests {
    @Test func liveChordsGoOutOnTheLiveChannel() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CHANNEL, 2)
        e.slot(1, [60, 64, 67], bass: 36)
        _ = e.render(seconds: 0.05)
        let on = e.notes(e.midiOut())
        #expect(Set(on.map(\.data1)) == [36, 60, 64, 67])
        #expect(on.allSatisfy { $0.status == 0x92 && $0.data2 == 100 })
        e.slot(1, [])
        _ = e.render(seconds: 0.01)
        #expect(e.notes(e.midiOut()).allSatisfy { $0.status == 0x82 })
    }

    @Test func arpSendsEachNoteAsItSounds() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        ps_synth_set_performer(e.engine, Int32(PS_PERF_ARP.rawValue))
        e.rhythm { $0.arpRateBeats = 0.5 }
        e.slot(1, [60, 64, 67])
        _ = e.render(seconds: 0.8)
        let ons = e.notes(e.midiOut()).filter { $0.status == 0x90 }
        #expect(ons.map(\.data1) == [60, 64, 67, 60])
    }

    @Test func drumsGoOutOnChannelTenWithGMNotes() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        ps_drum_trigger(e.engine, 1, 110)
        _ = e.render(seconds: 0.1)
        let ev = e.midiOut()
        #expect(ev.first.map { $0.status == 0x99 && $0.data1 == 38 && $0.data2 == 110 } == true)
        #expect(ev.contains { $0.status == 0x89 && $0.data1 == 38 })
    }

    @Test func clockRuns24PerBeatWithStartAndStop() {
        let e = OfflineEngine()
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 1.0) // 2 beats
        let ev = e.midiOut()
        #expect(ev.first?.status == 0xFA)
        // 48 ticks in 2 beats (the one on the boundary may land a sample early).
        #expect((48...49).contains(ev.filter { $0.status == 0xF8 }.count))
        ps_transport_stop(e.engine)
        _ = e.render(seconds: 0.01)
        #expect(e.midiOut().contains { $0.status == 0xFC })
    }

    @Test func midiTracksSendOnTheirChannel() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        e.setSequence([noteEvent(0, note: 50, target: PS_TARGET_MIDI, program: 4, length: 240)], length: 3840)
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.3)
        let n = e.notes(e.midiOut())
        #expect(n.count == 2)
        #expect(n[0].status == 0x94 && n[0].data1 == 50 && n[1].status == 0x84)
        // The off is one 1/16 later (0.125 s = 6000 frames; host time = frames here).
        #expect(abs(Int(n[1].hostTime) - Int(n[0].hostTime) - 6000) <= 32)
    }

    @Test func hostTimesFollowTheRenderCall() {
        let e = OfflineEngine()
        ps_engine_set_host_clock(e.engine, 1_000_000_000, 5_000_000) // ns, +5 ms latency
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        var l = [Float](repeating: 0, count: 480), r = l
        ps_drum_trigger(e.engine, 0, 100)
        ps_engine_render_at(e.engine, &l, &r, 480, 7_000_000_000)
        let ev = e.midiOut()
        #expect(ev.first.map { $0.hostTime == 7_005_000_000 } == true)
    }

    @Test func incomingNotesPlayTheSynthWithSustainAndPanic() {
        let e = OfflineEngine()
        ps_engine_midi_in(e.engine, 0x90, 60, 100)
        _ = e.render(seconds: 0.05)
        #expect(ps_engine_active_voices(e.engine) == 1)
        #expect(e.notes(e.midiOut()).isEmpty) // never echoed
        ps_engine_midi_in(e.engine, 0xB0, 64, 127)
        ps_engine_midi_in(e.engine, 0x80, 60, 0)
        _ = e.render(seconds: 2)
        #expect(ps_engine_active_voices(e.engine) == 1) // held by the pedal
        ps_engine_midi_in(e.engine, 0xB0, 64, 0)
        _ = e.render(seconds: 3)
        #expect(ps_engine_active_voices(e.engine) == 0)
        ps_engine_midi_in(e.engine, 0x90, 62, 100)
        ps_engine_midi_in(e.engine, 0xB0, 123, 0)
        _ = e.render(seconds: 3)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }

    @Test func drumsModeMapsGMNotes() {
        let e = OfflineEngine()
        ps_synth_set_performer(e.engine, Int32(PS_PERF_DRUMS.rawValue))
        ps_engine_midi_in(e.engine, 0x99, 36, 120)
        let (l, _) = e.render(seconds: 0.1)
        #expect(rms(l[...]) > 0.01)
    }

    @Test func loopsReplayTheirNotesOnTheTrackChannel() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
        let buf = ps_sample_create(Int32(e.sampleRate), 2, e.sampleRate)!
        ps_looper_record_first(e.engine, 2, buf, Int32(e.sampleRate / 2), 0, 1) // track 3, 0.5 s
        _ = e.render(seconds: 0.1)
        e.slot(1, [64])
        _ = e.render(seconds: 0.1)
        e.slot(1, [])
        _ = e.render(seconds: 0.35) // take ends at 0.5 s
        _ = e.midiOut()
        _ = e.render(seconds: 0.5)  // one pass of playback
        let n = e.notes(e.midiOut())
        #expect(n.contains { $0.status == 0x92 && $0.data1 == 64 })
        #expect(n.contains { $0.status == 0x82 && $0.data1 == 64 })
    }
}
