import Foundation
import Testing
import SynthDSP

extension OfflineEngine {
    /// One keygroup program: a 261.6 Hz sine sample rooted at C4 (60), zone 48…84.
    func sineKeygroup(program: Int32 = 0) {
        let s = makeSample(frames: 48_000) { Float(0.5 * sin(2 * .pi * 261.63 * Double($0) / 48_000)) }
        var zone = PSKeygroupZone()
        zone.lowNote = 48; zone.highNote = 84; zone.rootNote = 60
        zone.layers.0.sample = s
        zone.layers.0.level = 1
        zone.layers.0.velocityLow = 0
        zone.layers.0.velocityHigh = 127
        zone.layerCount = 1
        ps_keygroup_set_zone(engine, program, 0, &zone)
        var common = PSPadParams()
        common.level = 1; common.sustain = 1; common.releaseMs = 5; common.attackMs = 1
        ps_keygroup_set_program(engine, program, 1, &common)
    }
}

func noteEvent(_ tick: Int, note: Int, target: PSTarget, program: Int = 0, length: Int = 480) -> PSNoteEvent {
    PSNoteEvent(tick: Int32(tick), length: Int32(length), pad: Int32(note), velocity: 100, tune: 0,
                target: Int32(target.rawValue), program: Int32(program))
}

@Suite("Keygroups and note targets")
struct KeygroupRenderTests {
    @Test func keygroupPitchesFromTheRoot() {
        let e = OfflineEngine()
        e.sineKeygroup()
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 0, 72, 100)
        let (l, _) = e.render(seconds: 0.3)
        #expect(abs(estimatedHz(window(l, 0.05, 0.25), sampleRate: 48_000) - 523.3) < 6)
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 0, 72, 0)
        let (after, _) = e.render(seconds: 0.2)
        #expect(rms(window(after, 0.1, 0.2)) < 1e-4) // gated: released
    }

    @Test func notesOutsideEveryZoneAreSilent() {
        let e = OfflineEngine()
        e.sineKeygroup()
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 0, 30, 100)
        let (l, _) = e.render(seconds: 0.2)
        #expect(rms(l[...]) < 1e-5)
    }

    @Test func sequenceEventsReachEachTarget() {
        let e = OfflineEngine()
        e.sineKeygroup()
        e.sine()
        // Keygroup C5 at beat 0 (0.25 s long), synth A4 at beat 1.
        e.setSequence([noteEvent(0, note: 72, target: PS_TARGET_KEYGROUP), noteEvent(960, note: 69, target: PS_TARGET_SYNTH)],
                      length: 3840)
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 0.9)
        #expect(abs(estimatedHz(window(l, 0.05, 0.2), sampleRate: 48_000) - 523.3) < 8)
        #expect(rms(window(l, 0.3, 0.45)) < 1e-3)           // both released between
        #expect(abs(estimatedHz(window(l, 0.55, 0.7), sampleRate: 48_000) - 440) < 8)
    }

    @Test func liveNotesAreStampedWithTheirTarget() {
        let e = OfflineEngine()
        e.sineKeygroup()
        e.setSequence([], length: 3840)
        ps_transport_play(e.engine, 0, 0)
        ps_transport_set_recording(e.engine, 1, 60)
        _ = e.render(seconds: 0.25)
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 0, 64, 90)
        _ = e.render(seconds: 0.01)
        var out = [PSRecordedEvent](repeating: PSRecordedEvent(), count: 4)
        #expect(ps_engine_poll_recorded(e.engine, &out, 4) == 1)
        #expect(out[0].pad == 64 && out[0].target == Int32(PS_TARGET_KEYGROUP.rawValue))
        #expect(abs(Int(out[0].tick) - 480) <= 3)
    }

    @Test func monoKeygroupCutsThePreviousNote() {
        let e = OfflineEngine()
        e.sineKeygroup()
        var common = PSPadParams()
        common.level = 1; common.sustain = 1; common.releaseMs = 5; common.attackMs = 1; common.mono = 1
        ps_keygroup_set_program(e.engine, 0, 1, &common)
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 0, 60, 100)
        _ = e.render(seconds: 0.1)
        ps_live_note(e.engine, Int32(PS_TARGET_KEYGROUP.rawValue), 0, 67, 100)
        _ = e.render(seconds: 0.05)
        #expect(ps_sampler_active_voices(e.engine) == 1)
    }
}

@Suite("Song mode queue")
struct SequenceQueueTests {
    func compiled(_ events: [PSNoteEvent], length: Int) -> OpaquePointer {
        var ev = events
        return ps_sequence_create(&ev, Int32(ev.count), Int32(length), 1)
    }

