import Foundation
import Testing
@testable import SamplerCore

@Suite("Song model")
struct SongModelTests {
    @Test func playlistAndFlatten() {
        var a = PadSequence(name: "A", bars: 1); a.add(tick: 0, length: 10, pad: 1, velocity: 100)
        var b = PadSequence(name: "B", bars: 2); b.add(tick: 960, length: 10, pad: 2, velocity: 100)
        var song = Song()
        song.steps = [SongStep(sequence: 0, repeats: 2), SongStep(sequence: 1)]
        #expect(song.playlist == [0, 0, 1])
        let flat = song.flattened([a, b], name: "F")
        #expect(flat.bars == 4)
        #expect(flat.tracks[0].events.map(\.tick) == [0, 3840, 7680 + 960])
    }
}

@MainActor
@Suite("Song playback")
struct SongControllerTests {
    final class Sink { var commands: [SamplerCommand] = [] }

    func make() -> (SamplerController, Sink) {
        let sink = Sink()
        let c = SamplerController(send: { sink.commands.append($0) })
        c.selectSequence(1)
        c.selectSequence(2)
        c.selectSequence(0)
        return (c, sink)
    }

    @Test func songQueuesEachNextStepAndEndsOnce() {
        let (c, sink) = make()
        c.addSongStep(sequence: 1)
        c.addSongStep(sequence: 2)
        c.playSong()
        #expect(c.project.currentSequence == 1 && c.songIndex == 0)
        #expect(sink.commands.contains { if case .queueSequence(let s, false, false) = $0 { s.name == "Sequence 03" } else { false } })
        c.poll(hits: [], position: 100, enginePlaying: true, sequenceGeneration: 5)
        c.poll(hits: [], position: 10, enginePlaying: true, sequenceGeneration: 6) // swapped
        #expect(c.project.currentSequence == 2 && c.songIndex == 1)
        c.poll(hits: [], position: 0, enginePlaying: false, sequenceGeneration: 6)
        #expect(!c.transport.playing && c.songIndex == nil)
    }

    @Test func loopingSongWrapsAround() {
        let (c, sink) = make()
        c.editSong("Loop") { $0.loop = true }
        c.addSongStep(sequence: 0)
        c.addSongStep(sequence: 1)
        c.playSong()
        c.poll(hits: [], position: 100, enginePlaying: true, sequenceGeneration: 1)
        c.poll(hits: [], position: 10, enginePlaying: true, sequenceGeneration: 2)
        #expect(c.project.currentSequence == 1)
        // After the last step the first is queued again.
        if case .queueSequence(let s, _, let loop)? = sink.commands.last { #expect(s.name == "Sequence 01" && loop == true) }
        else { Issue.record("no queue") }
    }

    @Test func nextSequenceWaitsWhilePlaying() {
        let (c, sink) = make()
        c.nextSequenceMode = true
        c.play()
        c.poll(hits: [], position: 50, enginePlaying: true, sequenceGeneration: 0)
        c.selectSequence(2)
        #expect(c.project.currentSequence == 0 && c.queuedSequence == 2)
        #expect(sink.commands.last.map { if case .queueSequence = $0 { true } else { false } } == true)
        c.poll(hits: [], position: 5, enginePlaying: true, sequenceGeneration: 1)
        #expect(c.project.currentSequence == 2 && c.queuedSequence == nil)
    }

    @Test func songToSequence() {
        let (c, _) = make()
        c.addSongStep(sequence: 0)
        c.addSongStep(sequence: 1)
        c.convertSongToSequence()
        #expect(c.project.sequences.count == 4 && c.sequence.bars == 4)
    }
}
