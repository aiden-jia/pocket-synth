import ChordTheory
import Foundation
import Testing
@testable import SynthCore

@MainActor
@Suite("Tool modes: Tuner, Mic, Trainer, Game")
struct ToolModeTests {
    func rig(_ mode: SynthMode) -> Rig {
        var st = SynthState()
        st.mode = mode
        return Rig(st)
    }

    func tick(_ r: Rig, by dt: Double, steps: Int = 10) {
        for _ in 0..<steps {
            r.t += dt / Double(steps)
            r.c.tick(at: r.t)
        }
    }

    // Tuner --------------------------------------------------------------------------

    @Test func tunerReadsNoteAndCents() {
        let a = TunerReading(hz: 440)!
        #expect(a.note == 69 && a.name == "A4" && abs(a.cents) < 0.01 && a.inTune)
        let sharp = TunerReading(hz: 446)!
        #expect(sharp.note == 69 && abs(sharp.cents - 23.4) < 0.2 && !sharp.inTune)
        #expect(TunerReading(hz: 10) == nil)
        #expect(TunerReading(hz: nil) == nil)
    }

    @Test func tunerSmootherNeedsTwoReadingsToChangeNote() {
        var s = TunerSmoother()
        #expect(s.add(TunerReading(hz: 440))?.note == 69)
        #expect(s.add(TunerReading(hz: 523.25))?.note == 69) // one stray reading
        #expect(s.add(TunerReading(hz: 523.25))?.note == 72)
        for _ in 0..<6 { _ = s.add(nil) }
        #expect(s.shown == nil)
    }

    @Test func tunerPadsAreSilentAndScreenShowsTheReading() {
        let r = rig(.tuner)
        r.on(.padDown(1), .padUp(1))
        #expect(r.lastChordCommand == nil)
        #expect(r.c.display.tool == .tuner(nil))
        r.c.setTunerReading(TunerReading(hz: 220))
        #expect(r.c.display.tool == .tuner(TunerReading(hz: 220)))
        #expect(r.c.display.looper == nil)
    }

    // Mic ----------------------------------------------------------------------------

    @Test func holdingPadOneRecordsThenTheTakePlaysInLead() {
        let r = rig(.mic)
        var requests: [Bool] = []
        r.c.onMicRecord = { requests.append($0) }
        r.on(.padDown(2), .padUp(2))
        #expect(requests.isEmpty && r.lastChordCommand == nil)
        r.on(.padDown(1))
        #expect(requests == [true] && r.c.micRecording)
        #expect(r.c.display.chordName == "● REC")
        r.on(.padUp(1))
        #expect(requests == [true, false] && !r.c.micRecording)

        r.c.micSampleReady(root: 57.2)
        #expect(r.c.state.mode == .lead)
        #expect(r.c.state.soundIndex == SoundCatalog.micSampleIndex)
        #expect(r.c.state.micSampleRoot == 57.2)
        #expect(r.commands.contains(.sound(index: SoundCatalog.micSampleIndex, engine: .sample)))
    }

    @Test func micTakeStopsByItselfAfterThreeSeconds() {
        let r = rig(.mic)
        var requests: [Bool] = []
        r.c.onMicRecord = { requests.append($0) }
        r.on(.padDown(1))
        tick(r, by: 2.9)
        #expect(requests == [true])
        tick(r, by: 0.2)
        #expect(requests == [true, false])
        r.on(.padUp(1)) // releasing later doesn't ask again
        #expect(requests == [true, false])
    }

    @Test func leavingMicModeMidTakeStopsIt() {
        let r = rig(.mic)
        var requests: [Bool] = []
        r.c.onMicRecord = { requests.append($0) }
        r.on(.padDown(1))
        r.on(.menuDown(.mode), .padDown(1), .padUp(1), .menuUp(.mode)) // M + 1 = Play
        #expect(r.c.state.mode == .play)
        #expect(requests == [true, false])
    }

    @Test func presetLoadKeepsTheNewestMicTake() {
        var st = SynthState()
        st.micSampleRoot = 60
        let r = Rig(st)
        r.on(.menuDown(.key), .menuDown(.sound), .menuUp(.key), .menuUp(.sound), .stick(.up), .stick(nil), .stick(.up), .stick(nil))
        r.c.micSampleReady(root: 64)
        r.on(.menuDown(.key), .menuDown(.sound), .menuUp(.key), .menuUp(.sound), .stick(.down), .stick(nil), .stick(.up), .stick(nil))
        #expect(r.c.state.micSampleRoot == 64)
        #expect(r.c.state.soundIndex == 0) // the preset's own sound
    }

    // Trainer: questions ---------------------------------------------------------------

    @Test func intervalQuestionsAnswerWithTheMatchingDegree() {
        let st = SynthState()
        var t = EarTrainer(level: .intervalUp, seed: 1)
        for _ in 0..<40 {
            let q = t.next(state: st)
            let tonic = EarTrainer.padNote(1, state: st)
            #expect(q.targetNote! > tonic && q.targetNote! <= tonic + 12)
            #expect(mod12(EarTrainer.padNote(q.answers[0].pad, state: st)) == mod12(q.targetNote!))
            #expect(q.playback.map(\.notes) == [[tonic], [q.targetNote!]])
            #expect(t.answer(q.answers[0], state: st) == .right)
        }
        #expect(t.correct == 40 && t.streak == 40)
    }

