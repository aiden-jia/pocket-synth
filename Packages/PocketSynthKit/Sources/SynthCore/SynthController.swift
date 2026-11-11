import ChordTheory
import Foundation
import Observation

/// The synth panel's brain: one explicit state machine that turns `ControlEvent`s into
/// state changes and `EngineCommand`s (DESIGN §5.2).
///
/// Event priority: open dialog → combo with something already held → open menu → mode.
/// Time is passed in (`now`, seconds) so every gesture is deterministic in tests.
@MainActor
@Observable
public final class SynthController {
    public private(set) var state: SynthState
    public private(set) var heldPads: [Int] = []          // in press order
    public private(set) var stick: StickDirection?
    public private(set) var openMenu: OpenMenu?
    public private(set) var dialog: Dialog?
    public private(set) var presets: [SynthState?] = Array(repeating: nil, count: 4)
    public private(set) var sounding: [Int: Voicing] = [:] // slot -> voicing
    public private(set) var lastChordName: String?
    public private(set) var toast: Toast?
    /// The synth looper, as far as the controller knows (engine telemetry keeps it current).
    public private(set) var looper = LooperState()
    /// MIXER only appears in the mode list once loops exist.
    public var looperHasAudio: Bool { looper.hasAudio }
    /// Beat mode: the style player is running.
    public private(set) var beatPlaying = false
    /// Seq mode: the chord sequencer is running, and the step being edited.
    public private(set) var seqPlaying = false
    public private(set) var seqCursor = 0
    /// Step the engine is playing (set by the app from engine telemetry).
    public var seqPlayhead: Int?

    // Tools (phase 6): Tuner, Mic, Trainer, Game.
    /// Tuner mode: the latest (smoothed) reading from the app.
    public private(set) var tuner: TunerReading?
    /// Mic mode: pad 1 is held and the take is recording.
    public private(set) var micRecording = false
    public private(set) var trainer: EarTrainer
    /// Trainer: the expected answers, shown once a question is answered.
    public private(set) var trainerReveal: [String]?
    public private(set) var gameSong = 0
    public private(set) var gameSpeed = 1.0
    public private(set) var game: GameRun?
    public private(set) var gameResult: GameRun?
    /// Best accuracy by song name (full-speed runs only).
    public private(set) var gameBest: [String: Int]
    /// Asks the app to start (true) or stop (false) a Mic-mode take.
    @ObservationIgnored public var onMicRecord: (Bool) -> Void = { _ in }
    /// Seconds from sending a command to hearing it (Game lines the chart up with the drums).
    @ObservationIgnored public var outputLatency = 0.0
    @ObservationIgnored private var scheduled: [(at: Double, command: EngineCommand)] = []
    @ObservationIgnored private var nextQuestionAt: Double?
    @ObservationIgnored private var answerStick: StickDirection?
    @ObservationIgnored private var micStartedAt: Double?
    public static let micMaxSeconds = 3.0

    @ObservationIgnored public var send: (EngineCommand) -> Void
    /// Called after the session (state or presets) changes, for saving.
    @ObservationIgnored public var onSessionChange: (SynthSession) -> Void = { _ in }
    @ObservationIgnored private var clickDownAt: Double?
    @ObservationIgnored private var clickTarget = 0
    @ObservationIgnored private var clickConsumed = false
    /// Mixer mode: pads held for a combo (solo, wheel) don't mute on release.
    @ObservationIgnored private var mixerComboPads: Set<Int> = []
    /// Observed: the K/S/M keys light from it.
    private var heldMenus: Set<MenuKey> = []
    @ObservationIgnored private var comboUsed: Set<MenuKey> = []
    @ObservationIgnored private var menuOpenedBy: MenuKey?
    @ObservationIgnored private var lastActivity = 0.0
    @ObservationIgnored private var now = 0.0
    @ObservationIgnored private var tapTimes: [Double] = []
    @ObservationIgnored private var slashBassPad: Int?
    @ObservationIgnored private var lastVoicedNotes: [Int]?
    /// After a chord lock, ignore the stick until it returns to center.
    @ObservationIgnored private var stickConsumed = false
    @ObservationIgnored private var droneSlot: Int?
    /// Seq mode: the current stick push, and whether a pad or click used it.
    @ObservationIgnored private var seqPush: StickDirection?
    @ObservationIgnored private var pushUsed = false
    @ObservationIgnored private var drumRepeatVoice: DrumVoice?
    @ObservationIgnored private var rng: SplitMix64

    public static let menuIdleTimeout = 5.0
    public static let toastDuration = 1.2
    public static let tapWindow = 1.0
    /// Hold time on the stick click that clears a loop (SYNTH_SPEC §5).
    public static let clearHold = 0.7
    public static let countInBeats = 4

    public init(state: SynthState = SynthState(), presets: [SynthState?] = Array(repeating: nil, count: 4),
                gameBest: [String: Int] = [:], seed: UInt64 = 0x5EED,
                send: @escaping (EngineCommand) -> Void = { _ in }) {
        self.state = state
        self.gameBest = gameBest
        trainer = EarTrainer(level: state.trainerLevel, seed: seed ^ 0x7A)
        if state.mode == .trainer { nextQuestionAt = 0 } // relaunched in Trainer: ask on the first tick
        self.presets = Array((presets + Array(repeating: nil, count: 4)).prefix(4))
        self.send = send
        self.rng = SplitMix64(seed: seed)
    }

    /// What gets saved between launches (chord locks are session-only, so they're dropped).
    public var session: SynthSession {
        var s = state
        s.locks.removeAll()
        return SynthSession(state: s, presets: presets, gameBest: gameBest)
    }

    /// Pushes the full current state to the engine (call once after wiring `send`).
    public func start() {
        for c in EngineCommand.diff(from: nil, to: state) { send(c) }
    }

    // MARK: - Event entry points

    public func handle(_ event: ControlEvent, at time: Double) {
        now = time
        lastActivity = time
        switch event {
        case .padDown(let p): padDown(p)
        case .padUp(let p): padUp(p)
        case .menuDown(let k): menuDown(k)
        case .menuUp(let k): menuUp(k)
        case .stick(let d): stickMoved(d)
        case .clickDown: clickDown()
        case .clickUp: clickUp()
        case .wheel(let d): wheel(d)
        }
    }

    /// Sets the shared tempo (top bar, tap tempo elsewhere), 40...300 BPM.
    public func setTempo(_ bpm: Double) {
        mutate { $0.bpm = min(300, max(40, bpm.rounded())) }
    }

    public func setMetronome(_ on: Bool) { mutate { $0.metronome = on } }

