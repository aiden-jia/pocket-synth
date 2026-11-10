import Foundation
import Testing
@testable import SamplerCore

@Suite("Sequence model and Timing Correct")
struct SequenceModelTests {
    @Test func eventsStaySortedAndWrap() {
        var s = PadSequence(name: "S", bars: 1) // 3840 ticks
        s.add(tick: 960, length: 10, pad: 1, velocity: 100)
        s.add(tick: 0, length: 10, pad: 2, velocity: 100)
        s.add(tick: 3840 + 480, length: 10, pad: 3, velocity: 200)
        #expect(s.tracks[0].events.map(\.tick) == [0, 480, 960])
        #expect(s.tracks[0].events[1].velocity == 127)
    }

    @Test func eraseHandlesWrapAndPadsAndKeep() {
        var s = PadSequence(name: "S", bars: 1)
        let keep = s.add(tick: 100, length: 1, pad: 0, velocity: 1)
        for t in [0, 200, 3000, 3800] { s.add(tick: t, length: 1, pad: 1, velocity: 1) }
        s.add(tick: 3700, length: 1, pad: 2, velocity: 1)
        s.erase(track: 0, from: 3500, to: 300, pads: [1], keep: [keep]) // wraps past the end
        #expect(s.tracks[0].events.map(\.tick) == [100, 3000, 3700])
    }

    @Test func barsAndDouble() {
        var s = PadSequence(name: "S", bars: 2)
        s.add(tick: 100, length: 1, pad: 0, velocity: 1)
        s.add(tick: 5000, length: 1, pad: 0, velocity: 1)
        s.setBars(1)
        #expect(s.tracks[0].events.map(\.tick) == [100])
        s.double()
        #expect(s.bars == 2 && s.tracks[0].events.map(\.tick) == [100, 3940])
    }

    @Test func timingCorrectSnapsWithStrengthAndSwing() {
        var tc = TimingCorrect()
        #expect(tc.apply(250) == 240)
        #expect(tc.apply(-30) == 0)
        tc.strength = 50
        #expect(tc.apply(300) == 270)   // halfway to 240
        tc.strength = 100
        tc.swing = 66
        #expect(tc.gridTick(1) == 317)  // 240 · 66/50
        #expect(tc.apply(300) == 317)
        #expect(tc.apply(470) == 480)
        tc.value = .eighthTriplet
        tc.swing = 50
        #expect(tc.apply(330) == 320)
    }
}

@Suite("Take recording")
struct TakeRecorderTests {
    @Test func notesGetCorrectedAndLengthsFromReleases() {
        var s = PadSequence(name: "S", bars: 1)
        var take = TakeRecorder()
        take.ingest([.init(tick: 250, pad: 4, velocity: 90), .init(tick: 700, pad: 4, velocity: 0)],
                    into: &s, track: 0, timing: TimingCorrect())
        let e = s.tracks[0].events
        #expect(e.count == 1 && e[0].tick == 240 && e[0].length == 450 && e[0].velocity == 90)
        #expect(take.recordedIDs == [e[0].id])
    }

    @Test func countInHitsOnlyCountNearTheDownbeat() {
        var s = PadSequence(name: "S", bars: 1)
        var take = TakeRecorder()
        take.ingest([.init(tick: -50, pad: 0, velocity: 90), .init(tick: -600, pad: 1, velocity: 90)],
                    into: &s, track: 0, timing: TimingCorrect())
        #expect(s.tracks[0].events.map(\.pad) == [0])
        #expect(s.tracks[0].events[0].tick == 0)
    }

    @Test func retriggerClosesThePreviousNoteAndFinishCloses() {
        var s = PadSequence(name: "S", bars: 1)
        var take = TakeRecorder()
        take.ingest([.init(tick: 0, pad: 2, velocity: 90), .init(tick: 240, pad: 2, velocity: 80)],
                    into: &s, track: 0, timing: nil)
        take.finish(at: 1000, in: &s, track: 0)
        #expect(s.tracks[0].events.map(\.length) == [240, 760])
    }

    @Test func wrappedReleaseGivesAPositiveLength() {
        var s = PadSequence(name: "S", bars: 1)
        var take = TakeRecorder()
        take.ingest([.init(tick: 3700, pad: 2, velocity: 90), .init(tick: 100, pad: 2, velocity: 0)],
                    into: &s, track: 0, timing: nil)
        #expect(s.tracks[0].events[0].length == 240)
    }
}

@Suite("Undo history")
struct UndoHistoryTests {
    @Test func undoRedoAndCoalescing() {
        var h = UndoHistory<Int>()
        h.record(0, label: "a", at: 0)
        h.record(1, label: "drag", key: "k", at: 1)
        h.record(2, label: "drag", key: "k", at: 1.5)  // merged
        h.record(3, label: "drag", key: "k", at: 3.0)  // too late: new step
        #expect(h.undoStack.map(\.state) == [0, 1, 3])
        #expect(h.undo(current: 4) == 3)
        #expect(h.undo(current: 3) == 1)
        #expect(h.redo(current: 1) == 3)
        h.record(5, label: "new", at: 10)
        #expect(!h.canRedo)
    }

