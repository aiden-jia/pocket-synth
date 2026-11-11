import Foundation
import Testing
@testable import SamplerCore

@Suite("Retrospective capture, auto-sampled keygroups, clips (models)")
struct SamplerExtrasModelTests {
    func ev(_ beat: Double, _ d: RetroEvent.Destination, _ note: Int, _ vel: Int = 100, time: Double = 0) -> RetroEvent {
        RetroEvent(beat: beat, destination: d, note: note, velocity: vel, time: time)
    }

    @Test func captureMakesWholeBarsWithATrackPerDestination() throws {
        let events = [
            ev(9.0, .keygroup(2), 60), ev(9.5, .keygroup(2), 60, 0),   // bar 3 (beats 8–11)
            ev(9.25, .pad, 3), ev(13.6, .pad, 4),                       // bar 4
        ]
        let seq = try #require(RetroCapture.sequence(from: events, beatsPerBar: 4, name: "R", timing: nil))
        #expect(seq.bars == 2)
        #expect(seq.tracks.map(\.program) == [.drum, .keygroup(2)]) // pads first
        #expect(seq.tracks[0].events.map(\.tick) == [Int(1.25 * 960), Int(5.6 * 960)])
        #expect(seq.tracks[1].events.first?.tick == 960)
        #expect(seq.tracks[1].events.first?.length == 480)            // from the release
        #expect(seq.tracks[0].events.first?.length == 240)            // no release: a 16th
    }

    @Test func captureKeepsOnlyTheLatestPhrase() throws {
        // Two hits, 3 bars of silence, then the phrase we want (bar 6).
        let events = [ev(0, .synth, 60), ev(1, .synth, 62), ev(17, .pad, 1), ev(18, .pad, 2), ev(21.5, .pad, 1)]
        let seq = try #require(RetroCapture.sequence(from: events, beatsPerBar: 4, name: "R", timing: nil))
        #expect(seq.bars == 2 && seq.tracks.map(\.program) == [.drum])
        #expect(seq.tracks[0].events.map(\.tick) == [960, 1920, Int(5.5 * 960)])
    }

    @Test func captureCanQuantize() throws {
        var tc = TimingCorrect()
        tc.value = .sixteenth
        let seq = try #require(RetroCapture.sequence(from: [ev(0.27, .pad, 0), ev(1.48, .synth, 64)], beatsPerBar: 4,
                                                     name: "R", timing: tc))
        #expect(seq.tracks[0].events[0].tick == 240)
        #expect(seq.tracks[1].events[0].tick == 1440)
        #expect(RetroCapture.sequence(from: [ev(1, .pad, 0, 0)], beatsPerBar: 4, name: "R", timing: nil) == nil)
    }

    @Test func bufferKeepsThirtySecondsAndRestartsWhenTheClockJumps() {
        var b = RetroBuffer()
        b.add([ev(1, .pad, 0, time: 0), ev(2, .pad, 1, time: 10)], now: 10)
        #expect(b.hitCount == 2)
        b.add([ev(30, .pad, 2, time: 35)], now: 35)
        #expect(b.events.map(\.note) == [1, 2]) // the first is over 30 s old
        b.add([ev(-4, .pad, 3, time: 36)], now: 36) // transport started: beats went back
        #expect(b.events.map(\.note) == [3])
    }

    @Test func autoSampledKeygroupSplitsNotesAndVelocities() {
        let takes = [(48, 64, SampleID("a")), (48, 127, SampleID("b")), (60, 64, SampleID("c")), (60, 127, SampleID("d"))]
            .map { (note: $0.0, velocity: $0.1, id: $0.2) }
        let k = KeygroupProgram.autoSampled(name: "A", takes: takes)
        #expect(k.zones.map(\.rootNote) == [48, 60])
        #expect(k.zones.map(\.lowNote) == [0, 55] && k.zones.map(\.highNote) == [54, 127])
        let layers = k.zones[0].layers
        #expect(layers.map(\.sampleID) == [SampleID("a"), SampleID("b")])
        #expect(layers.map(\.velocityLow) == [0, 65] && layers.map(\.velocityHigh) == [64, 127])
    }

    @Test func clipBeatsGuessAndGroups() {
        #expect(ClipPad.guessBeats(seconds: 2, bpm: 120) == 4)
        #expect(ClipPad.guessBeats(seconds: 7.7, bpm: 125) == 16)
        #expect(ClipProgram.group(0) == ClipProgram.group(12) && ClipProgram.group(1) != ClipProgram.group(0))
        #expect(ClipQuantize.bar.beats(beatsPerBar: 3) == 3)
    }

    @Test func trackPrograms() {
        #expect(!TrackProgram.audio.isNotes && !TrackProgram.clip.isNotes && TrackProgram.synth.isNotes)
        var seq = PadSequence(name: "S")
        seq.tracks = [Track(program: .audio), Track(), Track(program: .audio)]
        #expect(seq.audioSlots.map(\.track) == [0, 2] && seq.audioSlots.map(\.slot) == [0, 1])
    }

    @Test func oldTracksDecodeWithoutArpOrAudio() throws {
        let t = try JSONDecoder().decode(Track.self, from: #"{"name":"T","program":{"synth":{}}}"#.data(using: .utf8)!)
        #expect(t.arp == TrackArp() && t.audio == nil && t.program == .synth)
        var a = Track(program: .audio)
        a.audio = AudioClip(sampleID: SampleID("x"), startTick: 960)
        a.arp.on = true
        #expect(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(a)) == a)
    }
}