    @Test func queuedSequenceTakesOverAtTheEnd() {
        let e = OfflineEngine()
        e.clickPad(0)
        e.setSequence([event(0)], length: 960)               // A: hit at 0, 0.5 s long
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.2)
        ps_engine_queue_sequence(e.engine, compiled([event(480)], length: 1920), 0) // B: hit at 0.25 s
        let (l, _) = e.render(seconds: 1.4)                    // 0.2 → 1.6 s
        // A ends at 0.5 s; B starts there: hits at 0.75 s and 1.75 (outside) → 0.75 only,
        // and no A hit at 1.0 s.
        #expect(near(onsets(l).map { $0 + 0.2 }, [0.75]), "\(onsets(l).map { $0 + 0.2 })")
        #expect(ps_transport_sequence_generation(e.engine) == 1)
        #expect(abs(ps_transport_ticks(e.engine) - 192) < 40)   // 1.1 s into B = 2112 ticks, wrapped at 1920
    }

    @Test func barQueueSwitchesAtTheNextBar() {
        let e = OfflineEngine()
        e.clickPad(0)
        e.setSequence([], length: 3840 * 4)                    // 4 bars
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.5)
        ps_engine_queue_sequence(e.engine, compiled([event(0)], length: 3840), 1)
        let (l, _) = e.render(seconds: 2.0)                    // bar 2 starts at 2.0 s
        #expect(near(onsets(l).map { $0 + 0.5 }, [2.0]), "\(onsets(l))")
    }

    @Test func stopDropsTheQueueAndQueueWhileStoppedSwitches() {
        let e = OfflineEngine()
        e.setSequence([], length: 960)
        ps_engine_queue_sequence(e.engine, compiled([], length: 960), 0)
        _ = e.render(seconds: 0.01)
        #expect(ps_transport_sequence_generation(e.engine) == 1)
        ps_transport_play(e.engine, 0, 0)
        ps_engine_queue_sequence(e.engine, compiled([], length: 960), 0)
        ps_transport_stop(e.engine)
        _ = e.render(seconds: 1)
        #expect(ps_transport_sequence_generation(e.engine) == 1)
        #expect(ps_engine_collect_garbage(e.engine) == 2)
    }
}

@Suite("Mixer routing")
struct MixerRoutingTests {
    func burst(_ e: OfflineEngine, output: Int32 = 0, send: Float = 0) {
        let s = e.makeSample(frames: 4800) { Float(0.5 * sin(Double($0) * 0.2)) }
        e.setPad(0) { $0.layers.0.sample = s; $0.output = output; $0.sends.0 = send }
    }

    @Test func submixLevelAndMuteApply() {
        let e = OfflineEngine()
        burst(e, output: 3)
        ps_mixer_set_submix(e.engine, 2, 1, 0, 0, Int32(PS_INSERT_NONE.rawValue), 0)
        ps_sampler_trigger(e.engine, 0, 127)
        let (on, _) = e.render(seconds: 0.08)
        #expect(rms(on[...]) > 0.1)
        ps_mixer_set_submix(e.engine, 2, 1, 0, 1, Int32(PS_INSERT_NONE.rawValue), 0) // mute
        _ = e.render(seconds: 0.05)
        ps_sampler_trigger(e.engine, 0, 127)
        let (muted, _) = e.render(seconds: 0.08)
        #expect(rms(muted[...]) < 1e-3)
    }

    @Test func lowPassInsertDarkens() {
        func brightness(_ insert: PSInsert) -> Float {
            let e = OfflineEngine()
            let s = e.makeSample(frames: 9600) { i in i % 2 == 0 ? 0.3 : -0.3 } // very bright
            e.setPad(0) { $0.layers.0.sample = s; $0.output = 1 }
            ps_mixer_set_submix(e.engine, 0, 1, 0, 0, Int32(insert.rawValue), 0.2)
            ps_sampler_trigger(e.engine, 0, 127)
            let (l, _) = e.render(seconds: 0.15)
            return rms(window(l, 0.05, 0.15))
        }
        #expect(brightness(PS_INSERT_LOWPASS) < 0.1 * brightness(PS_INSERT_NONE))
    }

    @Test func sendFeedsTheReturnTail() {
        func tail(send: Float) -> Float {
            let e = OfflineEngine()
            burst(e, send: send)
            ps_mixer_set_return(e.engine, 0, Int32(PS_RETURN_HALL.rawValue), 1)
            ps_sampler_trigger(e.engine, 0, 127)
            let (l, _) = e.render(seconds: 0.8)
            return rms(window(l, 0.3, 0.8)) // the dry burst is over by 0.1 s
        }
        #expect(tail(send: 0) < 1e-4)
        #expect(tail(send: 1) > 1e-3)
    }

    @Test func xyFilterOnlyWhileActive() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 96_000) { i in i % 2 == 0 ? 0.2 : -0.2 }
        e.setPad(0) { $0.layers.0.sample = s }
        ps_sampler_trigger(e.engine, 0, 127)
        ps_mixer_set_xy(e.engine, Int32(PS_XY_FILTER.rawValue), 0.1, 0.2, 0)
        let (dry, _) = e.render(seconds: 0.2)
        ps_mixer_set_xy(e.engine, Int32(PS_XY_FILTER.rawValue), 0.1, 0.2, 1)
        let (wet, _) = e.render(seconds: 0.3)
        #expect(rms(window(wet, 0.15, 0.3)) < 0.2 * rms(window(dry, 0.05, 0.2)))
        ps_mixer_set_xy(e.engine, Int32(PS_XY_FILTER.rawValue), 0.1, 0.2, 0)
        let (back, _) = e.render(seconds: 0.3)
        #expect(abs(rms(window(back, 0.15, 0.3)) - rms(window(dry, 0.05, 0.2))) < 0.02)
    }
}
