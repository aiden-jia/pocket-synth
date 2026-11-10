import ChordTheory
import Testing
@testable import SynthCore

@Suite("MIDI parsing and control")
struct MIDITests {
    @Test func umpRoundTrip() {
        let on = MIDIMessage.ump(status: 0x93, data1: 60, data2: 100)
        #expect(MIDIMessage(ump: on) == .noteOn(channel: 3, note: 60, velocity: 100))
        #expect(MIDIMessage(ump: MIDIMessage.ump(status: 0x93, data1: 60, data2: 0)) == .noteOff(channel: 3, note: 60))
        #expect(MIDIMessage(ump: MIDIMessage.ump(status: 0xB0, data1: 64, data2: 127)) == .controlChange(channel: 0, controller: 64, value: 127))
        #expect(MIDIMessage(ump: MIDIMessage.ump(status: 0xF8, data1: 0, data2: 0)) == .clock)
        #expect(MIDIMessage(ump: MIDIMessage.ump(status: 0xFA, data1: 0, data2: 0)) == .start)
        #expect(MIDIMessage.noteOn(channel: 1, note: 40, velocity: 90).bytes! == (0x91, 40, 90))
    }

    @Test func clockFollowerFindsTheTempoAndHolds() {
        var f = ClockFollower()
        var found: Double?
        let interval = 60.0 / 100 / 24 // 100 BPM
        for i in 0..<48 { if let b = f.tick(at: Double(i) * interval) { found = b } }
        #expect(found == 100)
        // Same tempo: no new reports. A long gap then a new tempo starts fresh.
        #expect(f.tick(at: 48 * interval) == nil)
        var t = 10.0
        var later: Double?
        for _ in 0..<30 { t += 60.0 / 140 / 24; if let b = f.tick(at: t) { later = b } }
        #expect(later == 140)
    }

    @Test func controlCCsNeedTheGate() {
        var m = MIDIControlMap()
        #expect(m.handle(channel: 0, controller: 21, value: 5) == nil)
        _ = m.handle(channel: 0, controller: 127, value: 1)
        #expect(m.handle(channel: 0, controller: 21, value: 17) == .key(5))
        #expect(m.handle(channel: 1, controller: 21, value: 5) == nil) // other channel not open
        #expect(m.handle(channel: 0, controller: 20, value: 0) == nil)
        #expect(m.handle(channel: 0, controller: 50, value: 97) == .tempo(97))
        #expect(m.handle(channel: 0, controller: 22, value: 66) == .octave(2))
        #expect(m.handle(channel: 0, controller: 31, value: 127) == .reverb(6))
        if case .cutoff(let hz)? = m.handle(channel: 0, controller: 29, value: 127) { #expect(abs(hz - 20_000) < 1) }
        _ = m.handle(channel: 0, controller: 127, value: 0)
        #expect(m.handle(channel: 0, controller: 21, value: 1) == nil)
    }

    @MainActor @Test func controlActionsChangeTheSynth() {
        let r = Rig()
        r.c.apply(.key(7))
        r.c.apply(.tempo(88))
        r.c.apply(.reverb(2))
        #expect(r.c.state.key == Key(7) && r.c.state.bpm == 88 && r.c.state.fxIndex(.reverb) == 2)
        #expect(r.commands.contains(.tempo(88)))
    }

    @MainActor @Test func liveChannelFollowsTheLooper() {
        let r = Rig()
        #expect(r.c.liveMIDIChannel == 0)
        r.on(.clickDown, .clickUp)                     // track 1 waiting / recording
        #expect(r.c.liveMIDIChannel == 0)
        r.c.updateLooper([LoopTrackReport(state: .play, generation: r.c.looper.tracks[0].generation)],
                         length: 1000, position: 0)
        #expect(r.c.liveMIDIChannel == 1)              // next empty track's channel
    }

    @MainActor @Test func midiOutSettingReachesTheEngine() {
        let r = Rig()
        let i = SettingRow.allCases.firstIndex(of: .midiOut)!
        r.on(.menuDown(.sound), .menuUp(.sound), .stick(.up), .stick(nil))
        for _ in 0..<i { r.on(.stick(.right), .stick(nil)) }
        r.on(.stick(.up), .stick(nil))
        #expect(!r.c.state.midiOut)
        #expect(r.commands.contains(.midiOut(false)))
    }
}