    /// A gated MIDI control CC (see MIDIControlMap).
    public func apply(_ action: MIDIControlMap.Action) {
        mutate { s in
            switch action {
            case .tempo(let bpm): s.bpm = bpm
            case .key(let k): s.key = Key(k)
            case .octave(let o): s.globalOctave = o
            case .cutoff(let hz):
                s.filterCutoffHz = hz
                s.fx[.filter] = 1
            case .reverb(let r): s.fx[.reverb] = r == 0 ? nil : r
            }
        }
    }

    /// Live MIDI channel (0-based) for synth playing (SYNTH_SPEC §9): the recording
    /// track's channel, else the next empty track's, else 7 when all six are full.
    public var liveMIDIChannel: Int {
        if let r = looper.tracks.firstIndex(where: { $0.state == .record || $0.state == .waiting }) { return r }
        return looper.tracks.firstIndex { $0.state == .off } ?? 6
    }

    /// Call periodically (e.g. 4×/s) to expire toasts and idle menus.
    public func tick(at time: Double) {
        now = time
        if let t0 = clickDownAt, !clickConsumed, time - t0 >= Self.clearHold { clickHeldLong() }
        fireScheduled(upTo: time)
        if state.mode == .trainer, let t = nextQuestionAt, time >= t {
            nextQuestionAt = nil
            askQuestion()
        }
        if micRecording, let t0 = micStartedAt, time - t0 >= Self.micMaxSeconds { stopMic() }
        if game != nil { advanceGame(time) }
        if let t = toast, time >= t.until { toast = nil }
        if dialog == nil, time - lastActivity > Self.menuIdleTimeout {
            switch openMenu {
            case .key, .presets: openMenu = nil
            default: break
            }
        }
    }

    // MARK: - Pads

    private func padDown(_ pad: Int) {
        guard (1...7).contains(pad) else { return }
        if !heldMenus.isEmpty {
            menuThenPad(pad)
            return
        }
        openMenu = nil
        dialog = nil
        heldPads.removeAll { $0 == pad }
        heldPads.append(pad)

        if let t = looper.freeArmed, state.mode != .mixer, state.mode != .seq, !state.mode.isTool {
            startFreeTake(t)
        }

        switch state.mode {
        case .tuner:
            return
        case .mic:
            if pad == 1 { startMic() } else { showToast("HOLD PAD 1 TO RECORD") }
            return
        case .trainer:
            trainerPadDown(pad)
            return
        case .game:
            game?.hit(pad: pad, at: now)
        case .mixer:
            mixerComboPads.remove(pad) // mute / metronome happen on release
            return
        case .drums:
            guard let voice = DrumVoice.forPad(pad) else { return }
            send(.drumHit(voice, velocity: 100))
            lastChordName = voice.label
            if let s = stick { startDrumRepeat(voice, s) }
            return
        case .beat:
            beatPad(pad)
            return
        case .seq:
            if seqPush != nil { pushUsed = true }
        default:
            break
        }

        // Slash chord: the first held pad becomes the bass of later pads.
        if state.mode.supportsSlashChords, heldPads.count >= 2, slashBassPad == nil {
            slashBassPad = heldPads[0]
            release(heldPads[0])
        }
        if state.mode == .drone, let d = droneSlot, d != pad { release(d) }
        sound(pad)
        if state.mode == .drone { droneSlot = pad }
    }

    private func padUp(_ pad: Int) {
        heldPads.removeAll { $0 == pad }
        switch state.mode {
        case .tuner:
            return
        case .mic:
            if pad == 1, micRecording { stopMic() }
            return
        case .trainer:
            trainerPadUp(pad)
            return
        default:
            break
        }
        if state.mode == .drums || state.mode == .beat {
            if let v = drumRepeatVoice, v == DrumVoice.forPad(pad) { stopDrumRepeat() }
            return
        }
        if state.mode == .mixer {
            if mixerComboPads.remove(pad) == nil { mixerPad(pad) }
            return
        }
        if pad == slashBassPad || heldPads.isEmpty { slashBassPad = nil }
        if state.mode == .drone { return } // latched until mode change or the next chord
        release(pad)
    }

    private func sound(_ pad: Int) {
        let useStick = pad == heldPads.last && !stickConsumed
        let bass = slashBassPad.flatMap { $0 == pad ? nil : $0 }
        let v = ChordResolver.voicing(pad: pad, state: state, stick: useStick ? stick : nil,
                                      slashBassPad: bass, previous: lastVoicedNotes)
        sounding[pad] = v
        lastVoicedNotes = v.notes
        lastChordName = v.name
        send(.chord(slot: pad, voicing: v))
        // Seq mode, stopped: the pad (with any stick modification) fills the cursor step.
        if state.mode == .seq, !seqPlaying, pad == heldPads.last {
            mutate { $0.chordSequence.steps[min(seqCursor, $0.chordSequence.length - 1)] = v }
        }
    }

    private func release(_ slot: Int) {
        guard sounding.removeValue(forKey: slot) != nil else { return }
        send(.chord(slot: slot, voicing: nil))
    }

    // MARK: - Stick

    private func stickMoved(_ dir: StickDirection?) {
        let changed = dir != stick
        stick = dir
        if dir == nil { stickConsumed = false }
        guard changed else { return }

        if let d = dialog {
            if dir == .up { confirm(d) } else if dir == .down { dialog = nil }
            return
        }
        switch state.mode {
        case .drums:
            if let pad = heldPads.last, let voice = DrumVoice.forPad(pad) {
                if let dir { startDrumRepeat(voice, dir) } else { stopDrumRepeat() }
                return
            }
        case .beat:
            if !heldPads.isEmpty {
                if dir == .up || dir == .down { stepVariation(dir == .up ? 1 : -1) }
                return
            }
        case .trainer:
            if let pad = heldPads.last {
                if let dir { answerStick = dir }
                if sounding[pad] != nil, !trainer.level.isInterval { voiceTrainerPad(pad) }
                return
            }
            if openMenu == nil { return }
        case .game:
            if game == nil, heldPads.isEmpty, openMenu == nil {
                if let dir { gameStick(dir) }
                return
            }
        case .tuner, .mic:
            if openMenu == nil { return }
        default:
            break
        }
        if let pad = heldPads.last, sounding[pad] != nil {
            if !stickConsumed { sound(pad) }
            return
        }
        if let dir, dir.isCardinal, openMenu != nil {
            navigate(dir)
            return
        }
        if state.mode == .seq, openMenu == nil {
            seqStick(dir)
        } else if openMenu == nil, heldPads.isEmpty, let dir {
            looperNavigate(dir)
        }
    }

    // MARK: - Drums & Beat

    /// Drums mode stick directions → repeat rate (SYNTH_SPEC §4).
    public static func drumRepeatRate(_ d: StickDirection) -> (beats: Double, swing: Double) {
        switch d {
        case .up: (1, 0.5)
        case .right: (0.5, 0.5)
        case .down: (0.25, 0.5)
        case .left: (0.125, 0.5)
        case .upRight: (0.5, 0.62)
        case .downRight: (0.25, 0.62)
        case .downLeft: (1.0 / 6, 0.5)
        case .upLeft: (1.0 / 3, 0.5)
        }
    }

