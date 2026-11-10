import ChordTheory
import Testing
@testable import SynthCore

@MainActor
@Suite("Drums, Beat and Seq modes")
struct ModeTests {
    func rig(_ mode: SynthMode) -> Rig {
        var st = SynthState()
        st.mode = mode
        return Rig(st)
    }

    // Drums ------------------------------------------------------------------------

    @Test func drumPadsHitVoicesNotChords() {
        let r = rig(.drums)
        r.on(.padDown(1), .padUp(1), .padDown(3))
        #expect(r.commands.contains(.drumHit(.kick, velocity: 100)))
        #expect(r.commands.contains(.drumHit(.closedHat, velocity: 100)))
        #expect(r.lastChordCommand == nil)
        #expect(r.c.padLabel(2) == "SNARE")
    }

    @Test func drumStickRepeatsAtTheDirectionRate() {
        let r = rig(.drums)
        r.on(.padDown(2), .stick(.down))
        #expect(r.commands.last == .drumRepeat(.snare, beats: 0.25, swing: 0.5))
        r.on(.stick(.upRight))
        #expect(r.commands.last == .drumRepeat(.snare, beats: 0.5, swing: 0.62))
        r.on(.stick(nil))
        #expect(r.commands.last == .drumRepeat(.snare, beats: 0, swing: 0.5))
        // Releasing the pad also stops a roll.
        r.on(.stick(.left))
        r.on(.padUp(2))
        #expect(r.commands.last == .drumRepeat(.snare, beats: 0, swing: 0.5))
    }

    @Test func soundPlusPadPicksTheKit() {
        let r = rig(.drums)
        r.on(.menuDown(.sound), .padDown(4), .padUp(4), .menuUp(.sound))
        #expect(r.c.state.drumKit == 4)
        #expect(r.commands.contains(.drumKit(4)))
        #expect(r.c.display.detail == "KIT 4 · LO-FI")
    }

    // Beat ---------------------------------------------------------------------------

    @Test func beatPadStartsSwitchesAndStops() {
        let r = rig(.beat)
        r.on(.padDown(1), .padUp(1))
        #expect(r.c.beatPlaying)
        #expect(r.commands.last == .beat(.make(.rock, .original), playing: true))
        r.on(.padDown(5), .padUp(5))
        #expect(r.c.state.beatStyle == .house)
        #expect(r.commands.last == .beat(.make(.house, .original), playing: true))
        r.on(.padDown(5), .padUp(5))
        #expect(!r.c.beatPlaying)
        #expect(r.commands.last == .beat(nil, playing: false))
    }

    @Test func holdPadAndStickChangesVariation() {
        let r = rig(.beat)
        r.on(.padDown(4), .stick(.up), .stick(nil))
        #expect(r.c.state.beatVariation == .ghost)
        #expect(r.commands.last == .beat(.make(.funk, .ghost), playing: true))
        r.on(.stick(.down), .stick(.down), .stick(nil), .stick(.down))
        #expect(r.c.state.beatVariation == .perc) // wrapped below ORIG
        r.on(.padUp(4))
    }

    @Test func leavingBeatModeStopsThePlayer() {
        let r = rig(.beat)
        r.on(.padDown(1), .padUp(1))
        r.on(.menuDown(.mode), .padDown(1), .padUp(1), .menuUp(.mode)) // quick select PLAY
        #expect(r.c.state.mode == .play)
        #expect(!r.c.beatPlaying)
        #expect(r.commands.contains(.allNotesOff))
    }

    // Seq ------------------------------------------------------------------------------

    @Test func padsFillTheCursorStepAndStickMovesIt() {
        let r = rig(.seq)
        r.on(.padDown(1), .padUp(1))
        #expect(r.c.state.chordSequence.steps[0]?.name == "C")
        r.on(.stick(.right), .stick(nil))
        #expect(r.c.seqCursor == 1)
        r.on(.padDown(6), .padUp(6))
        #expect(r.c.state.chordSequence.steps[1]?.name == "Am")
        if case .chordSequence(let steps)? = r.commands.last(where: { if case .chordSequence = $0 { true } else { false } }) {
            #expect(steps[1]?.name == "Am")
        } else {
            Issue.record("no chordSequence command")
        }
    }

