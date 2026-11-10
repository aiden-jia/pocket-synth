import Foundation
import ChordTheory
import Testing
@testable import SynthCore

@MainActor
@Suite("Looper and Mixer mode")
struct LooperControllerTests {
    func click(_ r: Rig) { r.on(.clickDown, .clickUp) }

    /// What the engine would report back for the controller's current generations.
    func report(_ r: Rig, _ states: [Int: LoopTrackState], length: Int = 96_000) {
        let reports = r.c.looper.tracks.enumerated().map { i, t in
            LoopTrackReport(state: states[i] ?? t.state, generation: t.generation)
        }
        r.c.updateLooper(reports, length: length, position: 0.5)
    }

    @Test func barTakeCountsInAndAutoAdvances() {
        let r = Rig()
        click(r)
        let gen = r.c.looper.tracks[0].generation
        #expect(r.commands.last == .looperRecordFirst(track: 0, bars: 4, countInBeats: 4, generation: gen))
        #expect(r.c.looper.tracks[0].state == .waiting)
        report(r, [0: .record], length: 0)
        #expect(r.c.looper.tracks[0].state == .record)
        report(r, [0: .play])
        #expect(r.c.looper.hasLoop && r.c.looper.firstTake == nil)
        #expect(r.c.looper.cursor == 1)            // next empty track
        #expect(r.c.looperHasAudio)
    }

    @Test func laterTracksArmAndCancel() {
        let r = Rig()
        click(r); report(r, [0: .play])
        click(r)                                   // cursor 1: arm
        #expect(r.commands.last == .looperArm(track: 1, generation: r.c.looper.tracks[1].generation))
        click(r)                                   // waiting: cancel
        #expect(r.c.looper.tracks[1].state == .off)
        #expect(r.commands.last == .looperClear(track: 1, generation: r.c.looper.tracks[1].generation))
    }

    @Test func staleReportsAreIgnored() {
        let r = Rig()
        click(r); report(r, [0: .play])
        click(r)                                   // arm track 1 (gen n)
        let stale = LoopTrackReport(state: .off, generation: r.c.looper.tracks[1].generation - 1)
        r.c.updateLooper([LoopTrackReport(state: .play, generation: r.c.looper.tracks[0].generation), stale],
                         length: 96_000, position: 0)
        #expect(r.c.looper.tracks[1].state == .waiting)
    }

    @Test func freeTakeStartsOnTheFirstChordAndEndsOnClick() {
        var st = SynthState()
        st.loopBars = 0
        let r = Rig(st)
        click(r)
        #expect(r.c.looper.freeArmed == 0)
        #expect(!r.commands.contains { if case .looperRecordFirst = $0 { true } else { false } })
        r.on(.padDown(1))
        let gen = r.c.looper.tracks[0].generation
        #expect(r.commands.contains(.looperRecordFirst(track: 0, bars: nil, countInBeats: 0, generation: gen)))
        #expect(r.c.looper.tracks[0].state == .record)
        r.on(.padUp(1))
        click(r)
        #expect(r.commands.last == .looperStopFirst(generation: gen + 1))
        report(r, [0: .play])
        #expect(r.c.looper.tracks[0].state == .play)
    }

    @Test func holdingClickClearsAPlayingTrack() {
        let r = Rig()
        click(r); report(r, [0: .play])
        r.on(.stick(.left), .stick(nil))           // back to track 1
        #expect(r.c.looper.cursor == 0)
        r.on(.clickDown)
        r.c.tick(at: r.t + 0.3)
        #expect(r.c.looper.tracks[0].state == .play)
        r.c.tick(at: r.t + 0.8)
        #expect(r.c.looper.tracks[0].state == .off)
        #expect(!r.c.looper.hasLoop)               // that was the last one: looper reset
        r.on(.clickUp)
    }

    @Test func transportPausesAndHoldClearsAll() {
        let r = Rig()
        click(r); report(r, [0: .play])
        r.on(.stick(.down), .stick(nil))
        #expect(r.c.looper.cursor == LooperState.transport)
        click(r)
        #expect(r.commands.last == .looperPause(true) && r.c.looper.paused)
        click(r)
        #expect(r.commands.last == .looperPause(false))
        r.on(.clickDown)
        r.c.tick(at: r.t + 1)
        #expect(r.c.looper.tracks.allSatisfy { $0.state == .off })
    }

    @Test func mixerModeMutesSolosAndSetsLevels() {
        let r = Rig()
        click(r); report(r, [0: .play])
        r.on(.menuDown(.mode), .menuUp(.mode))
        for _ in 0..<(r.c.availableModes.count - 1) { r.on(.stick(.right), .stick(nil)) }
        r.on(.clickDown, .clickUp)                  // MIXER needs a confirm
        #expect(r.c.state.mode == .mixer)
        r.on(.padDown(1), .padUp(1))
        #expect(r.commands.last == .looperGain(track: 5, gain: 1)) // all six resent
        #expect(r.c.looper.tracks[0].muted && r.c.looper.gain(0) == 0)
        r.on(.padDown(1), .padUp(1))
        r.on(.padDown(2), .menuDown(.sound), .menuUp(.sound), .padUp(2)) // solo track 2
        #expect(r.c.looper.gain(0) == 0 && r.c.looper.gain(1) == 1)
        r.on(.padDown(2), .wheel(-0.5), .padUp(2))
        #expect(abs(r.c.looper.tracks[1].level - 0.5) < 1e-9)
        r.on(.padDown(7), .padUp(7))
        #expect(!r.c.state.metronome)
        #expect(r.commands.contains(.metronome(on: false, level: 0.6)))
        // No chord was played in mixer mode.
        #expect(r.c.sounding.isEmpty)
    }

    @Test func randomizeAndPresetSaveWaitWhileRecording() {
        let r = Rig()
        click(r); report(r, [0: .record], length: 0)
        let before = r.c.state
        r.on(.menuDown(.sound), .clickDown, .clickUp, .menuUp(.sound))
        #expect(r.c.state == before)
        #expect(r.c.display.toast == "NOT WHILE RECORDING")
    }

    @Test func modeRandomizeMakesASequence() {
        let r = Rig()
        r.on(.menuDown(.mode), .clickDown, .clickUp, .menuUp(.mode))
        let steps = r.c.state.chordSequence.steps
        #expect(steps.count == 4 && steps.allSatisfy { $0 != nil })
        #expect(steps[0]?.chord.root == 0)  // starts on the tonic
    }

    @Test func sessionDropsLocksAndRoundTrips() throws {
        var st = SynthState()
        st.locks[1] = ChordLock(chord: Chord(root: 2, type: .minor7), rootNote: 62, legacyNinthVoicing: false, spelling: .sharps)
        st.loopBars = 2
        st.bpm = 97
        let c = SynthController(state: st)
        let s = c.session
        #expect(s.state.locks.isEmpty && s.state.loopBars == 2)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SynthSession.self, from: data)
        #expect(back.state.bpm == 97 && back.presets.count == 4)
        // Old/partial files fill in defaults.
        let partial = try JSONDecoder().decode(SynthState.self, from: Data(#"{"bpm": 88, "unknown": 1}"#.utf8))
        #expect(partial.bpm == 88 && partial.mode == .play)
    }
}