    @Test func historyIsCapped() {
        var h = UndoHistory<Int>()
        for i in 0..<250 { h.record(i, label: "x", at: Double(i)) }
        #expect(h.undoStack.count == 200)
        #expect(h.undoStack.first?.state == 50)
    }
}

@MainActor
@Suite("Sampler sequencer controller")
struct SequencerControllerTests {
    final class Sink {
        var commands: [SamplerCommand] = []
    }

    func make() -> (SamplerController, Sink) {
        let sink = Sink()
        let c = SamplerController(send: { sink.commands.append($0) })
        var t = 0.0
        c.now = { t += 10; return t } // never coalesce unless a test sets its own clock
        return (c, sink)
    }

    @Test func recordFromStopCountsInThenCommitsOneUndoStep() {
        let (c, sink) = make()
        c.record()
        #expect(c.transport.playing && c.transport.recording == .overdub)
        #expect(sink.commands.contains(.transport(playing: true, startTick: 0, countInBeats: 4)))
        #expect(sink.commands.contains(.recording(true, guardTicks: 120)))
        c.poll(hits: [], position: -1000, enginePlaying: true)
        c.poll(hits: [.init(tick: 250, pad: 0, velocity: 100)], position: 300, enginePlaying: true)
        #expect(c.sequence.tracks[0].events.map(\.tick) == [240])
        #expect(sink.commands.last == .sequence(c.sequence)) // plays back on the next pass
        c.poll(hits: [.init(tick: 500, pad: 0, velocity: 0)], position: 600, enginePlaying: true)
        c.stop()
        #expect(c.transport.recording == nil && !c.transport.playing)
        #expect(c.history.undoLabel == "Record")
        c.undo()
        #expect(c.sequence.tracks[0].events.isEmpty)
        c.redo()
        #expect(c.sequence.tracks[0].events.count == 1)
    }

    @Test func replaceErasesWhatThePlayheadPasses() {
        let (c, _) = make()
        c.toggleStep(pad: 1, tick: 0, span: 240)
        c.toggleStep(pad: 2, tick: 960, span: 240)
        c.toggleStep(pad: 3, tick: 3000, span: 240)
        c.play()
        c.poll(hits: [], position: 500, enginePlaying: true) // playing, not recording yet
        c.recordMode = .replace
        c.record() // punch in while playing
        c.poll(hits: [], position: 600, enginePlaying: true)
        c.poll(hits: [.init(tick: 1000, pad: 9, velocity: 100)], position: 1100, enginePlaying: true)
        let pads = c.sequence.tracks[0].events.map(\.pad)
        #expect(pads.contains(9))       // the new take stays
        #expect(!pads.contains(2))      // erased as the playhead passed
        #expect(pads.contains(1) && pads.contains(3)) // outside the swept range
    }

    @Test func liveEraseRemovesOnlyHeldPads() {
        let (c, sink) = make()
        c.toggleStep(pad: 0, tick: 480, span: 240)
        c.toggleStep(pad: 1, tick: 480, span: 240)
        c.play()
        c.eraseHeld = true
        c.padDown(gridIndex: 0)
        #expect(!sink.commands.contains { if case .trigger = $0 { true } else { false } })
        c.poll(hits: [], position: 100, enginePlaying: true)
        c.poll(hits: [], position: 700, enginePlaying: true)
        #expect(c.sequence.tracks[0].events.map(\.pad) == [1])
        c.padUp(gridIndex: 0)
        c.eraseHeld = false
        #expect(c.history.undoLabel == "Erase")
    }

    @Test func gridEditsAreUndoable() {
        let (c, sink) = make()
        c.setBars(1)
        c.toggleStep(pad: 5, tick: 480, span: 240)
        #expect(c.sequence.tracks[0].events.count == 1)
        c.toggleStep(pad: 5, tick: 480, span: 240) // tap again removes
        #expect(c.sequence.tracks[0].events.isEmpty)
        c.undo()
        #expect(c.sequence.tracks[0].events.count == 1)
        let id = c.sequence.tracks[0].events[0].id
        c.moveEvent(id, toTick: 960, pad: 6)
        c.setVelocity(id, 40)
        #expect(c.sequence.tracks[0].events[0].tick == 960 && c.sequence.tracks[0].events[0].pad == 6)
        #expect(c.sequence.tracks[0].events[0].velocity == 40)
        c.undo(); c.undo()
        #expect(c.sequence.tracks[0].events[0].tick == 480)
        #expect(sink.commands.last == .sequence(c.sequence))
    }