    @Test func stickPushedWithAPadStoresTheModifiedChordWithoutMoving() {
        let r = rig(.seq)
        r.on(.stick(.upRight), .padDown(5), .padUp(5), .stick(nil))
        #expect(r.c.state.chordSequence.steps[0]?.name == "G7")
        #expect(r.c.seqCursor == 0)
    }

    @Test func advancingPastTheEndAddsSteps() {
        let r = rig(.seq)
        for _ in 0..<5 { r.on(.stick(.right), .stick(nil)) }
        #expect(r.c.state.chordSequence.length == 6)
        #expect(r.c.seqCursor == 5)
        r.on(.stick(.up), .stick(nil))        // page 2 → page 1
        #expect(r.c.seqCursor == 1)
        r.on(.stick(.up), .stick(nil))        // on page 1: cycles the step rate
        #expect(r.c.state.seqRate == .eighth)
        r.on(.stick(.down), .stick(nil))
        #expect(r.c.seqCursor == 5)
    }

    @Test func clickPlaysStopsAndTrims() {
        let r = rig(.seq)
        r.on(.padDown(1), .padUp(1))
        for _ in 0..<7 { r.on(.stick(.right), .stick(nil)) } // 8 steps, only the first filled
        r.on(.stick(.up), .clickDown, .clickUp, .stick(nil))
        #expect(r.c.state.chordSequence.length == 1)
        #expect(r.c.seqCursor == 0)
        r.on(.clickDown, .clickUp)
        #expect(r.c.seqPlaying)
        #expect(r.commands.last == .chordSequencePlaying(true, length: 1))
        // Editing is off while playing.
        r.on(.padDown(2), .padUp(2))
        #expect(r.c.state.chordSequence.steps[0]?.name == "C")
        r.on(.clickDown, .clickUp)
        #expect(r.commands.last == .chordSequencePlaying(false, length: 1))
    }

    @Test func seqDisplayShowsThePage() {
        let r = rig(.seq)
        r.on(.padDown(4), .padUp(4))
        let cells = r.c.display.steps ?? []
        #expect(cells.map(\.label) == ["F", "—", "—", "—"])
        #expect(cells.first?.isCursor == true)
        #expect(r.c.display.detail == "STEP 1/4 · 1/4 ■")
    }

    @Test func modeParamCyclesTheStepRate() {
        let r = rig(.seq)
        r.on(.menuDown(.mode), .menuUp(.mode), .stick(.down), .stick(nil))
        #expect(r.c.state.seqRate == .eighth)
        #expect(r.commands.contains { if case .rhythm(_, _, _, _, _, .eighth) = $0 { true } else { false } })
    }
}

@Suite("Beat patterns")
struct BeatPatternTests {
    @Test(arguments: BeatStyle.allCases)
    func everyStyleAndVariationIsPlayable(style: BeatStyle) {
        for v in BeatVariation.allCases {
            let p = BeatPattern.make(style, v)
            #expect((1...32).contains(p.steps), "\(style) \(v)")
            #expect(p.hits.allSatisfy { $0.count == DrumVoice.allCases.count })
            #expect(p.hits.joined().contains { $0 > 0 })
            #expect(p.hits.joined().allSatisfy { (0...127).contains($0) })
        }
    }

    @Test func rockHasBackbeatSnares() {
        let p = BeatPattern.make(.rock, .original)
        #expect(p.velocity(4, .snare) > 0 && p.velocity(12, .snare) > 0)
        #expect(p.velocity(0, .kick) == 120)
    }

    @Test func variationsTransformTheBase() {
        let base = BeatPattern.make(.rock, .original)
        #expect(BeatPattern.make(.rock, .half).stepBeats == 0.5)
        #expect(BeatPattern.make(.rock, .double).stepBeats == 0.125)
        #expect(BeatPattern.make(.rock, .fill).steps == 32)
        #expect(BeatPattern.make(.rock, .sixteenths).hits.allSatisfy { $0[DrumVoice.closedHat.rawValue] > 0 })
        let ghosts = BeatPattern.make(.rock, .ghost).hits.filter { $0[DrumVoice.snare.rawValue] == 40 }.count
        #expect(ghosts > 0)
        #expect(BeatPattern.make(.rock, .push).velocity(14, .kick) > 0 && base.velocity(14, .kick) == 0)
        #expect(BeatPattern.make(.swing, .original).swing > 0.6)
    }
}