    private func startDrumRepeat(_ voice: DrumVoice, _ dir: StickDirection) {
        if let old = drumRepeatVoice, old != voice { send(.drumRepeat(old, beats: 0, swing: 0.5)) }
        let r = Self.drumRepeatRate(dir)
        drumRepeatVoice = voice
        send(.drumRepeat(voice, beats: r.beats, swing: r.swing))
    }

    private func stopDrumRepeat() {
        guard let v = drumRepeatVoice else { return }
        drumRepeatVoice = nil
        send(.drumRepeat(v, beats: 0, swing: 0.5))
    }

    /// Beat mode: a pad starts its style, switches to it, or stops it if it's playing.
    private func beatPad(_ pad: Int) {
        guard let style = BeatStyle(rawValue: pad - 1) else { return }
        if beatPlaying, state.beatStyle == style {
            beatPlaying = false
            send(.beat(nil, playing: false))
            lastChordName = "STOP"
            return
        }
        mutate { $0.beatStyle = style }
        beatPlaying = true
        send(.beat(.make(style, state.beatVariation), playing: true))
        lastChordName = style.label
        showToast("\(style.label) · \(state.beatVariation.label)")
    }

    private func stepVariation(_ step: Int) {
        let all = BeatVariation.allCases
        let i = wrap(all.firstIndex(of: state.beatVariation)! + step, all.count)
        mutate { $0.beatVariation = all[i] }
        if beatPlaying { send(.beat(.make(state.beatStyle, state.beatVariation), playing: true)) }
        showToast("\(state.beatStyle.label) · \(state.beatVariation.label)")
    }

    // MARK: - Seq mode (chord sequencer)

    /// Seq mode stick: a push that ends without a pad press moves the cursor.
    /// → next step (adds one past the end), ← back, ↓ next page, ↑ previous page
    /// (on page 1: cycle the step rate).
    private func seqStick(_ dir: StickDirection?) {
        if let dir {
            if seqPush == nil { pushUsed = false }
            seqPush = dir
            return
        }
        guard let push = seqPush else { return }
        seqPush = nil
        guard !pushUsed, !seqPlaying else { return }
        let len = state.chordSequence.length
        let page = ChordSequence.pageSize
        switch push {
        case .right:
            if seqCursor < len - 1 {
                seqCursor += 1
            } else if len < ChordSequence.maxSteps {
                mutate { $0.chordSequence.steps.append(nil) }
                seqCursor = len
            }
        case .left:
            seqCursor = max(0, seqCursor - 1)
        case .down:
            seqCursor = min(len - 1, seqCursor + page)
        case .up:
            if seqCursor < page {
                mutate { $0.seqRate = next($0.seqRate, in: RhythmRate.seqRates) }
                showToast("STEP \(state.seqRate.label)")
            } else {
                seqCursor -= page
            }
        default:
            break
        }
    }

    private func seqClick() {
        if stick == .up {
            // Click with ↑ held trims empty steps from the end.
            pushUsed = true
            mutate { $0.chordSequence.trimEmptyTail() }
            seqCursor = min(seqCursor, state.chordSequence.length - 1)
            showToast("TRIM \(state.chordSequence.length) STEPS")
            return
        }
        seqPlaying.toggle()
        if !seqPlaying { seqPlayhead = nil }
        send(.chordSequencePlaying(seqPlaying, length: state.chordSequence.length))
        showToast(seqPlaying ? "SEQ PLAY" : "SEQ STOP")
    }

    // MARK: - Menu keys

    private func menuDown(_ k: MenuKey) {
        heldMenus.insert(k)
        comboUsed.remove(k)
        if dialog != nil { return }

        if let pad = heldPads.last {        // pad held first → per-pad combos
            comboUsed.insert(k)
            padThenMenu(pad, k)
            return
        }
        if heldMenus.isSuperset(of: [.key, .sound]) {
            comboUsed.formUnion([.key, .sound])
            openMenu = .presets(slot: 0)
            menuOpenedBy = nil
            return
        }
        if k == .mode, registerTap() { return }
        toggleMenu(k)
    }

    private func menuUp(_ k: MenuKey) {
        heldMenus.remove(k)
        if comboUsed.contains(k), menuOpenedBy == k { openMenu = nil }
        if menuOpenedBy == k { menuOpenedBy = nil }
        comboUsed.remove(k)
    }

    private func toggleMenu(_ k: MenuKey) {
        if let menu = openMenu, menu.owner == k {
            if case .mode(let h) = menu { activateMode(at: h) }
            openMenu = nil
            menuOpenedBy = nil
            return
        }
        switch k {
        case .key: openMenu = .key
        case .sound: openMenu = .sound
        case .mode: openMenu = .mode(highlight: availableModes.firstIndex(of: state.mode) ?? 0)
        }
        menuOpenedBy = k
    }

    /// Three quick taps of M set the tempo. Returns true when the tap set a tempo.
    private func registerTap() -> Bool {
        if let last = tapTimes.last, now - last > Self.tapWindow { tapTimes.removeAll() }
        tapTimes.append(now)
        guard tapTimes.count >= 3 else { return false }
        let recent = tapTimes.suffix(4)
        let span = recent.last! - recent.first!
        let bpm = (60 * Double(recent.count - 1) / span).rounded()
        mutate { $0.bpm = min(300, max(40, bpm)) }
        tapTimes.removeAll()
        openMenu = nil
        showToast("TAP \(Int(state.bpm)) BPM")
        return true
    }

    /// Pad held, then a menu key: octave / inversion / chord lock.
    private func padThenMenu(_ pad: Int, _ k: MenuKey) {
        let i = pad - 1
        if state.mode == .mixer {
            if k == .sound, pad <= LooperState.trackCount { toggleSolo(pad - 1) }
            mixerComboPads.insert(pad)
            return
        }
        switch k {
        case .sound:
            if stick != nil, !stickConsumed {
                toggleLock(pad)
            } else if state.voiceLeading {
                showToast("VLEAD AUTO")
            } else {
                mutate { $0.padInversion[i] = $0.padInversion[i].next }
                showToast(state.padInversion[i].label)
            }
        case .key:
            mutate { $0.padOctave[i] = max(-2, $0.padOctave[i] - 1) }
            showToast("PAD \(pad) OCT \(signed(state.padOctave[i]))")
        case .mode:
            mutate { $0.padOctave[i] = min(2, $0.padOctave[i] + 1) }
            showToast("PAD \(pad) OCT \(signed(state.padOctave[i]))")
        }
    }

