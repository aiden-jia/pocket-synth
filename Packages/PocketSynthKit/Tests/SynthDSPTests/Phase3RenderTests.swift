import Foundation
import Testing
import SynthDSP

// Helpers ------------------------------------------------------------------------

/// Times (seconds) where the signal jumps above `threshold` after at least `gap` of quiet.
func onsets(_ x: [Float], threshold: Float = 0.02, gap: Double = 0.03, sr: Double = 48_000) -> [Double] {
    var out: [Double] = []
    var quiet = Int(gap * sr)
    let need = Int(gap * sr)
    for (i, s) in x.enumerated() {
        if abs(s) > threshold {
            if quiet >= need { out.append(Double(i) / sr) }
            quiet = 0
        } else {
            quiet += 1
        }
    }
    return out
}

func near(_ a: [Double], _ b: [Double], tolerance: Double = 0.002) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

extension OfflineEngine {
    /// A 20 ms click on `pad` (one-shot).
    func clickPad(_ pad: Int) {
        let s = makeSample(frames: 960) { i in i < 960 ? 0.8 * Float(sin(Double(i) * 0.3)) : 0 }
        setPad(pad) { $0.layers.0.sample = s; $0.layers.0.end = 960 }
    }

    func setSequence(_ events: [PSNoteEvent], length: Int, loop: Bool = true) {
        var ev = events
        let seq = ps_sequence_create(&ev, Int32(ev.count), Int32(length), loop ? 1 : 0)
        ps_engine_set_sequence(engine, seq)
    }

    func sine() {
        ps_engine_set_param(engine, PS_PARAM_WAVEFORM, Float(PS_WAVE_SINE.rawValue))
        ps_engine_set_param(engine, PS_PARAM_STEREO, 0)
        ps_engine_set_param(engine, PS_PARAM_ATTACK_MS, 2)
        ps_engine_set_param(engine, PS_PARAM_DECAY_MS, 1)
        ps_engine_set_param(engine, PS_PARAM_SUSTAIN, 1)
        ps_engine_set_param(engine, PS_PARAM_RELEASE_MS, 5)
    }

    func slot(_ slot: Int, _ notes: [Int], bass: Int = -1) {
        var n = notes.map(Int32.init)
        ps_synth_set_slot(engine, Int32(slot), &n, Int32(n.count), Int32(bass))
    }

    func rhythm(_ configure: (inout PSRhythm) -> Void) {
        var r = PSRhythm(strumMs: 80, arpPattern: 0, arpLayer: 0, arpRateBeats: 0.5, arpSwing: 0.5,
                         repeatRateBeats: 0.5, repeatSwing: 0.5, repeatStutter: 0, seqRateBeats: 1)
        configure(&r)
        ps_synth_set_rhythm(engine, &r)
    }
}

func event(_ tick: Int, pad: Int = 0, velocity: Int = 100, length: Int = 120, tune: Float = 0) -> PSNoteEvent {
    PSNoteEvent(tick: Int32(tick), length: Int32(length), pad: Int32(pad), velocity: Int32(velocity), tune: tune)
}

// Transport & sequencer --------------------------------------------------------------

