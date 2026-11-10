import ChordTheory
import Testing
@testable import SynthCore

/// Drives a controller with scripted events and records what it sends to the engine.
@MainActor
final class Rig {
    var commands: [EngineCommand] = []
    let c: SynthController
    var t = 0.0

    init(_ state: SynthState = SynthState()) {
        c = SynthController(state: state)
        c.send = { [unowned self] in self.commands.append($0) }
    }

    func on(_ events: ControlEvent..., dt: Double = 0.05) {
        for e in events {
            t += dt
            c.handle(e, at: t)
        }
    }

    /// Name of the chord currently in a slot.
    func slot(_ pad: Int) -> String? { c.sounding[pad]?.name }

    var lastChordCommand: (slot: Int, voicing: Voicing?)? {
        for cmd in commands.reversed() {
            if case .chord(let s, let v) = cmd { return (s, v) }
        }
        return nil
    }
}

@MainActor
@Suite("Pads and stick")
struct PadTests {
    @Test func padPlaysAndReleases() {
        let r = Rig()
        r.on(.padDown(1))
        #expect(r.slot(1) == "C")
        #expect(r.lastChordCommand?.voicing?.notes == [60, 64, 67])
        r.on(.padUp(1))
        #expect(r.slot(1) == nil)
        #expect(r.lastChordCommand?.slot == 1)
        #expect(r.lastChordCommand?.voicing == nil)
    }

    @Test func stickModifiesWhileHeldAndSnapsBack() {
        let r = Rig()
        r.on(.padDown(1), .stick(.up))
        #expect(r.slot(1) == "Cm")
        r.on(.stick(.upRight))
        #expect(r.slot(1) == "C7")
        r.on(.stick(nil))
        #expect(r.slot(1) == "C")
    }

    @Test func stickHeldBeforePadApplies() {
        let r = Rig()
        r.on(.stick(.right), .padDown(5))
        #expect(r.slot(5) == "Gmaj7")
    }

    @Test func slashChordFromTwoPads() {
        let r = Rig()
        r.on(.padDown(1), .padDown(6))
        #expect(r.slot(1) == nil)          // bass pad goes silent
        #expect(r.slot(6) == "Am/C")
        #expect(r.c.sounding[6]?.bass == 36)
    }

    @Test func leadModePlaysRootsAndStickBends() {
        var s = SynthState()
        s.mode = .lead
        let r = Rig(s)
        r.on(.padDown(5))
        #expect(r.c.sounding[5]?.notes == [67])
        r.on(.stick(.up))
        #expect(r.c.sounding[5]?.notes == [79])
        r.on(.stick(.left))
        #expect(r.c.sounding[5]?.notes == [66])
    }

    @Test func droneLatchesAndSwitches() {
        var s = SynthState()
        s.mode = .drone
        let r = Rig(s)
        r.on(.padDown(1), .padUp(1))
        #expect(r.slot(1) == "C")
        r.on(.padDown(4), .padUp(4))
        #expect(r.slot(1) == nil)
        #expect(r.slot(4) == "F")
    }
}

@MainActor
@Suite("Pad + menu combos")
struct ComboTests {
    @Test func padOctaveAndInversion() {
        let r = Rig()
        r.on(.padDown(1), .menuDown(.mode), .menuUp(.mode))
        #expect(r.c.state.padOctave[0] == 1)
        #expect(r.c.sounding[1]?.notes == [72, 76, 79])
        #expect(r.c.openMenu == nil)       // combo must not leave a menu open
        r.on(.menuDown(.key), .menuUp(.key), .menuDown(.key), .menuUp(.key))
        #expect(r.c.state.padOctave[0] == -1)
        r.on(.menuDown(.sound), .menuUp(.sound))
        #expect(r.c.state.padInversion[0] == .first)
        #expect(r.c.sounding[1]?.notes == [52, 55, 60])
    }

    @Test func chordLockToggle() {
        let r = Rig()
        // Lock pad 1 as C7.
        r.on(.padDown(1), .stick(.upRight), .menuDown(.sound), .menuUp(.sound))
        #expect(r.c.state.locks[1]?.chord.name() == "C7")
        #expect(r.c.state.padInversion[0] == .root) // lock, not inversion
        r.on(.stick(nil), .padUp(1))
        r.on(.padDown(1))
        #expect(r.slot(1) == "C7")
        r.on(.padUp(1))
        // Same gesture unlocks.
        r.on(.padDown(1), .stick(.upRight), .menuDown(.sound), .menuUp(.sound), .stick(nil), .padUp(1))
        #expect(r.c.state.locks[1] == nil)
    }