    private func toggleLock(_ pad: Int) {
        if state.locks[pad] != nil {
            mutate { $0.locks[pad] = nil }
            showToast("UNLOCKED")
        } else {
            let m = ChordResolver.modifiedChord(pad: pad, state: state, stick: stick)
            let lock = ChordLock(chord: m.chord, rootNote: m.rootNote,
                                 legacyNinthVoicing: m.legacy, spelling: m.spelling)
            stickConsumed = true
            mutate { $0.locks[pad] = lock }
            showToast("LOCKED \(m.chord.name(spelling: m.spelling))")
        }
        stickConsumed = true
        if sounding[pad] != nil { sound(pad) }
    }

    /// Menu key held, then a pad: quick sound / quick mode / arp pattern.
    private func menuThenPad(_ pad: Int) {
        guard heldMenus.count == 1, let k = heldMenus.first else { return }
        comboUsed.insert(k)
        switch k {
        case .sound:
            if state.mode == .drums || state.mode == .beat {
                mutate { $0.drumKit = pad }
                showToast("KIT \(pad)")
            } else if let index = SoundCatalog.quickSelect(pad: pad) {
                mutate { $0.selectSound(index) }
                showToast(state.sound.name.uppercased())
            }
        case .mode:
            if let m = SynthMode.quickSelect(pad: pad) { setMode(m) }
        case .key:
            guard state.mode == .arp else { return }
            if pad <= ArpPattern.allCases.count {
                mutate { $0.arpPattern = ArpPattern.allCases[pad - 1] }
                showToast("ARP \(state.arpPattern.label)")
            } else if pad == 7 {
                mutate { $0.arpLayer = next($0.arpLayer) }
                showToast(state.arpLayer.label)
            }
        }
    }

    // MARK: - Click & wheel

    private func clickDown() {
        if heldMenus.count == 1, let k = heldMenus.first {
            comboUsed.insert(k)
            randomize(k)
            return
        }
        if dialog != nil { return }
        if let menu = openMenu {
            if case .mode(let h) = menu { activateMode(at: h) }
            openMenu = nil
            menuOpenedBy = nil
            return
        }
        switch state.mode {
        case .seq: seqClick()
        case .mixer: setLoopsPaused(!looper.paused)
        case .trainer: trainerClick()
        case .game: gameClick()
        case .tuner, .mic: break
        default: looperClick()
        }
    }

    private func wheel(_ delta: Double) {
        if state.mode == .mixer, let pad = heldPads.last {
            mixerComboPads.insert(pad)
            if pad <= LooperState.trackCount {
                let i = pad - 1
                looper.tracks[i].level = min(1.5, max(0, looper.tracks[i].level + delta))
                sendGains()
                showToast("TRACK \(pad) \(Int((looper.tracks[i].level * 100).rounded()))")
            } else {
                mutate { $0.metronomeLevel = min(1, max(0, $0.metronomeLevel + delta)) }
                showToast("CLICK \(Int((state.metronomeLevel * 100).rounded()))")
            }
            return
        }
        if heldMenus.count == 1, let k = heldMenus.first {
            comboUsed.insert(k)
            switch k {
            case .key:
                let a = logStep(state.envelope.attackMs, 0.1, 5000, delta)
                mutate { $0.attackOverrideMs = a }
                showToast("ATTACK \(ms(a))")
            case .sound:
                let r = logStep(state.envelope.releaseMs, 0.1, 5000, delta)
                mutate { $0.releaseOverrideMs = r }
                showToast("RELEASE \(ms(r))")
            case .mode:
                let c = logStep(state.filterCutoffHz, 20, 20_000, delta)
                mutate { $0.filterCutoffHz = c }
                showToast("CUTOFF \(Int(c)) Hz")
            }
            return
        }
        mutate { $0.volume = min(1, max(0, $0.volume + delta)) }
        showToast("VOL \(Int((state.volume * 100).rounded()))")
    }

    // MARK: - Menu navigation

    public var availableModes: [SynthMode] {
        SynthMode.allCases.filter { $0 != .mixer || looperHasAudio }
    }

    private func navigate(_ dir: StickDirection) {
        guard let menu = openMenu else { return }
        let step = dir == .right ? 1 : dir == .left ? -1 : 0
        switch menu {
        case .key:
            if step != 0 { mutate { $0.key = $0.key.transposed(by: step) } }
            if dir == .up { mutate { $0.globalOctave = min(2, $0.globalOctave + 1) } }
            if dir == .down { mutate { $0.globalOctave = max(-2, $0.globalOctave - 1) } }
        case .sound:
            if step != 0 {
                let n = SoundCatalog.builtIn.count
                let current = min(state.soundIndex, n - 1)
                mutate { $0.selectSound(wrap(current + step, n)) }
            } else if dir == .up {
                openMenu = .settings(row: 0)
            }
        case .settings(let row):
            let rows = SettingRow.allCases
            if step != 0 { openMenu = .settings(row: wrap(row + step, rows.count)) }
            if dir == .up { mutate { rows[row].cycle(in: &$0) } }
            if dir == .down { openMenu = .sound }
        case .mode(let h):
            let modes = availableModes
            if step != 0 {
                let nh = wrap(h + step, modes.count)
                openMenu = .mode(highlight: nh)
                if !modes[nh].needsConfirm { setMode(modes[nh]) }
            }
            if dir == .down { cyclePrimaryParam() }
            if dir == .up { openMenu = .bpm }
        case .bpm:
            let delta: Double = switch dir {
            case .right: 1
            case .left: -1
            case .up: 10
            default: -10
            }
            mutate { $0.bpm = min(300, max(40, $0.bpm + delta)) }
        case .presets(let slot):
            if step != 0 { openMenu = .presets(slot: wrap(slot + step, presets.count)) }
            if dir == .up { dialog = .save(slot: slot) }
            if dir == .down {
                if presets[slot] != nil { dialog = .load(slot: slot) } else { showToast("EMPTY") }
            }
        }
    }

    private func activateMode(at highlight: Int) {
        let modes = availableModes
        guard modes.indices.contains(highlight) else { return }
        if modes[highlight] != state.mode { setMode(modes[highlight]) }
    }

    private func setMode(_ m: SynthMode) {
        if m == .mixer, !looperHasAudio { return }
        mutate { $0.mode = m }
        showToast(m.label)
    }