@Suite("Transport and sequencer")
struct TransportTests {
    @Test func metronomeClicksOnEveryBeat() {
        let e = OfflineEngine()
        ps_engine_set_param(e.engine, PS_PARAM_METRONOME, 1)
        ps_engine_set_param(e.engine, PS_PARAM_METRONOME_LEVEL, 1)
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 2.2) // 120 BPM: a beat every 0.5 s
        let hits = onsets(l)
        #expect(near(hits, [0, 0.5, 1.0, 1.5, 2.0]), "\(hits)")
        // Downbeat accent is louder.
        #expect(rms(window(l, 0, 0.02)) > rms(window(l, 0.5, 0.52)))
    }

    @Test func countInClicksThenPlaysTheSequence() {
        let e = OfflineEngine()
        e.clickPad(0)
        e.setSequence([event(0)], length: 3840)
        ps_engine_set_param(e.engine, PS_PARAM_METRONOME_LEVEL, 1)
        ps_transport_play(e.engine, 0, 4) // 4 beats count-in = 2 s, metronome off afterwards
        let (l, _) = e.render(seconds: 2.4)
        let hits = onsets(l)
        #expect(hits.count == 5, "\(hits)") // 4 clicks + the pad at 2.0 s (click + pad overlap)
        #expect(abs((hits.last ?? 0) - 2.0) < 0.002)
        #expect(ps_transport_ticks(e.engine) > 0)
    }

    @Test func sequenceEventsLandOnTime() {
        let e = OfflineEngine()
        e.clickPad(3)
        // 8th notes at 120 BPM: 0.25 s apart; a 1-bar loop is 2 s.
        e.setSequence([event(0, pad: 3), event(480, pad: 3), event(960, pad: 3), event(2880, pad: 3)], length: 3840)
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 2.6)
        #expect(near(onsets(l), [0, 0.25, 0.5, 1.5, 2.0, 2.25, 2.5]), "\(onsets(l))")
    }

    @Test func nonLoopingSequenceStopsTheTransport() {
        let e = OfflineEngine()
        e.clickPad(0)
        e.setSequence([event(0)], length: 960, loop: false)
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 1.5)
        #expect(onsets(l).count == 1)
        #expect(ps_transport_playing(e.engine) == 0)
    }

    @Test func tempoChangesSpacing() {
        let e = OfflineEngine()
        e.clickPad(0)
        ps_engine_set_param(e.engine, PS_PARAM_TEMPO_BPM, 60)
        e.setSequence([event(0)], length: 960) // one beat = 1 s at 60 BPM
        ps_transport_play(e.engine, 0, 0)
        let (l, _) = e.render(seconds: 2.1)
        #expect(near(onsets(l), [0, 1, 2]), "\(onsets(l))")
    }

    @Test func swappingTheSequenceKeepsPlayingAndFreesTheOldOne() {
        let e = OfflineEngine()
        e.clickPad(0)
        e.setSequence([event(0)], length: 960)
        ps_transport_play(e.engine, 0, 0)
        _ = e.render(seconds: 0.2)
        e.setSequence([event(0), event(480)], length: 960)
        let (l, _) = e.render(seconds: 0.85) // 0.2 → 1.05 s: the new events at 0 and 480 ticks
        #expect(near(onsets(l).map { $0 + 0.2 }, [0.25, 0.5, 0.75, 1.0]), "\(onsets(l))")
        #expect(ps_engine_collect_garbage(e.engine) == 1)
        #expect(ps_transport_playing(e.engine) == 1)
    }

    @Test func recordingStampsLiveHitsInTicks() {
        let e = OfflineEngine()
        e.clickPad(5)
        e.setSequence([], length: 3840)
        ps_transport_play(e.engine, 0, 0)
        ps_transport_set_recording(e.engine, 1, 60)
        _ = e.render(seconds: 0.25) // 480 ticks at 120 BPM
        ps_sampler_trigger_ex(e.engine, 5, 90, 2)
        _ = e.render(seconds: 0.1)
        ps_sampler_release(e.engine, 5)
        _ = e.render(seconds: 0.01)
        var out = [PSRecordedEvent](repeating: PSRecordedEvent(), count: 8)
        let n = Int(ps_engine_poll_recorded(e.engine, &out, 8))
        #expect(n == 2)
        #expect(abs(Int(out[0].tick) - 480) <= 3)
        #expect(out[0].pad == 5 && out[0].velocity == 90 && out[0].tune == 2)
        #expect(out[1].velocity == 0 && abs(Int(out[1].tick) - 672) <= 3)
    }

    @Test func recordedTicksWrapWithTheLoopAndGuardSkipsDoubles() {
        let e = OfflineEngine()
        e.clickPad(0)
        // A one-beat loop with an event at 0. A live hit at 0.5 s (tick 960 → wraps to 0)
        // plus the guard means the sequence event right there is skipped.
        e.setSequence([event(0)], length: 960)
        ps_transport_play(e.engine, 0, 0)
        ps_transport_set_recording(e.engine, 1, 120)
        _ = e.render(seconds: 0.499)
        ps_sampler_trigger(e.engine, 0, 100)
        let (l, _) = e.render(seconds: 0.2)
        #expect(onsets(l).count == 1) // the live hit only
        var out = [PSRecordedEvent](repeating: PSRecordedEvent(), count: 4)
        #expect(ps_engine_poll_recorded(e.engine, &out, 4) == 1)
        #expect(out[0].tick >= 955 || out[0].tick <= 5)
    }

    @Test func noteRepeatRetriggersOnTheGrid() {
        let e = OfflineEngine()
        e.clickPad(2)
        ps_note_repeat_set(e.engine, 0.25, 0.5) // 1/16 at 120 = 0.125 s
        ps_note_repeat_pad(e.engine, 2, 100, 0)  // at beat 0: counts as the first step
        let (l, _) = e.render(seconds: 0.55)
        #expect(near(onsets(l), [0, 0.125, 0.25, 0.375, 0.5]), "\(onsets(l))")
        ps_note_repeat_pad(e.engine, 2, 0, 0)
        let (after, _) = e.render(seconds: 0.4)
        #expect(onsets(after).isEmpty)
    }

    @Test func noteRepeatSwingDelaysOddSteps() {
        let e = OfflineEngine()
        e.clickPad(2)
        ps_note_repeat_set(e.engine, 0.5, 0.66) // 1/8 swung
        ps_note_repeat_pad(e.engine, 2, 100, 0)
        let (l, _) = e.render(seconds: 0.9)
        // Steps at 0, 0.25 + 0.16·0.25·2 = 0.33, 0.5, 0.83
        #expect(near(onsets(l), [0, 0.33, 0.5, 0.83], tolerance: 0.003), "\(onsets(l))")
    }
}