    @Test func upDownLevelAsksBelowTheTonicToo() {
        let st = SynthState()
        var t = EarTrainer(level: .intervalUpDown, seed: 2)
        let below = (0..<40).filter { _ in t.next(state: st).targetNote! < EarTrainer.padNote(1, state: st) }
        #expect(!below.isEmpty && below.count < 40)
    }

    @Test func wrongAnswerEndsTheQuestionAndTheStreak() {
        let st = SynthState()
        var t = EarTrainer(level: .triad, seed: 3)
        var q = t.next(state: st)
        #expect(t.answer(q.answers[0], state: st) == .right)
        q = t.next(state: st)
        let wrong = TrainerAnswer(pad: q.answers[0].pad % 7 + 1)
        #expect(t.answer(wrong, state: st) == .wrong)
        #expect(t.streak == 0 && t.correct == 1 && t.asked == 2 && t.question == nil)
        #expect(t.answer(wrong, state: st) == nil)
    }

    @Test func progressionNeedsAllFourInOrder() {
        let st = SynthState()
        var t = EarTrainer(level: .progression, seed: 4)
        let q = t.next(state: st)
        #expect(q.answers.count == 4 && q.answers[0].pad == 1 && q.playback.count == 4)
        #expect(t.answer(q.answers[0], state: st) == .partial)
        #expect(t.answer(q.answers[1], state: st) == .partial)
        #expect(t.answer(q.answers[2], state: st) == .partial)
        #expect(t.answer(q.answers[3], state: st) == .right)
    }

    @Test func modifiedChordAcceptsAnyStickThatMakesTheSameChord() {
        let st = SynthState()
        // Pad 2 (Dm) ↑ flips the third → D; pad 2 ↗ (dom7 on a minor chord) → D7. Different.
        #expect(!EarTrainer.sameSound(TrainerAnswer(pad: 2, stick: .up), TrainerAnswer(pad: 2, stick: .upRight), state: st))
        #expect(EarTrainer.sameSound(TrainerAnswer(pad: 5, stick: nil), TrainerAnswer(pad: 5, stick: nil), state: st))
        var t = EarTrainer(level: .modifiedChord, seed: 5)
        let q = t.next(state: st)
        #expect(q.answers[0].stick != nil)
        #expect(t.answer(q.answers[0], state: st) == .right)
    }

    // Trainer: controller flow ---------------------------------------------------------

    @Test func trainerAsksPlaysAndScoresAnAnswer() {
        let r = rig(.trainer)
        tick(r, by: 0.7)
        let q = try! #require(r.c.trainer.question)
        tick(r, by: 2)
        let played = r.commands.compactMap { cmd -> [Int]? in
            if case .chord(0, let v?) = cmd { return v.notes } else { return nil }
        }
        #expect(played == q.playback.map(\.notes))
        #expect(r.c.display.chordName == "?")

        r.on(.padDown(q.answers[0].pad), .padUp(q.answers[0].pad))
        #expect(r.c.trainer.correct == 1)
        #expect(r.c.display.toast == "✓ RIGHT")
        #expect(r.c.display.chordName == EarTrainer.names(q, state: r.c.state).joined(separator: " → "))
        tick(r, by: 1.6)
        #expect(r.c.trainer.question != nil) // the next one
    }

    @Test func clickReplaysTheQuestion() {
        let r = rig(.trainer)
        tick(r, by: 3)
        let before = r.commands.count
        r.on(.clickDown, .clickUp)
        tick(r, by: 2)
        let replayed = r.commands[before...].filter { if case .chord(0, _?) = $0 { true } else { false } }
        #expect(replayed.count == 2)
    }

    @Test func modeMenuDownCyclesTheLevel() {
        let r = rig(.trainer)
        r.on(.menuDown(.mode), .menuUp(.mode), .stick(.down), .stick(nil))
        #expect(r.c.state.trainerLevel == .intervalUpDown)
        #expect(r.c.trainer.level == .intervalUpDown)
    }

    @Test func modifiedLevelsJudgeOnReleaseWithTheStick() {
        var st = SynthState()
        st.mode = .trainer
        st.trainerLevel = .modifiedChord
        let r = Rig(st)
        tick(r, by: 0.7)
        let a = try! #require(r.c.trainer.question?.answers.first)
        r.on(.padDown(a.pad), .stick(a.stick))
        #expect(r.c.trainer.asked == 0) // not yet
        r.on(.stick(nil), .padUp(a.pad))
        #expect(r.c.trainer.correct == 1)
    }

    // Game -------------------------------------------------------------------------------