    private func cyclePrimaryParam() {
        switch state.mode {
        case .strum:
            mutate { $0.strumSpeed = next($0.strumSpeed) }
            showToast("STRUM \(state.strumSpeed.label)")
        case .arp:
            mutate { $0.arpRate = next($0.arpRate, in: RhythmRate.arpRates) }
            showToast("RATE \(state.arpRate.label)")
        case .repeat:
            mutate { $0.repeatRate = next($0.repeatRate) }
            showToast("RATE \(state.repeatRate.label)")
        case .seq:
            mutate { $0.seqRate = next($0.seqRate, in: RhythmRate.seqRates) }
            showToast("STEP \(state.seqRate.label)")
        case .beat:
            stepVariation(1)
        case .trainer:
            let all = TrainerLevel.allCases
            mutate { $0.trainerLevel = all[$0.trainerLevel.rawValue % all.count] }
            showToast("LV \(state.trainerLevel.rawValue) \(state.trainerLevel.label)")
        case .game:
            gameSpeed = gameSpeed <= 0.55 ? 1 : ((gameSpeed - 0.1) * 10).rounded() / 10
            showToast("SPEED \(Int((gameSpeed * 100).rounded()))%")
        default:
            break
        }
    }

    private func confirm(_ d: Dialog) {
        dialog = nil
        switch d {
        case .save(let slot):
            guard !looper.isRecording else { return showToast("NOT WHILE RECORDING") }
            presets[slot] = state
            onSessionChange(session)
            showToast("SAVED P\(slot + 1)")
        case .load(let slot):
            guard var p = presets[slot] else { return }
            p.volume = state.volume    // device-level settings are not part of a preset
            p.midiIn = state.midiIn
            p.micSampleRoot = state.micSampleRoot // the take on disk is the latest one
            if p.soundIndex == SoundCatalog.micSampleIndex, p.micSampleRoot == nil { p.selectSound(0) }
            mutate { $0 = p }
            showToast("LOADED P\(slot + 1)")
        }
    }

    // MARK: - Randomize (menu held + click)

    private func randomize(_ k: MenuKey) {
        if k != .mode, looper.isRecording { return showToast("NOT WHILE RECORDING") }
        switch k {
        case .sound:
            mutate { randomizeSound(&$0) }
            showToast("RANDOMIZED SOUND")
        case .key:
            mutate { s in
                randomizeSound(&s)
                s.key = Key(Int.random(in: 0..<12, using: &rng))
                if !looperHasAudio { s.bpm = Double(Int.random(in: 70...140, using: &rng)) }
            }
            showToast("RANDOMIZED ALL")
        case .mode:
            mutate { s in
                s.arpPattern = ArpPattern.allCases.randomElement(using: &rng)!
                s.arpRate = RhythmRate.arpRates.randomElement(using: &rng)!
                s.strumSpeed = StrumSpeed.allCases.randomElement(using: &rng)!
                for i in 0..<7 { s.padInversion[i] = Inversion.allCases.randomElement(using: &rng)! }
                // A 4-step progression that starts on the tonic.
                var seq = ChordSequence()
                let pads = [1] + (0..<3).map { _ in Int.random(in: 2...6, using: &rng) }
                seq.steps = pads.map { ChordResolver.voicing(pad: $0, state: s, stick: nil) }
                s.chordSequence = seq
            }
            showToast("RANDOMIZED PATTERN")
        }
    }

    private func randomizeSound(_ s: inout SynthState) {
        let pool = SoundCatalog.builtIn.count + 1 // + hidden Wind
        let pick = Int.random(in: 0..<pool, using: &rng)
        s.selectSound(pick == SoundCatalog.builtIn.count ? SoundCatalog.windIndex : pick)
        for kind in [FXKind.reverb, .delay, .chorus, .flanger, .drive, .tape, .tremolo, .lfo] {
            let on = Double.random(in: 0..<1, using: &rng) < 0.3
            s.fx[kind] = on ? Int.random(in: 1..<kind.options.count, using: &rng) : nil
        }
    }

    // MARK: - Tools: shared

    /// Engine commands due later (Trainer playback). Fired from `tick`, so ~30 ms granular.
    private func schedule(_ c: EngineCommand, at t: Double) {
        scheduled.append((t, c))
        scheduled.sort { $0.at < $1.at }
    }

    private func fireScheduled(upTo time: Double) {
        while let first = scheduled.first, first.at <= time {
            scheduled.removeFirst()
            send(first.command)
        }
    }

    private func clearScheduled() {
        guard !scheduled.isEmpty else { return }
        scheduled.removeAll()
        send(.chord(slot: 0, voicing: nil))
    }

    /// Mode change away from (or into) a tool: stop what it was doing.
    private func leaveTool(_ old: SynthMode) {
        clearScheduled()
        trainerReveal = nil
        answerStick = nil
        nextQuestionAt = state.mode == .trainer ? now + 0.6 : nil
        if old == .trainer { trainer.setLevel(state.trainerLevel) } // drops the open question
        if micRecording {
            micRecording = false
            micStartedAt = nil
            onMicRecord(false)
        }
        gameResult = nil
        if old == .tuner { tuner = nil }
    }

    /// A short message from the app (e.g. "MIC ACCESS OFF").
    public func notify(_ text: String) { showToast(text) }

    // MARK: - Tuner

    public func setTunerReading(_ r: TunerReading?) {
        if r != tuner { tuner = r }
    }

    // MARK: - Mic mode

    private func startMic() {
        guard !micRecording else { return }
        micRecording = true
        micStartedAt = now
        lastChordName = "● REC"
        onMicRecord(true)
    }

    private func stopMic() {
        guard micRecording else { return }
        micRecording = false
        micStartedAt = nil
        lastChordName = "…"
        onMicRecord(false)
    }

    /// The app finished a Mic-mode take (`root` = detected pitch, nil = none): it plays as
    /// the Mic Sample sound in Lead mode.
    public func micSampleReady(root: Double?) {
        let r = root ?? 60
        mutate { s in
            s.micSampleRoot = r
            s.selectSound(SoundCatalog.micSampleIndex)
            s.mode = .lead
        }
        lastChordName = PitchName.noteName(Int(r.rounded()))
        showToast(root == nil ? "NO PITCH: PLAYS AS C" : "MIC SAMPLE → LEAD")
    }

    /// The take on disk is gone: drop the sound.
    public func forgetMicSample() {
        mutate { s in
            s.micSampleRoot = nil
            if s.soundIndex == SoundCatalog.micSampleIndex { s.selectSound(0) }
        }
    }

    public func micFailed(_ message: String) {
        micRecording = false
        micStartedAt = nil
        lastChordName = "MIC"
        showToast(message)
    }

    // MARK: - Trainer mode

    private func askQuestion() {
        trainerReveal = nil
        trainer.next(state: state)
        playQuestion()
    }

    /// Plays the open question on slot 0 (pads 1–7 stay free for answering).
    private func playQuestion() {
        guard let q = trainer.question else { return }
        play(q.playback, step: q.level.isInterval ? 0.8 : q.level.answerCount > 1 ? 1.0 : 1.2)
    }

    private func play(_ voicings: [Voicing], step: Double, after delay: Double = 0.1) {
        clearScheduled()
        var t = now + delay
        for v in voicings {
            schedule(.chord(slot: 0, voicing: v), at: t)
            schedule(.chord(slot: 0, voicing: nil), at: t + step * 0.8)
            t += step
        }
    }