// Synth performers ------------------------------------------------------------------

@Suite("Synth performers")
struct PerformerTests {
    @Test func playHoldsSharedNotesAcrossSlots() {
        let e = OfflineEngine()
        e.slot(1, [60, 64, 67])
        e.slot(2, [60, 65, 69])
        _ = e.render(seconds: 0.05)
        #expect(ps_engine_active_voices(e.engine) == 5)
        e.slot(1, [])
        _ = e.render(seconds: 0.05)
        // 60 stays for slot 2.
        e.slot(2, [])
        _ = e.render(seconds: 3)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }

    @Test func strumRollsNotesUpward() {
        let e = OfflineEngine()
        e.sine()
        ps_synth_set_performer(e.engine, Int32(PS_PERF_STRUM.rawValue))
        e.rhythm { $0.strumMs = 80 }
        e.slot(1, [67, 60, 64])
        var counts: [Int32] = []
        for _ in 0..<3 {
            _ = e.render(seconds: 0.06)
            counts.append(ps_engine_active_voices(e.engine))
            _ = e.render(seconds: 0.02)
        }
        #expect(counts == [1, 2, 3])
        // The first note is the lowest.
        let e2 = OfflineEngine()
        e2.sine()
        ps_synth_set_performer(e2.engine, Int32(PS_PERF_STRUM.rawValue))
        e2.slot(1, [67, 60, 64])
        let (l, _) = e2.render(seconds: 0.07)
        #expect(abs(estimatedHz(window(l, 0.01, 0.07), sampleRate: 48_000) - 261.6) < 8)
    }

    @Test func arpPlaysUpThenWrapsOnTheBeatGrid() {
        let e = OfflineEngine()
        e.sine()
        ps_engine_set_param(e.engine, PS_PARAM_RELEASE_MS, 200) // gate ≈ 0.2 s of a 0.25 s step
        ps_synth_set_performer(e.engine, Int32(PS_PERF_ARP.rawValue))
        e.rhythm { $0.arpRateBeats = 0.5 }
        e.slot(1, [60, 64, 67])
        let (l, _) = e.render(seconds: 1.0)
        let hz = (0..<4).map { estimatedHz(window(l, Double($0) * 0.25 + 0.03, Double($0) * 0.25 + 0.17), sampleRate: 48_000) }
        let expected = [261.6, 329.6, 392.0, 261.6]
        #expect(zip(hz, expected).allSatisfy { abs($0 - $1) < 10 }, "\(hz)")
    }

    @Test func arpDownPattern() {
        let e = OfflineEngine()
        e.sine()
        ps_engine_set_param(e.engine, PS_PARAM_RELEASE_MS, 200)
        ps_synth_set_performer(e.engine, Int32(PS_PERF_ARP.rawValue))
        e.rhythm { $0.arpRateBeats = 0.5; $0.arpPattern = 1 }
        e.slot(1, [60, 64, 67])
        let (l, _) = e.render(seconds: 0.5)
        let first = estimatedHz(window(l, 0.03, 0.17), sampleRate: 48_000)
        #expect(abs(first - 392) < 10)
    }

    @Test func repeatRetriggersTheChord() {
        let e = OfflineEngine()
        e.sine()
        ps_synth_set_performer(e.engine, Int32(PS_PERF_REPEAT.rawValue))
        e.rhythm { $0.repeatRateBeats = 0.5 } // 0.25 s steps, 50 % gate
        e.slot(1, [60, 64, 67], bass: 36)
        let (l, _) = e.render(seconds: 0.95)
        #expect(near(onsets(l, threshold: 0.01, gap: 0.05), [0, 0.25, 0.5, 0.75], tolerance: 0.004), "\(onsets(l))")
        e.slot(1, [])
        let (after, _) = e.render(seconds: 0.6)
        #expect(rms(window(after, 0.3, 0.6)) < 1e-4)
    }

