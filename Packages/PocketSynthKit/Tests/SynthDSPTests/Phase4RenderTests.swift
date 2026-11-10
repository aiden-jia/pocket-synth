import Foundation
import Testing
import SynthDSP

extension OfflineEngine {
    func loopState(_ t: Int) -> (state: Int32, gen: Int32) {
        let v = ps_looper_track(engine, Int32(t))
        return (v & 7, v >> 3)
    }

    func buffer(seconds: Double) -> OpaquePointer {
        ps_sample_create(Int32(seconds * sampleRate), 2, sampleRate)!
    }
}

@Suite("Looper")
struct LooperTests {
    @Test func barTakeCountsInRecordsThenLoops() {
        let e = OfflineEngine()
        e.sine()
        ps_engine_set_param(e.engine, PS_PARAM_METRONOME, 0)
        let len = Int(e.sampleRate) // 2 beats at 120 BPM = 1 s
        ps_looper_record_first(e.engine, 0, e.buffer(seconds: 1), Int32(len), 2, 7)
        _ = e.render(seconds: 0.5)
        #expect(e.loopState(0) == (Int32(PS_LOOP_WAITING.rawValue), 7)) // count-in (1 s)
        _ = e.render(seconds: 0.6)
        #expect(e.loopState(0).state == Int32(PS_LOOP_RECORD.rawValue))
        // Play a note during the take: 0.2 → 0.5 s into the loop.
        ps_engine_note_on(e.engine, 69, 1)
        _ = e.render(seconds: 0.3)
        ps_engine_note_off(e.engine, 69)
        _ = e.render(seconds: 0.65) // take ends at 2.0 s
        #expect(e.loopState(0).state == Int32(PS_LOOP_PLAY.rawValue))
        #expect(ps_looper_length(e.engine) == Int32(len))
        // The loop plays the note back without anyone playing it.
        _ = e.render(seconds: 2.0)
        let (l, _) = e.render(seconds: 1.0)
        let hz = estimatedHz(window(l, 0.1, 0.3), sampleRate: e.sampleRate) // loop 0.15–0.35 s
        #expect(abs(hz - 440) < 8, "\(hz) Hz")
        #expect(rms(window(l, 0.75, 0.95)) < 0.01)
    }

    @Test func freeTakeEndsOnStopAndLaterTakesStartAtTheLoopPoint() {
        let e = OfflineEngine()
        e.sine()
        ps_looper_record_first(e.engine, 0, e.buffer(seconds: 120), 0, 0, 1)
        _ = e.render(seconds: 0.8)
        ps_looper_stop_first(e.engine, 2)
        _ = e.render(seconds: 0.01)
        let len = Int(ps_looper_length(e.engine))
        #expect(abs(len - Int(0.8 * e.sampleRate)) < 300)
        #expect(e.loopState(0) == (Int32(PS_LOOP_PLAY.rawValue), 2))

        ps_looper_arm(e.engine, 1, e.buffer(seconds: 1), 5)
        _ = e.render(seconds: 0.05)
        #expect(e.loopState(1).state == Int32(PS_LOOP_WAITING.rawValue))
        let wait = (1 - ps_looper_position(e.engine)) * 0.8
        _ = e.render(seconds: wait + 0.05)
        #expect(e.loopState(1).state == Int32(PS_LOOP_RECORD.rawValue))
        ps_engine_note_on(e.engine, 81, 1)
        _ = e.render(seconds: 0.9) // a full pass
        ps_engine_note_off(e.engine, 81)
        #expect(e.loopState(1).state == Int32(PS_LOOP_PLAY.rawValue))
    }

    @Test func clearingReleasesBuffersAndResets() {
        let e = OfflineEngine()
        ps_looper_record_first(e.engine, 2, e.buffer(seconds: 1), Int32(e.sampleRate / 2), 0, 1)
        _ = e.render(seconds: 0.6)
        #expect(ps_looper_length(e.engine) > 0)
        ps_looper_clear(e.engine, 2, 9)
        _ = e.render(seconds: 0.01)
        #expect(e.loopState(2) == (Int32(PS_LOOP_OFF.rawValue), 9))
        #expect(ps_looper_length(e.engine) == 0)
        #expect(ps_engine_collect_garbage(e.engine) == 1)
    }

    @Test func pauseSlowsToAStopAndResumes() {
        let e = OfflineEngine()
        e.sine()
        ps_engine_note_on(e.engine, 69, 1)
        ps_looper_record_first(e.engine, 0, e.buffer(seconds: 1), Int32(e.sampleRate), 0, 1)
        _ = e.render(seconds: 1.05)
        ps_engine_note_off(e.engine, 69)
        _ = e.render(seconds: 0.2)
        ps_looper_pause(e.engine, 1)
        let (l, _) = e.render(seconds: 1.0)
        let early = estimatedHz(window(l, 0.02, 0.12), sampleRate: e.sampleRate)
        let late = estimatedHz(window(l, 0.40, 0.50), sampleRate: e.sampleRate)
        #expect(late < early * 0.6, "\(early) → \(late) Hz") // pitch falls like a tape stop
        #expect(rms(window(l, 0.8, 1.0)) < 1e-4)
        let p = ps_looper_position(e.engine)
        _ = e.render(seconds: 0.3)
        #expect(ps_looper_position(e.engine) == p)
        ps_looper_pause(e.engine, 0)
        _ = e.render(seconds: 0.3)
        #expect(ps_looper_position(e.engine) != p)
    }