    private func trainerPadDown(_ pad: Int) {
        answerStick = stick
        voiceTrainerPad(pad)
        if !trainer.level.usesStick { submit(TrainerAnswer(pad: pad)) }
    }

    private func trainerPadUp(_ pad: Int) {
        release(pad)
        if trainer.level.usesStick { submit(TrainerAnswer(pad: pad, stick: answerStick)) }
        answerStick = nil
    }

    private func voiceTrainerPad(_ pad: Int) {
        let a = TrainerAnswer(pad: pad, stick: trainer.level.isInterval ? nil : stick)
        let v = EarTrainer.answerVoicing(a, level: trainer.level, state: state)
        sounding[pad] = v
        send(.chord(slot: pad, voicing: v))
    }

    private func submit(_ a: TrainerAnswer) {
        guard let q = trainer.question else { return }
        switch trainer.answer(a, state: state) {
        case .right?:
            trainerReveal = EarTrainer.names(q, state: state)
            showToast("✓ RIGHT")
            nextQuestionAt = now + 1.4
        case .wrong?:
            trainerReveal = EarTrainer.names(q, state: state)
            showToast("✗ WRONG")
            // Play the right answer, then move on.
            let answers = q.answers.map { EarTrainer.answerVoicing($0, level: q.level, state: state) }
            let notes = q.targetNote.map { [EarTrainer.noteVoicing($0)] } ?? answers
            play(notes, step: 0.9, after: 0.5)
            nextQuestionAt = now + 0.5 + 0.9 * Double(notes.count) + 0.8
        case .partial?, nil:
            break
        }
    }

    /// Click: hear the question again (or skip to a new one after an answer).
    private func trainerClick() {
        if trainer.question != nil {
            playQuestion()
        } else {
            nextQuestionAt = nil
            askQuestion()
        }
    }

    // MARK: - Game mode

    /// Idle stick: ←/→ song, ↑/↓ practice speed (50–100 %).
    private func gameStick(_ dir: StickDirection) {
        let n = GameSongs.all.count
        switch dir {
        case .right: gameSong = (gameSong + 1) % n
        case .left: gameSong = (gameSong + n - 1) % n
        case .up: gameSpeed = min(1, ((gameSpeed + 0.1) * 10).rounded() / 10)
        case .down: gameSpeed = max(0.5, ((gameSpeed - 0.1) * 10).rounded() / 10)
        default: return
        }
        gameResult = nil
    }

    private func gameClick() {
        if game != nil { endGame(completed: false) } else { startGame() }
    }

    /// The drums start right away; the chart's beat 0 is when they're heard.
    private func startGame() {
        let song = GameSongs.all[gameSong]
        let run = GameRun(song: song, speed: gameSpeed, startTime: now + outputLatency)
        game = run
        gameResult = nil
        send(.tempo(run.bpm))
        send(.beat(.make(song.style, .original), playing: true))
    }

    private func advanceGame(_ t: Double) {
        guard var g = game else { return }
        if g.expire(at: t) > 0 { game = g }
        if g.isFinished(at: t) { endGame(completed: true) }
    }

    private func endGame(completed: Bool) {
        guard let g = game else { return }
        game = nil
        send(.beat(nil, playing: false))
        send(.tempo(state.bpm))
        guard completed else { return showToast("STOPPED") }
        gameResult = g
        if g.speed >= 0.999, g.accuracy > gameBest[g.song.name] ?? -1 {
            gameBest[g.song.name] = g.accuracy
            onSessionChange(session)
        }
        showToast("\(g.grade) · \(g.accuracy)%")
    }

    /// The scrolling chart at `time` (same clock as the events), while a song runs.
    public func gameLane(at time: Double) -> GameLane? { game?.lane(at: time) }

    // MARK: - State plumbing

    /// Applies a state change, emits engine commands for it, and re-voices held chords
    /// if anything harmonic changed.
    private func mutate(_ body: (inout SynthState) -> Void) {
        let old = state
        body(&state)
        guard old != state else { return }
        if old.mode != state.mode {
            sounding.removeAll()
            droneSlot = nil
            slashBassPad = nil
            lastVoicedNotes = nil
            beatPlaying = false   // the engine's all-notes-off stops the players
            seqPlaying = false
            seqPlayhead = nil
            seqPush = nil
            drumRepeatVoice = nil
            leaveTool(old.mode)
        }
        if old.trainerLevel != state.trainerLevel {
            trainer.setLevel(state.trainerLevel)
            trainerReveal = nil
            clearScheduled()
            if state.mode == .trainer { nextQuestionAt = now + 0.6 }
        }
        let endedGame = old.mode != state.mode && game != nil
        if endedGame { game = nil }
        for c in EngineCommand.diff(from: old, to: state) { send(c) }
        if endedGame, old.bpm == state.bpm { send(.tempo(state.bpm)) } // the game ran at its own tempo
        if Self.harmonyChanged(old, state) {
            for pad in sounding.keys.sorted() { sound(pad) }
        }
        onSessionChange(session)
    }

    // MARK: - Looper (SYNTH_SPEC §5)

    /// Stick with nothing held and no menu: ←/→ pick a track, ↓ the looper transport,
    /// ↑ back to the tracks.
    private func looperNavigate(_ dir: StickDirection) {
        let n = LooperState.trackCount
        switch dir {
        case .right where looper.cursor < n: looper.cursor = (looper.cursor + 1) % n
        case .left where looper.cursor < n: looper.cursor = (looper.cursor + n - 1) % n
        case .down: looper.cursor = LooperState.transport
        case .up where looper.cursor == LooperState.transport: looper.cursor = 0
        default: return
        }
    }

    private func looperClick() {
        clickDownAt = now
        clickConsumed = false
        clickTarget = looper.cursor
        guard looper.cursor < LooperState.trackCount else { return } // transport acts on release
        let i = looper.cursor
        switch looper.tracks[i].state {
        case .off:
            if looper.hasLoop {
                bump(i, to: .waiting)
                send(.looperArm(track: i, generation: looper.tracks[i].generation))
            } else if looper.firstTake == nil, looper.freeArmed == nil {
                beginFirstTake(i)
            }
        case .waiting:
            cancel(i)   // a click while waiting cancels
        case .record:
            if looper.firstTake == i, state.loopBars == 0 {
                looper.tracks[i].generation += 1   // free take: this click sets the length
                send(.looperStopFirst(generation: looper.tracks[i].generation))
            }
        case .play:
            break       // hold to clear (see clickHeldLong)
        }
    }

    private func clickUp() {
        defer { clickDownAt = nil }
        guard let t0 = clickDownAt, !clickConsumed else { return }
        if clickTarget == LooperState.transport, now - t0 < Self.clearHold, looper.hasLoop {
            setLoopsPaused(!looper.paused)
        }
    }