@MainActor
@Suite("Sampler extras: controller")
struct SamplerExtrasControllerTests {
    final class Sink { var commands: [SamplerCommand] = [] }

    func make() -> (SamplerController, Sink) {
        let sink = Sink()
        let c = SamplerController(send: { sink.commands.append($0) })
        var t = 0.0
        c.now = { t += 10; return t }
        return (c, sink)
    }

    func info(_ name: String) -> SampleInfo {
        SampleInfo(id: SampleID(name), name: name, fileName: "\(name).wav", frames: 48_000, sampleRate: 48_000, channels: 1)
    }

    @Test func clipTrackPadsLaunchClipsAndRecordLaunches() {
        let (c, sink) = make()
        c.addTrack(.clip)
        c.padDown(gridIndex: 5)
        c.padUp(gridIndex: 5)
        #expect(sink.commands.suffix(2) == [.clipPad(5, down: true), .clipPad(5, down: false)])
        #expect(c.selectedClip == 5 && c.stepLane == 5 && c.laneValue(7) == 7)

        c.record()
        c.poll(hits: [RecordedHit(tick: 0, pad: 5, velocity: 100, isClip: true),
                      RecordedHit(tick: 10, pad: 2, velocity: 100),                 // a pad hit: not ours
                      RecordedHit(tick: 1920, pad: 5, velocity: 0, isClip: true)], position: 1920, enginePlaying: true)
        c.stop()
        #expect(c.track.events.map(\.pad) == [5])
        #expect(c.track.events.first?.length == 1920)
    }

    @Test func clipEditsAreUndoableAndTheirSamplesCountAsUsed() {
        let (c, sink) = make()
        c.addSamples([info("loop")], autoAssign: false)
        c.updateClips { $0.pads[3] = ClipPad(sampleID: SampleID("loop")) }
        #expect(c.usedSampleIDs.contains(SampleID("loop")))
        if case .clips(let p, _)? = sink.commands.last { #expect(p.pads[3].sampleID == SampleID("loop")) } else { Issue.record("no clips sent") }
        c.undo()
        #expect(c.project.clips.pads[3].sampleID == nil)
        c.redo()
        c.removeSample(SampleID("loop"))
        #expect(c.project.clips.pads[3].sampleID == nil)
    }

    @Test func audioTracksHoldAClipAndRecordThroughTheApp() {
        let (c, _) = make()
        let t = c.addAudioTrack(info("vox"), startTick: 960)!
        #expect(c.track.program == .audio && c.track.audio?.startTick == 960 && c.track.name == "vox")
        #expect(c.project.sequences.allSatisfy { $0.tracks.count == 2 })
        c.undo()
        #expect(c.sequence.tracks.count == 1)
        c.redo()

        var calls: [(Bool, Int)] = []
        c.onAudioRecord = { calls.append(($0, $1)) }
        c.selectTrack(t)
        c.record()
        #expect(c.transport.recording != nil && c.audioTakeTrack == t)
        c.poll(hits: [RecordedHit(tick: 0, pad: 1, velocity: 100)], position: 100, enginePlaying: true)
        #expect(c.track.events.isEmpty) // hits never land on an audio track
        c.stop()
        #expect(calls.map(\.0) == [true, false] && calls.allSatisfy { $0.1 == t })
        c.finishAudioTake(track: t, sample: info("take"), startTick: 0)
        #expect(c.track.audio?.sampleID == SampleID("take"))
        #expect(c.project.sample(SampleID("take")) != nil)
        c.removeSample(SampleID("take"))
        #expect(c.track.audio == nil)
    }

    @Test func arpSettingsLiveOnTheTrack() {
        let (c, _) = make()
        c.addTrack(.synth)
        c.setTrackArp(c.trackIndex) { $0.on = true; $0.octaves = 9; $0.mode = .down }
        #expect(c.track.arp.on && c.track.arp.octaves == 4 && c.track.arp.mode == .down)
        c.undo()
        #expect(!c.track.arp.on)
    }

    @Test func retroCaptureAddsASelectedSequence() {
        let (c, _) = make()
        let name = c.captureRetro([RetroEvent(beat: 5, destination: .pad, note: 2, velocity: 90)], quantize: false)
        #expect(name == "Retro 02")
        #expect(c.project.currentSequence == 1 && c.sequence.tracks[0].events.first?.tick == 960)
        c.undo()
        #expect(c.project.sequences.count == 1)
        #expect(c.captureRetro([], quantize: true) == nil)
    }
}