    @Test func lockSurvivesKeyChangeButNotScaleChange() {
        let r = Rig()
        r.on(.padDown(2), .stick(.up), .menuDown(.sound), .menuUp(.sound), .stick(nil), .padUp(2))
        #expect(r.c.state.locks[2]?.chord.name() == "D")
        // Key menu → D.
        r.on(.menuDown(.key), .menuUp(.key), .stick(.right), .stick(nil))
        #expect(r.c.state.key == Key(1))
        r.on(.padDown(2))
        #expect(r.slot(2) == "D")           // still the locked chord
        r.on(.padUp(2))
        // Scale change clears locks.
        var s = r.c.state
        SettingRow.scale.set(1, in: &s)
        #expect(s.locks.isEmpty)
    }

    @Test func menuThenPadQuickSelects() {
        let r = Rig()
        r.on(.menuDown(.sound), .padDown(3), .padUp(3), .menuUp(.sound))
        #expect(r.c.state.sound.name == "FM EP")
        #expect(r.c.openMenu == nil)
        #expect(r.slot(3) == nil)            // combo, not a chord
        r.on(.menuDown(.mode), .padDown(2), .padUp(2), .menuUp(.mode))
        #expect(r.c.state.mode == .strum)
        r.on(.menuDown(.sound), .padDown(4), .padUp(4), .menuUp(.sound))
        #expect(r.c.state.sound.name == "FM Piano") // hidden sound
    }

    @Test func arpPatternCombos() {
        var s = SynthState()
        s.mode = .arp
        let r = Rig(s)
        r.on(.menuDown(.key), .padDown(3), .padUp(3), .menuUp(.key))
        #expect(r.c.state.arpPattern == .upDown)
        r.on(.menuDown(.key), .padDown(7), .padUp(7), .menuUp(.key))
        #expect(r.c.state.arpLayer == .chordArp)
    }
}

@MainActor
@Suite("Menus")
struct MenuTests {
    @Test func keyMenuChangesKeyAndOctave() {
        let r = Rig()
        r.on(.menuDown(.key), .menuUp(.key))
        #expect(r.c.openMenu == .key)
        r.on(.stick(.right), .stick(nil), .stick(.right), .stick(nil), .stick(.up), .stick(nil))
        #expect(r.c.state.key == Key(2))
        #expect(r.c.state.globalOctave == 1)
        // A pad press closes the menu and plays in the new key.
        r.on(.padDown(1))
        #expect(r.c.openMenu == nil)
        #expect(r.slot(1) == "D")
        #expect(r.c.sounding[1]?.notes == [74, 78, 81])
    }

    @Test func keyMenuClosesWhenIdle() {
        let r = Rig()
        r.on(.menuDown(.key), .menuUp(.key))
        r.c.tick(at: r.t + 2)
        #expect(r.c.openMenu == .key)
        r.c.tick(at: r.t + 6)
        #expect(r.c.openMenu == nil)
    }

    @Test func settingsListCyclesValues() {
        let r = Rig()
        r.on(.menuDown(.sound), .menuUp(.sound), .stick(.up), .stick(nil))
        #expect(r.c.openMenu == .settings(row: 0))     // REVERB row
        r.on(.stick(.up), .stick(nil))
        #expect(r.c.state.fxIndex(.reverb) == 1)
        #expect(r.commands.contains(.fx(.reverb, 1)))
        // Walk to the JOYSTICK row and cycle it.
        let target = SettingRow.allCases.firstIndex(of: .stickMode)!
        for _ in 0..<target { r.on(.stick(.right), .stick(nil)) }
        #expect(r.c.openMenu == .settings(row: target))
        r.on(.stick(.up), .stick(nil))
        #expect(r.c.state.stickMode == .extended)
        r.on(.stick(.down), .stick(nil))
        #expect(r.c.openMenu == .sound)
    }

    @Test func modeMenuBrowsesAndConfirmsTools() {
        let r = Rig()
        r.on(.menuDown(.mode), .menuUp(.mode))
        r.on(.stick(.right), .stick(nil))
        #expect(r.c.state.mode == .strum)            // regular modes switch immediately
        r.on(.stick(.down), .stick(nil))
        #expect(r.c.state.strumSpeed == .fast)
        let gameIndex = r.c.availableModes.firstIndex(of: .game)!
        for _ in 1..<gameIndex { r.on(.stick(.right), .stick(nil)) }
        #expect(r.c.openMenu == .mode(highlight: gameIndex))
        #expect(r.c.state.mode == .beat)             // GAME only highlighted
        r.on(.clickDown, .clickUp)
        #expect(r.c.state.mode == .game)
        #expect(r.c.openMenu == nil)
    }