    @Test func songsCoverFiveTiersWithPlayableCharts() {
        #expect(GameSongs.all.count == 10)
        #expect(Dictionary(grouping: GameSongs.all, by: \.tier).mapValues(\.count) == [1: 2, 2: 2, 3: 2, 4: 2, 5: 2])
        for s in GameSongs.all {
            #expect(!s.notes.isEmpty)
            #expect(s.notes.allSatisfy { (1...7).contains($0.pad) && $0.beat >= GameSong.countInBeats && $0.beat < s.lengthBeats })
            #expect(s.notes.map(\.beat) == s.notes.map(\.beat).sorted())
        }
    }

    @Test func runJudgesHitsByTiming() {
        let song = GameSongs.all[0] // whole notes at 80 BPM: first at beat 4 = 3 s
        var run = GameRun(song: song, speed: 1, startTime: 10)
        #expect(abs(run.time(of: 0) - 13) < 1e-9)
        #expect(run.hit(pad: song.notes[0].pad, at: 13.03) == .perfect)
        #expect(run.hit(pad: song.notes[1].pad, at: run.time(of: 1) - 0.1) == .good)
        #expect(run.hit(pad: song.notes[2].pad, at: run.time(of: 2) + 0.3) == nil) // too late
        #expect(run.hit(pad: song.notes[2].pad == 1 ? 2 : 1, at: run.time(of: 2)) == nil) // wrong pad
        #expect(run.combo == 2)
        #expect(run.expire(at: run.time(of: 2) + 0.2) == 1)
        #expect(run.combo == 0 && run.maxCombo == 2)
        #expect(run.accuracy == 50) // (2 + 1 + 0) / 6
        // Half speed doubles every time from the start.
        #expect(abs(GameRun(song: song, speed: 0.5, startTime: 10).time(of: 0) - 16) < 1e-9)
    }

    @Test func gameModeRunsASongAndKeepsTheBest() {
        let r = rig(.game)
        r.on(.stick(.right), .stick(nil))
        #expect(r.c.gameSong == 1)
        r.on(.stick(.down), .stick(nil))
        #expect(r.c.gameSpeed == 0.9)
        r.on(.stick(.up), .stick(nil))
        r.on(.clickDown, .clickUp)
        let song = GameSongs.all[1]
        #expect(r.commands.contains(.tempo(song.bpm)))
        #expect(r.commands.contains(.beat(.make(song.style, .original), playing: true)))
        let run = try! #require(r.c.game)
        guard case .game(let g)? = r.c.display.tool else { Issue.record("no game screen"); return }
        #expect(g.running)

        // Hit every note on time.
        for (i, n) in song.notes.enumerated() {
            r.t = run.time(of: i)
            r.c.handle(.padDown(n.pad), at: r.t)
            r.c.handle(.padUp(n.pad), at: r.t + 0.05)
            r.c.tick(at: r.t + 0.06)
        }
        #expect(r.c.game?.count(.perfect) == song.notes.count)
        r.c.tick(at: run.endTime + 0.01)
        #expect(r.c.game == nil)
        #expect(r.c.gameResult?.accuracy == 100)
        #expect(r.c.gameBest[song.name] == 100)
        #expect(r.commands.suffix(2) == [.beat(nil, playing: false), .tempo(r.c.state.bpm)])
        #expect(r.c.session.gameBest?[song.name] == 100)
    }

    @Test func leavingGameModeRestoresTheTempo() {
        let r = rig(.game)
        r.on(.clickDown, .clickUp)
        #expect(r.c.game != nil)
        r.on(.menuDown(.mode), .padDown(1), .padUp(1), .menuUp(.mode))
        #expect(r.c.game == nil)
        #expect(r.commands.last == .tempo(r.c.state.bpm))
    }

    // Settings & persistence ------------------------------------------------------------

    @Test func vocoderOnForcesChorusFlangerAndDelayOff() {
        var s = SynthState()
        s.fx[.chorus] = 2
        s.fx[.delay] = 1
        s.fx[.reverb] = 1
        SettingRow.fx(.vocoder).set(1, in: &s)
        #expect(s.fx[.chorus] == nil && s.fx[.delay] == nil && s.fx[.flanger] == nil)
        #expect(s.fx[.reverb] == 1 && s.fx[.vocoder] == 1)
        #expect(EngineCommand.diff(from: SynthState(), to: s).contains(.fx(.vocoder, 1)))
    }

    @Test func toolSettingsSurviveASaveAndOlderSessionsStillLoad() throws {
        var s = SynthState()
        s.trainerLevel = .progression
        s.micSampleRoot = 55.5
        let data = try JSONEncoder().encode(SynthSession(state: s, presets: [], gameBest: ["Rooftop": 91]))
        let back = try JSONDecoder().decode(SynthSession.self, from: data)
        #expect(back.state.trainerLevel == .progression && back.state.micSampleRoot == 55.5)
        #expect(back.gameBest == ["Rooftop": 91])
        let old = #"{"state":{"bpm":99},"presets":[]}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(SynthSession.self, from: old)
        #expect(legacy.state.bpm == 99 && legacy.gameBest == nil && legacy.state.micSampleRoot == nil)
    }
}