    @Test func chordSequencerStepsThroughChords() {
        let e = OfflineEngine()
        e.sine()
        ps_synth_set_performer(e.engine, Int32(PS_PERF_SEQ.rawValue))
        e.rhythm { $0.seqRateBeats = 1 } // 0.5 s per step
        var a: [Int32] = [57], b: [Int32] = [69]
        ps_synth_set_seq_step(e.engine, 0, &a, 1, -1)
        ps_synth_set_seq_step(e.engine, 1, &b, 1, -1)
        ps_synth_set_seq(e.engine, 2, 1)
        let (l, _) = e.render(seconds: 0.2)
        #expect(ps_synth_seq_position(e.engine) == 0)
        #expect(abs(estimatedHz(window(l, 0.05, 0.2), sampleRate: 48_000) - 220) < 6)
        let (l2, _) = e.render(seconds: 0.5)
        #expect(ps_synth_seq_position(e.engine) == 1)
        #expect(abs(estimatedHz(window(l2, 0.35, 0.5), sampleRate: 48_000) - 440) < 8)
        ps_synth_set_seq(e.engine, 2, 0)
        _ = e.render(seconds: 0.1)
        #expect(ps_synth_seq_position(e.engine) == -1)
    }

    @Test func modeChangeSilencesEverything() {
        let e = OfflineEngine()
        ps_synth_set_performer(e.engine, Int32(PS_PERF_ARP.rawValue))
        e.slot(1, [60, 64])
        _ = e.render(seconds: 0.3)
        ps_synth_set_performer(e.engine, Int32(PS_PERF_PLAY.rawValue))
        _ = e.render(seconds: 3)
        #expect(ps_engine_active_voices(e.engine) == 0)
    }
}

// Drum machine -------------------------------------------------------------------------

@Suite("Drum machine")
struct DrumTests {
    @Test(arguments: 0..<Int(PS_DRUM_KITS))
    func everyVoiceInEveryKitIsAudibleAndBounded(kit: Int) {
        for voice in 0..<Int(PS_DRUM_VOICES) {
            let e = OfflineEngine()
            ps_drum_set_kit(e.engine, Int32(kit))
            ps_drum_trigger(e.engine, Int32(voice), 127)
            let (l, _) = e.render(seconds: 1.5)
            let peak = l.map(abs).max() ?? 0
            #expect(peak > 0.02, "kit \(kit) voice \(voice) peak \(peak)")
            #expect(l.allSatisfy { $0.isFinite && abs($0) <= 1 })
            #expect(rms(window(l, 1.4, 1.5)) < 1e-3, "kit \(kit) voice \(voice) rings too long")
        }
    }

    @Test func closedHatChokesOpenHat() {
        let e = OfflineEngine()
        ps_drum_trigger(e.engine, 4, 127)
        _ = e.render(seconds: 0.05)
        ps_drum_trigger(e.engine, 2, 127)
        let (l, _) = e.render(seconds: 0.3)
        #expect(rms(window(l, 0.15, 0.3)) < 1e-3)
    }

    @Test func beatPatternPlaysItsSteps() {
        let e = OfflineEngine()
        var p = PSBeatPattern()
        p.steps = 16
        p.stepBeats = 0.25
        p.swing = 0.5
        withUnsafeMutableBytes(of: &p.velocity) { raw in
            raw[0 * Int(PS_DRUM_VOICES) + 0] = 120 // kick on step 0
            raw[8 * Int(PS_DRUM_VOICES) + 0] = 120 // and step 8 (1.0 s)
        }
        ps_beat_set(e.engine, &p, 1)
        let (l, _) = e.render(seconds: 2.2)
        #expect(near(onsets(l, threshold: 0.02, gap: 0.2), [0, 1.0, 2.0], tolerance: 0.003), "\(onsets(l))")
        ps_beat_set(e.engine, nil, 0)
        _ = e.render(seconds: 0.01)
        #expect(ps_beat_position(e.engine) == -1)
    }

    @Test func drumRepeatRolls() {
        let e = OfflineEngine()
        ps_drum_repeat(e.engine, 1, 0.5, 0.5, 110) // snare every 0.25 s
        let (l, _) = e.render(seconds: 0.9)
        #expect(near(onsets(l, threshold: 0.02, gap: 0.1), [0, 0.25, 0.5, 0.75], tolerance: 0.003), "\(onsets(l))")
        ps_drum_repeat(e.engine, 1, 0, 0.5, 110)
        let (after, _) = e.render(seconds: 1.2)
        #expect(onsets(after, threshold: 0.02, gap: 0.1).isEmpty)
    }
}