    @Test func mixerHiddenUntilLooperHasAudio() {
        let r = Rig()
        #expect(!r.c.availableModes.contains(.mixer))
        r.c.updateLooper([LoopTrackReport(state: .play, generation: 0)], length: 1000, position: 0)
        #expect(r.c.availableModes.last == .mixer)
    }

    @Test func tapTempo() {
        let r = Rig()
        r.on(.menuDown(.mode), .menuUp(.mode), dt: 0.0)
        r.t = 10.0; r.c.handle(.menuDown(.mode), at: 10.0); r.c.handle(.menuUp(.mode), at: 10.05)
        r.c.handle(.menuDown(.mode), at: 10.6); r.c.handle(.menuUp(.mode), at: 10.65)
        r.c.handle(.menuDown(.mode), at: 11.2); r.c.handle(.menuUp(.mode), at: 11.25)
        #expect(r.c.state.bpm == 100)
        #expect(r.c.openMenu == nil)
        #expect(r.commands.contains(.tempo(100)))
    }

    @Test func presetsSaveAndLoad() {
        let r = Rig()
        r.on(.menuDown(.key), .menuDown(.sound), .menuUp(.sound), .menuUp(.key))
        #expect(r.c.openMenu == .presets(slot: 0))
        r.on(.stick(.up), .stick(nil))
        #expect(r.c.dialog == .save(slot: 0))
        r.on(.stick(.up), .stick(nil))
        #expect(r.c.presets[0] != nil)
        // Change something, then load P1 back.
        r.on(.padDown(1), .padUp(1)) // closes menu
        r.on(.menuDown(.sound), .padDown(2), .padUp(2), .menuUp(.sound))
        #expect(r.c.state.sound.name == "Sine")
        r.on(.menuDown(.key), .menuDown(.sound), .menuUp(.sound), .menuUp(.key))
        r.on(.stick(.down), .stick(nil))
        #expect(r.c.dialog == .load(slot: 0))
        r.on(.stick(.up), .stick(nil))
        #expect(r.c.state.sound.name == "Saw")
    }
}

@MainActor
@Suite("Wheel, randomize, engine diff")
struct MiscTests {
    @Test func wheelCombos() {
        let r = Rig()
        r.on(.wheel(-0.3))
        #expect(abs(r.c.state.volume - 0.5) < 1e-9)
        r.on(.menuDown(.key), .wheel(0.1), .menuUp(.key))
        #expect((r.c.state.attackOverrideMs ?? 0) > 100)
        #expect(r.c.openMenu == nil)                 // combo closes the key menu
        r.on(.menuDown(.mode), .wheel(-0.5), .menuUp(.mode))
        #expect(r.c.state.filterCutoffHz < 1000)
        // Picking an ADSR preset clears fine-tune.
        var s = r.c.state
        SettingRow.envelope.set(0, in: &s)
        #expect(s.attackOverrideMs == nil)
    }

    @Test func randomizeIsDeterministicAndKeepsKeyForSound() {
        let a = Rig(), b = Rig()
        a.on(.menuDown(.sound), .clickDown, .clickUp, .menuUp(.sound))
        b.on(.menuDown(.sound), .clickDown, .clickUp, .menuUp(.sound))
        #expect(a.c.state == b.c.state)
        #expect(a.c.state.key == .c)
        #expect(a.c.openMenu == nil)
    }

    @Test func modeChangeSilencesEverything() {
        var st = SynthState()
        st.mode = .drone
        let r = Rig(st)
        r.on(.padDown(1), .padUp(1))   // drone keeps it latched
        #expect(r.slot(1) == "C")
        r.commands.removeAll()
        r.on(.menuDown(.mode), .menuUp(.mode), .stick(.right), .stick(nil))
        #expect(r.commands.first == .allNotesOff)
        #expect(r.c.sounding.isEmpty)
    }

    @Test func startSendsFullState() {
        let r = Rig()
        r.c.start()
        #expect(r.commands.contains(.volume(0.8)))
        #expect(r.commands.contains(.tempo(120)))
        #expect(r.commands.contains(.mode(.play)))
    }

    @Test func statusLine() {
        let r = Rig()
        #expect(r.c.display.status == "C Major · STD · PLAY")
        #expect(r.c.padLabel(7) == "B°")
    }
}