    @Test func gainZeroMutesATrack() {
        let e = OfflineEngine()
        e.sine()
        ps_engine_note_on(e.engine, 69, 1)
        ps_looper_record_first(e.engine, 0, e.buffer(seconds: 1), Int32(e.sampleRate / 2), 0, 1)
        _ = e.render(seconds: 0.55)
        ps_engine_note_off(e.engine, 69)
        ps_looper_set_gain(e.engine, 0, 0)
        _ = e.render(seconds: 0.5)
        let (l, _) = e.render(seconds: 0.5)
        #expect(rms(l[...]) < 1e-3)
    }
}

@Suite("Sampling recorder")
struct RecorderTests {
    @Test func recordsInputAfterTheThresholdWithPreRoll() {
        let e = OfflineEngine()
        let buf = e.buffer(seconds: 2)
        ps_recorder_arm(e.engine, buf, Int32(PS_SOURCE_INPUT.rawValue), 0.1, 480)
        _ = e.render(seconds: 0.01)
        #expect(ps_recorder_state(e.engine) == Int32(PS_REC_ARMED.rawValue))
        // Quiet input, then a loud burst.
        var quiet = [Float](repeating: 0.01, count: 4800)
        ps_engine_push_input(e.engine, &quiet, &quiet, 4800)
        _ = e.render(seconds: 0.01)
        #expect(ps_recorder_state(e.engine) == Int32(PS_REC_ARMED.rawValue))
        var loud = (0..<4800).map { Float(0.5 * sin(Double($0) * 0.1)) }
        ps_engine_push_input(e.engine, &loud, &loud, 4800)
        _ = e.render(seconds: 0.01)
        #expect(ps_recorder_state(e.engine) == Int32(PS_REC_RECORDING.rawValue))
        ps_recorder_stop(e.engine)
        _ = e.render(seconds: 0.01)
        #expect(ps_recorder_state(e.engine) == Int32(PS_REC_DONE.rawValue))
        let frames = Int(ps_recorder_frames(e.engine))
        // The first loud sample above 0.1 is i = 3 (0.5·sin 0.3 ≈ 0.15): 480 pre-roll + 4797.
        #expect(frames == 480 + 4797, "\(frames)")
        let ch = ps_sample_channel(buf, 0)!
        #expect(abs(ch[0] - 0.01) < 1e-6)       // pre-roll holds the quiet input
        #expect(ps_recorder_peak(e.engine) > 0.45)
        ps_recorder_release(e.engine)
        _ = e.render(seconds: 0.01)
        #expect(ps_engine_collect_garbage(e.engine) == 1)
    }

    @Test func resamplesTheSynthImmediately() {
        let e = OfflineEngine()
        e.sine()
        let buf = e.buffer(seconds: 1)
        ps_engine_note_on(e.engine, 69, 1)
        ps_recorder_arm(e.engine, buf, Int32(PS_SOURCE_SYNTH.rawValue), 0, 0)
        _ = e.render(seconds: 0.5)
        ps_recorder_stop(e.engine)
        _ = e.render(seconds: 0.01)
        let n = Int(ps_recorder_frames(e.engine))
        #expect(abs(n - 24_000) < 300)
        let data = Array(UnsafeBufferPointer(start: ps_sample_channel(buf, 0), count: n))
        #expect(abs(estimatedHz(data[4800...], sampleRate: e.sampleRate) - 440) < 4)
    }

    @Test func fullBufferEndsTheTake() {
        let e = OfflineEngine()
        ps_recorder_arm(e.engine, e.buffer(seconds: 0.1), Int32(PS_SOURCE_MASTER.rawValue), 0, 0)
        _ = e.render(seconds: 0.3)
        #expect(ps_recorder_state(e.engine) == Int32(PS_REC_DONE.rawValue))
        #expect(ps_recorder_frames(e.engine) == 4800)
    }

    @Test func previewPlaysARegion() {
        let e = OfflineEngine()
        let s = e.makeSample(frames: 48_000) { i in i >= 24_000 && i < 24_960 ? 0.5 : 0 }
        ps_sampler_preview(e.engine, s, 24_000, 24_960, 127)
        let (l, _) = e.render(seconds: 0.1)
        #expect(rms(window(l, 0, 0.018)) > 0.1)  // the region's start plays right away
        #expect(rms(window(l, 0.03, 0.1)) < 1e-4)
        ps_engine_release_sample(e.engine, s)
        _ = e.render(seconds: 0.01)
        #expect(ps_engine_collect_garbage(e.engine) == 1)
    }
}