    private func clickHeldLong() {
        clickConsumed = true
        if clickTarget == LooperState.transport {
            clearAllLoops()
        } else if clickTarget < LooperState.trackCount, looper.tracks[clickTarget].state == .play {
            cancel(clickTarget)
            showToast("TRACK \(clickTarget + 1) CLEARED")
            if !looper.hasAudio { clearAllLoops() }
        }
    }

    private func beginFirstTake(_ i: Int) {
        looper.firstTake = i
        if state.loopBars == 0 {
            // Free: arm now, start on the first chord.
            bump(i, to: .waiting)
            looper.freeArmed = i
            showToast("LOOP: PLAY TO START")
        } else {
            bump(i, to: .waiting)
            send(.looperRecordFirst(track: i, bars: state.loopBars, countInBeats: Self.countInBeats,
                                    generation: looper.tracks[i].generation))
        }
    }

    private func startFreeTake(_ i: Int) {
        looper.freeArmed = nil
        looper.tracks[i].state = .record
        send(.looperRecordFirst(track: i, bars: nil, countInBeats: 0, generation: looper.tracks[i].generation))
    }

    private func cancel(_ i: Int) {
        if looper.freeArmed == i { looper.freeArmed = nil }
        if looper.firstTake == i { looper.firstTake = nil }
        bump(i, to: .off)
        send(.looperClear(track: i, generation: looper.tracks[i].generation))
    }

    private func clearAllLoops() {
        for i in 0..<LooperState.trackCount where looper.tracks[i].state != .off || looper.freeArmed == i {
            cancel(i)
        }
        for i in 0..<LooperState.trackCount { looper.tracks[i].muted = false; looper.tracks[i].solo = false; looper.tracks[i].level = 1 }
        sendGains()
        looper.hasLoop = false
        looper.paused = false
        looper.cursor = 0
        if state.mode == .mixer { setMode(.play) }
        showToast("LOOPER CLEARED")
    }

    private func bump(_ i: Int, to s: LoopTrackState) {
        looper.tracks[i].generation += 1
        looper.tracks[i].state = s
    }

    private func setLoopsPaused(_ on: Bool) {
        guard looper.hasLoop else { return }
        looper.paused = on
        send(.looperPause(on))
        showToast(on ? "LOOPS PAUSED" : "LOOPS PLAY")
    }

    private func sendGains() {
        for i in 0..<LooperState.trackCount { send(.looperGain(track: i, gain: looper.gain(i))) }
    }

    // Mixer mode: tap pad 1–6 = mute, hold + S = solo, hold + wheel = level;
    // tap pad 7 = metronome, hold 7 + wheel = its level.
    private func mixerPad(_ pad: Int) {
        if pad == 7 {
            mutate { $0.metronome.toggle() }
            showToast(state.metronome ? "CLICK ON" : "CLICK OFF")
            return
        }
        let i = pad - 1
        guard i < LooperState.trackCount else { return }
        looper.tracks[i].muted.toggle()
        sendGains()
        showToast("TRACK \(pad) " + (looper.tracks[i].muted ? "MUTED" : "ON"))
    }

    private func toggleSolo(_ i: Int) {
        looper.tracks[i].solo.toggle()
        sendGains()
        showToast("TRACK \(i + 1) " + (looper.tracks[i].solo ? "SOLO" : "UNSOLO"))
    }

    /// Engine telemetry (~30×/s): track states, loop length, playhead.
    public func updateLooper(_ reports: [LoopTrackReport], length: Int, position: Double) {
        var l = looper
        for (i, r) in reports.prefix(LooperState.trackCount).enumerated() where r.generation == l.tracks[i].generation {
            let old = l.tracks[i].state
            guard old != r.state else { continue }
            // The engine can't know about a free take that waits for the first chord.
            if l.freeArmed == i, r.state == .off { continue }
            l.tracks[i].state = r.state
            if r.state == .play, old == .record || old == .waiting {
                if l.firstTake == i { l.firstTake = nil }
                if l.cursor == i, let next = l.nextEmpty(after: i) { l.cursor = next } // auto-advance
            }
        }
        l.hasLoop = length > 0
        l.position = (position * 50).rounded() / 50 // 2 % steps: enough for drawing
        if l != looper { looper = l }
        if state.mode == .mixer, !looper.hasAudio { setMode(.play) }
    }

    /// The track to send to the sampler, if it has audio.
    public func loopIsPlayable(_ track: Int) -> Bool {
        looper.tracks.indices.contains(track) && looper.tracks[track].state == .play
    }

    private static func harmonyChanged(_ a: SynthState, _ b: SynthState) -> Bool {
        a.key != b.key || a.scale != b.scale || a.globalOctave != b.globalOctave
            || a.padOctave != b.padOctave || a.padInversion != b.padInversion
            || a.locks != b.locks || a.stickMode != b.stickMode || a.voiceCount != b.voiceCount
            || a.bassMode != b.bassMode || a.voiceLeading != b.voiceLeading
    }

    private func showToast(_ text: String) {
        toast = Toast(text: text, until: now + Self.toastDuration)
    }

    // MARK: - Display

    /// Chord label for a pad at rest (for drawing the pads).
    public func padLabel(_ pad: Int) -> String {
        switch state.mode {
        case .drums: DrumVoice.forPad(pad)?.label ?? ""
        case .beat: BeatStyle(rawValue: pad - 1)?.label ?? ""
        default: ChordResolver.voicing(pad: pad, state: state, stick: nil).name
        }
    }

    public var isMenuHeld: Set<MenuKey> { heldMenus }

    public var display: DisplayModel {
        DisplayModel(
            status: "\(state.key.name) \(state.scale.displayName) · \(state.stickMode.shortName) · \(state.mode.label)",
            bpm: Int(state.bpm),
            chordName: toolChordName ?? lastChordName,
            menu: menuDisplay,
            dialog: dialog.map { "\($0.text)   ↑ YES · ↓ NO" },
            toast: toast?.text,
            detail: modeDetail,
            steps: state.mode == .seq ? seqCells : state.mode == .trainer ? trainerCells : nil,
            looper: state.mode.isTool ? nil : looperDisplay,
            tool: toolScreen
        )
    }

    private var toolChordName: String? {
        switch state.mode {
        case .trainer:
            if let r = trainerReveal { return r.joined(separator: " → ") }
            return trainer.question == nil ? "…" : "?"
        case .mic:
            return micRecording ? "● REC" : nil
        default:
            return nil
        }
    }