    @Test func velocityDragsCoalesce() {
        let (c, _) = make()
        var t = 0.0
        c.now = { t }
        c.toggleStep(pad: 0, tick: 0, span: 240)
        let id = c.sequence.tracks[0].events[0].id
        t = 5
        for v in stride(from: 100, to: 40, by: -10) { t += 0.05; c.setVelocity(id, v) }
        #expect(c.history.undoStack.count == 2)
        c.undo()
        #expect(c.sequence.tracks[0].events[0].velocity == 100)
    }

    @Test func quantizeAndSwingFollowTimingCorrect() {
        let (c, sink) = make()
        c.toggleStep(pad: 0, tick: 250, span: 1)
        c.quantizeTrack()
        #expect(c.sequence.tracks[0].events[0].tick == 240)
        c.setNoteRepeat(true)
        c.setTimingCorrect { $0.swing = 60 }
        #expect(sink.commands.last == .noteRepeat(beats: 0.25, swing: 0.6))
    }

    @Test func noteRepeatSendsRepeatPadsAndPressure() {
        let (c, sink) = make()
        c.setNoteRepeat(true)
        c.setRepeatRate(.eighthTriplet)
        #expect(sink.commands.last == .noteRepeat(beats: 1.0 / 3, swing: 0.5))
        c.padDown(gridIndex: 2, y: 0)
        #expect(sink.commands.last == .repeatPad(pad: 2, velocity: 127, tune: 0))
        c.padPressure(gridIndex: 2, y: 1, size: 0.5)
        #expect(sink.commands.last == .repeatPad(pad: 2, velocity: 20, tune: 0))
        c.padUp(gridIndex: 2)
        #expect(sink.commands.last == .repeatPad(pad: 2, velocity: 0, tune: 0))
        c.setNoteRepeat(false)
        #expect(sink.commands.last == .noteRepeat(beats: 0, swing: 0.5))
    }

    @Test func sixteenLevelsSpreadsTheSourcePad() {
        let (c, sink) = make()
        c.selectedPad = 3
        c.setSixteenLevels(.velocity)
        c.padDown(gridIndex: 0)
        #expect(sink.commands.last == .trigger(pad: 3, velocity: 7, tune: 0))
        c.padDown(gridIndex: 15)
        #expect(sink.commands.last == .trigger(pad: 3, velocity: 127, tune: 0))
        #expect(c.selectedPad == 3)
        c.setSixteenLevels(.tune)
        c.padDown(gridIndex: 8, y: 0)
        #expect(sink.commands.last == .trigger(pad: 3, velocity: 127, tune: 0))
        c.padDown(gridIndex: 0, y: 0)
        #expect(sink.commands.last == .trigger(pad: 3, velocity: 127, tune: -8))
        c.padUp(gridIndex: 0)
        #expect(sink.commands.last == .release(pad: 3))
    }

    @Test func padEditsAreUndoableAndSlidersCoalesce() {
        let (c, _) = make()
        var t = 0.0
        c.now = { t }
        for l in [0.9, 0.8, 0.7] { t += 0.1; c.updateSelected { $0.level = l } }
        #expect(c.history.undoStack.count == 1)
        c.undo()
        #expect(c.selected.level == 1)
    }

    @Test func undoKeepsTheSamplePool() {
        let (c, _) = make()
        let info = SampleInfo(id: SampleID(), name: "k", fileName: "k.wav", frames: 100, sampleRate: 48_000, channels: 1)
        c.addSamples([info])
        #expect(c.selected.primarySample == info.id)
        c.undo()
        #expect(c.selected.primarySample == nil)
        #expect(c.project.samples.count == 1)
    }

    @Test func sequencesAreCreatedOnSelect() {
        let (c, sink) = make()
        c.setBars(4)
        c.selectSequence(2)
        #expect(c.project.sequences.count == 3)
        #expect(c.sequence.name == "Sequence 03" && c.sequence.bars == 4)
        #expect(sink.commands.last == .sequence(c.sequence))
    }

    @Test func nonLoopingSequenceStopsTheTransportAtItsEnd() {
        let (c, _) = make()
        c.setLoop(false)
        c.play()
        c.poll(hits: [], position: 0, enginePlaying: false) // engine hasn't started yet
        #expect(c.transport.playing)
        c.poll(hits: [], position: 2000, enginePlaying: true)
        c.poll(hits: [], position: 0, enginePlaying: false)
        #expect(!c.transport.playing)
    }

    @Test func oldProjectFilesLoad() throws {
        let v1 = #"{"schemaVersion":1,"samples":[],"program":\#(String(data: try JSONEncoder().encode(DrumProgram()), encoding: .utf8)!),"mixer":{"synthLevel":1,"samplerLevel":0.5,"masterLevel":1}}"#
        let p = try JSONDecoder().decode(SamplerProject.self, from: Data(v1.utf8))
        #expect(p.sequences.count == 1 && p.mixer.samplerLevel == 0.5)
        let round = try JSONDecoder().decode(SamplerProject.self, from: JSONEncoder().encode(p))
        #expect(round == p)
    }
}
