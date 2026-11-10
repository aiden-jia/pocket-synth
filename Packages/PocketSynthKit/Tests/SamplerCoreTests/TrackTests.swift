import Foundation
import Testing
@testable import SamplerCore

@Suite("Keygroups and pad perform")
struct KeygroupModelTests {
    @Test func autoMapSpreadsZonesBetweenRoots() {
        let p = KeygroupProgram.autoMap(name: "K", samples: [(SampleID("b"), 64), (SampleID("a"), 48), (SampleID("c"), 72)])
        #expect(p.zones.map(\.rootNote) == [48, 64, 72])
        #expect(p.zones.map(\.lowNote) == [0, 57, 69])
        #expect(p.zones.map(\.highNote) == [56, 68, 127])
        #expect(p.zone(for: 60)?.rootNote == 64)
    }

    @Test func padPerformLayouts() {
        var p = PadPerform()
        #expect(p.note(0) == 48 && p.note(15) == 63)
        p.mode = .scale
        p.root = 2   // D major
        #expect((0..<8).map(p.note) == [50, 52, 54, 55, 57, 59, 61, 62])
        p.scale = .minorPentatonic
        #expect(p.note(5) == 62)
    }
}

@MainActor
@Suite("Tracks")
struct TrackControllerTests {
    final class Sink { var commands: [SamplerCommand] = [] }

    func make() -> (SamplerController, Sink) {
        let sink = Sink()
        let c = SamplerController(send: { sink.commands.append($0) })
        var t = 0.0
        c.now = { t += 10; return t }
        return (c, sink)
    }

    @Test func addTrackSelectsItAndKeepsSequencesAligned() {
        let (c, _) = make()
        c.selectSequence(1)
        c.addTrack(.synth)
        #expect(c.trackIndex == 1 && c.track.program == .synth)
        #expect(c.project.sequences.allSatisfy { $0.tracks.count == 2 })
        c.undo()
        #expect(c.project.sequence.tracks.count == 1 && c.trackIndex == 0)
    }

    @Test func noteTracksTurnPadsIntoNotes() {
        let (c, sink) = make()
        let k = c.addKeygroup(KeygroupProgram(name: "Keys"))!
        c.addTrack(.keygroup(k))
        c.padDown(gridIndex: 4, y: 0)
        #expect(sink.commands.last == .liveNote(.keygroup(0), note: 52, velocity: 127))
        c.padUp(gridIndex: 4)
        #expect(sink.commands.last == .liveNote(.keygroup(0), note: 52, velocity: 0))
        #expect(c.laneValue(4) == 52)
    }

    @Test func recordingGoesToTheSelectedTrackAndIgnoresOtherKinds() {
        let (c, _) = make()
        c.addTrack(.synth)
        c.record()
        c.poll(hits: [.init(tick: 240, pad: 60, velocity: 100, isNote: true),
                      .init(tick: 480, pad: 3, velocity: 100, isNote: false)], position: 600, enginePlaying: true)
        c.stop()
        #expect(c.project.sequence.tracks[1].events.map(\.pad) == [60])
        #expect(c.project.sequence.tracks[0].events.isEmpty)
    }

    @Test func gridEditsUseTheSelectedTrack() {
        let (c, _) = make()
        c.addTrack(.midi(channel: 2))
        c.toggleStep(pad: 64, tick: 0, span: 240)
        #expect(c.project.sequence.tracks[1].events.count == 1)
        c.selectTrack(0)
        c.clearTrack()
        #expect(c.project.sequence.tracks[1].events.count == 1)
    }

    @Test func oldTracksDecodeAsDrum() throws {
        let t = try JSONDecoder().decode(Track.self, from: Data(#"{"name":"T","events":[],"mute":false}"#.utf8))
        #expect(t.program == .drum && !t.solo)
    }
}