    private var toolScreen: ToolScreen? {
        switch state.mode {
        case .tuner:
            return .tuner(tuner)
        case .game:
            let song = GameSongs.all[gameSong]
            let result = gameResult.map {
                "\($0.grade) · \($0.accuracy)% · \($0.count(.perfect)) PERFECT · \($0.count(.good)) GOOD · "
                    + "\($0.count(.miss)) MISS · MAX COMBO \($0.maxCombo)"
            }
            return .game(GameScreen(running: game != nil, song: song.name, tier: song.tier,
                                    bpm: Int((song.bpm * gameSpeed).rounded()),
                                    speedPercent: Int((gameSpeed * 100).rounded()),
                                    best: gameBest[song.name], result: result))
        default:
            return nil
        }
    }

    /// Progression levels: one cell per chord to answer.
    private var trainerCells: [StepCell]? {
        let level = trainer.level
        guard level.answerCount > 1 else { return nil }
        let given = trainer.question == nil ? [] : trainer.given
        return (0..<level.answerCount).map { i in
            let label: String
            if let r = trainerReveal, i < r.count {
                label = r[i]
            } else if i < given.count {
                label = EarTrainer.answerVoicing(given[i], level: level, state: state).name
            } else {
                label = "?"
            }
            return StepCell(index: i, label: label, isCursor: trainer.question != nil && i == given.count, isPlaying: false)
        }
    }

    private var looperDisplay: LooperDisplay {
        LooperDisplay(
            cells: looper.tracks.enumerated().map { i, t in
                LoopCell(index: i, state: t.state, muted: t.muted || looper.gain(i) == 0 && t.state == .play,
                         solo: t.solo, isCursor: looper.cursor == i)
            },
            transportSelected: looper.cursor == LooperState.transport,
            position: looper.hasLoop ? looper.position : nil,
            paused: looper.paused,
            lengthText: state.loopBars == 0 ? "FREE" : "\(state.loopBars) BAR" + (state.loopBars == 1 ? "" : "S"))
    }

    private var modeDetail: String? {
        switch state.mode {
        case .drums:
            return "KIT \(state.drumKit) · \(DrumKitCatalog.names[state.drumKit - 1])"
        case .beat:
            return "\(state.beatStyle.label) · \(state.beatVariation.label) · KIT \(state.drumKit) "
                + (beatPlaying ? "▶" : "■")
        case .seq:
            let len = state.chordSequence.length
            return "STEP \(min(seqCursor, len - 1) + 1)/\(len) · \(state.seqRate.label) " + (seqPlaying ? "▶" : "■")
        case .arp:
            return "\(state.arpPattern.label) · \(state.arpRate.label) · \(state.arpLayer.label)"
        case .repeat:
            return "RATE \(state.repeatRate.label)"
        case .strum:
            return "STRUM \(state.strumSpeed.label)"
        case .mixer:
            return "PAD 1–6 MUTE · +S SOLO · +WHEEL LEVEL · 7 CLICK " + (state.metronome ? "ON" : "OFF")
        case .trainer:
            let t = trainer
            return "LV\(t.level.rawValue) \(t.level.label) · \(t.correct)/\(t.asked) · STREAK \(t.streak) · CLICK REPLAY"
                + (t.level.usesStick ? " · PAD+STICK, RELEASE" : "")
        case .mic:
            if micRecording { return "RECORDING · RELEASE PAD 1 (MAX 3 s)" }
            let root = state.micSampleRoot.map { " · LAST: " + PitchName.noteName(Int($0.rounded())) } ?? ""
            return "HOLD PAD 1 TO RECORD" + root
        case .tuner:
            return "PLAY OR SING A NOTE"
        default:
            return nil
        }
    }

    private var seqCells: [StepCell] {
        let seq = state.chordSequence
        let focus = seqPlaying ? (seqPlayhead ?? 0) : seqCursor
        let start = (min(focus, seq.length - 1) / ChordSequence.pageSize) * ChordSequence.pageSize
        return (start..<min(seq.length, start + ChordSequence.pageSize)).map { i in
            StepCell(index: i, label: seq.steps[i]?.name ?? "—",
                     isCursor: !seqPlaying && i == seqCursor, isPlaying: seqPlaying && i == seqPlayhead)
        }
    }

    private var menuDisplay: MenuDisplay? {
        guard let menu = openMenu else { return nil }
        switch menu {
        case .key:
            let names = (0..<12).map { Key($0).name }
            return MenuDisplay(title: "KEY", items: names, selected: state.key.tonic,
                               hint: "←→ key · ↑↓ octave \(signed(state.globalOctave))")
        case .sound:
            let names = SoundCatalog.builtIn.map(\.name)
            let sel = state.soundIndex < names.count ? state.soundIndex : nil
            return MenuDisplay(title: "SOUND", items: names, selected: sel,
                               hint: sel == nil ? state.sound.name : "↑ FX & settings")
        case .settings(let row):
            let r = SettingRow.allCases[row]
            return MenuDisplay(title: r.title, items: r.options, selected: r.value(in: state),
                               hint: "\(row + 1)/\(SettingRow.allCases.count) · ←→ row · ↑ change · ↓ back")
        case .mode(let h):
            let param: String = switch state.mode {
            case .strum: "↓ \(state.strumSpeed.label) · "
            case .arp: "↓ \(state.arpRate.label) · "
            case .repeat: "↓ \(state.repeatRate.label) · "
            case .trainer: "↓ LV\(state.trainerLevel.rawValue) · "
            case .game: "↓ SPEED \(Int((gameSpeed * 100).rounded()))% · "
            default: ""
            }
            return MenuDisplay(title: "MODE", items: availableModes.map(\.label), selected: h,
                               hint: param + "↑ tempo")
        case .bpm:
            return MenuDisplay(title: "TEMPO", items: [], selected: nil,
                               hint: "\(Int(state.bpm)) BPM · ←→ ±1 · ↑↓ ±10")
        case .presets(let slot):
            let items = presets.indices.map { "P\($0 + 1)" + (presets[$0] != nil ? "*" : "") }
            return MenuDisplay(title: "PRESETS", items: items, selected: slot,
                               hint: "↑ save · ↓ load")
        }
    }
}

// MARK: - Helpers

private func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

private func next<T: CaseIterable & Equatable>(_ v: T) -> T {
    let all = Array(T.allCases)
    return all[(all.firstIndex(of: v)! + 1) % all.count]
}

private func next<T: Equatable>(_ v: T, in all: [T]) -> T {
    all[((all.firstIndex(of: v) ?? -1) + 1) % all.count]
}

private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }

private func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : "\(Int(v)) ms" }

/// Moves `value` by `delta` (0...1 of the full range) on a logarithmic scale.
func logStep(_ value: Double, _ lo: Double, _ hi: Double, _ delta: Double) -> Double {
    let u = log(max(lo, min(hi, value)) / lo) / log(hi / lo)
    return lo * pow(hi / lo, min(1, max(0, u + delta)))
}

/// Small deterministic RNG so randomize is reproducible in tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
