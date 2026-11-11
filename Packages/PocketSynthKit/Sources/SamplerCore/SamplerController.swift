import Foundation
import Observation

/// What the sampler asks the audio engine to do.
public enum SamplerCommand: Equatable, Sendable {
    /// Pad settings changed (the bridge resolves sample IDs to loaded buffers).
    case pad(Int, Pad)
    case trigger(pad: Int, velocity: Int, tune: Double = 0)
    case release(pad: Int)
    case stopAll
    case mixer(SamplerMixer)
    /// The sequence to play (the engine swaps it in without stopping).
    case sequence(PadSequence)
    case transport(playing: Bool, startTick: Int, countInBeats: Int)
    case recording(Bool, guardTicks: Int)
    case metronome(Bool)
    case beatsPerBar(Int)
    /// Note repeat rate in beats (0 = off) and swing (0.5 … 0.75).
    case noteRepeat(beats: Double, swing: Double)
    /// Note repeat pad down / pressure (velocity > 0) or up (0).
    case repeatPad(pad: Int, velocity: Int, tune: Double)
    /// A keygroup program changed (the bridge resolves its samples).
    case keygroup(Int, KeygroupProgram)
    /// A live note on a note track's program (velocity 0 = off).
    case liveNote(TrackProgram, note: Int, velocity: Int)
    /// Plays `sequence` after the current one ends (or at the next bar). `loop` overrides
    /// the sequence's own loop flag (the last step of a song plays once).
    case queueSequence(PadSequence, atBar: Bool, loop: Bool?)
    /// XY performance FX only (sent at touch rate).
    case xy(XYSettings)
    /// The clip program changed (the bridge resolves its samples).
    case clips(ClipProgram, beatsPerBar: Int)
    /// A clip pad pressed (down) or let go.
    case clipPad(Int, down: Bool)
    case clipStopAll
}

/// How a touch on a pad becomes a velocity (SAMPLER_SPEC §2).
public enum VelocityMode: String, CaseIterable, Codable, Sendable {
    case position, touchSize, fixed

    public var label: String {
        switch self {
        case .position: "Position"
        case .touchSize: "Touch size"
        case .fixed: "Fixed"
        }
    }

    /// `y` is the touch height inside the pad (0 = top, 1 = bottom); `size` 0...1.
    public func velocity(y: Double, size: Double) -> Int {
        let v: Double = switch self {
        case .position: 1 - y
        case .touchSize: size
        case .fixed: 100.0 / 127.0
        }
        return max(1, min(127, Int((20 + 107 * min(1, max(0, v))).rounded())))
    }
}

public enum SamplerView: String, CaseIterable, Sendable {
    case main, grid, sample, edit, program, mixer, song

    public var label: String {
        switch self {
        case .main: "Main"
        case .grid: "Seq"
        case .sample: "Sample"
        case .edit: "Edit"
        case .program: "Program"
        case .mixer: "Mixer"
        case .song: "Song"
        }
    }
}

/// The sequence editors (SAMPLER_SPEC §6).
public enum SeqEditor: String, CaseIterable, Sendable {
    case grid, list, step
    public var label: String { ["Grid", "List", "Step"][Self.allCases.firstIndex(of: self)!] }
}

/// Sample Edit's two modes (SAMPLER_SPEC §5).
public enum EditMode: String, CaseIterable, Sendable {
    case trim, chop

    public var label: String { self == .trim ? "Trim" : "Chop" }
}

/// What Convert does with a chop (SAMPLER_SPEC §5.2).
public enum ChopConversion: String, CaseIterable, Sendable {
    /// Non-destructive: each pad plays its slice of the original sample.
    case pads
    /// One new sample file per slice, each on its own pad.
    case samples
    /// Slices on pads plus a sequence that replays them in their original timing.
    case sequence
    /// A keygroup that plays the whole phrase across the keyboard (root C3), on a new track.
    case phrase

    public var label: String {
        switch self {
        case .pads: "Slices → pads"
        case .samples: "Extract new samples"
        case .sequence: "Pads + sequence"
        case .phrase: "Patched phrase (keygroup)"
        }
    }
}

/// Note repeat rates (SAMPLER_SPEC §2).
public enum RepeatRate: String, CaseIterable, Codable, Sendable {
    case quarter, quarterTriplet, eighth, eighthTriplet, sixteenth, sixteenthTriplet, thirtySecond, thirtySecondTriplet

    public var beats: Double { [1, 2.0 / 3, 0.5, 1.0 / 3, 0.25, 1.0 / 6, 0.125, 1.0 / 12][index] }
    public var label: String { ["1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T"][index] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// 16 Levels: what the 16 pads step through for the source pad.
public enum LevelsParameter: String, CaseIterable, Sendable {
    case velocity, tune

    public var label: String { self == .velocity ? "Velocity" : "Tune" }
}

public enum RecordMode: String, CaseIterable, Sendable {
    case overdub, replace

    public var label: String { self == .overdub ? "Overdub" : "Replace" }
}

public struct TransportState: Equatable, Sendable {
    public var playing = false
    /// Set while a take is being recorded.
    public var recording: RecordMode?
    /// Bars of metronome before recording starts from stop (0, 1 or 2).
    public var countInBars = 1
    public var metronome = true
    // The playhead lives on the controller (`playhead`), not here: it changes every
    // frame, and views that only read `transport.playing` shouldn't redraw with it.
}

/// The sampler panel's brain: banks, pad hits, sample assignment, pad editing, the
/// sequencer (transport, recording, editing) and undo.
@MainActor
@Observable
public final class SamplerController {
    public private(set) var project: SamplerProject
    public var bank = 0
    public var selectedPad = 0
    public var view: SamplerView = .main
    public var velocityMode: VelocityMode = .position
    public var fullLevel = false
    public var editMode: EditMode = .trim
    /// Track being edited and recorded (UI state).
    public var selectedTrack = 0
    /// How the pads play notes on keygroup / synth / MIDI tracks.
    public var perform = PadPerform()
    public var seqEditor: SeqEditor = .grid
    /// Step editor: the bar shown, and the note stepped on note tracks.
    public var stepPage = 0
    public var stepNote = 60
    /// Pads currently held (program indices), for lighting.
    public private(set) var heldPads: Set<Int> = []
    public private(set) var lastVelocity: [Int: Int] = [:]

    // Performance
    public private(set) var noteRepeat = false
    public private(set) var repeatRate: RepeatRate = .sixteenth
    public private(set) var sixteenLevels: LevelsParameter?
    public private(set) var levelsSource = 0
    /// While held during playback, pressed pads have their events erased as the playhead passes.
    public var eraseHeld = false {
        didSet { if !eraseHeld { erasePads.removeAll(); eraseCheckpointed = false } }
    }

    // Sequencer
    public private(set) var transport = TransportState()
    /// Playhead in ticks inside the sequence; negative during the count-in. Updated every
    /// display frame while playing, so only small views (playhead lines) should read it.
    public private(set) var playhead = 0.0
    /// The playhead's beat (floor; negative in the count-in). Changes once per beat, for
    /// views that only need coarse position (bar.beat readout, page follow).
    public private(set) var playheadBeat = 0
    /// Playhead at the last `poll` (live erase and replace work on the span between polls).
    @ObservationIgnored private var polledPosition = 0.0
    public var recordMode: RecordMode = .overdub
    /// While playing, picking another sequence waits for this one to end (or the bar).
    public var nextSequenceMode = false
    public var nextSequenceAtBar = false
    /// Global automation read / write (SAMPLER_SPEC §6).
    public var automationMode: AutomationMode = .read
    public var qlinkPage: QLinkPage = .pad
    /// Project page assignments.
    public var projectQLinks: [AutoParam?] = [.samplerLevel, .synthLevel, .xyX, .xyY]
    /// The sequence that takes over next (Next Sequence or the song).
    public private(set) var queuedSequence: Int?
    /// Song playback: index into the song's playlist, nil when not playing the song.
    public private(set) var songIndex: Int?
    public private(set) var history = UndoHistory<SamplerProject>()
    /// Clip pads, from engine telemetry (for the pad lights).
    public private(set) var clipStates = [ClipState](repeating: .stopped, count: ClipProgram.count)
    /// The clip last pressed (the step editor's lane on clip tracks).
    public var selectedClip = 0
    /// An audio take is recording into this track (the app runs the recorder).
    public private(set) var audioTakeTrack: Int?

    @ObservationIgnored public var send: (SamplerCommand) -> Void
    /// Called after every project change (persistence hooks in here).
    @ObservationIgnored public var onChange: (SamplerProject) -> Void = { _ in }
    /// Clock for undo coalescing (seconds).
    @ObservationIgnored public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Record on an audio track: the app starts (true) or stops (false) recording audio
    /// into that track. The transport is already running when it's called.
    @ObservationIgnored public var onAudioRecord: (_ start: Bool, _ track: Int) -> Void = { _, _ in }
    @ObservationIgnored private var heldClips: Set<Int> = []

    @ObservationIgnored private var heldGrid: [Int: (pad: Int, tune: Double)] = [:]
    @ObservationIgnored private var heldNotes: [Int: (note: Int, program: TrackProgram)] = [:]
    @ObservationIgnored private var erasePads: Set<Int> = []
    @ObservationIgnored private var eraseCheckpointed = false
    @ObservationIgnored private var take: TakeRecorder?
    @ObservationIgnored private var takeTrack = 0
    @ObservationIgnored private var sequenceGeneration: Int?
    /// Parameters being touched (written), with the last tick written.
    @ObservationIgnored private var touching: [AutoParam: Int?] = [:]
    @ObservationIgnored private var takeBefore: SamplerProject?

    public init(project: SamplerProject = SamplerProject(),
                send: @escaping (SamplerCommand) -> Void = { _ in }) {
        self.project = project
        self.send = send
    }

    /// Pushes every pad, the mixer and the sequence to the engine.
    public func start() {
        for (i, pad) in project.program.pads.enumerated() where !pad.isEmpty { send(.pad(i, pad)) }
        send(.mixer(project.mixer))
        for (i, k) in project.keygroups.enumerated() { send(.keygroup(i, k)) }
        send(.beatsPerBar(project.sequence.beatsPerBar))
        send(.clips(project.clips, beatsPerBar: project.sequence.beatsPerBar))
        send(.sequence(project.sequence))
    }

    // MARK: - Playing

    /// 16 Levels → velocity: pad 1 (bottom-left) = 7 … pad 16 = 127.
    public static func levelVelocity(_ gridIndex: Int) -> Int { (gridIndex + 1) * 8 - 1 }
    /// 16 Levels → tune: pad 1 = −8 … pad 9 = 0 … pad 16 = +7 semitones.
    public static func levelTune(_ gridIndex: Int) -> Double { Double(gridIndex - 8) }

    public func padDown(gridIndex: Int, y: Double = 0.3, size: Double = 0.5) {
        let gridPad = PadAddress.pad(bank: bank, gridIndex: gridIndex)
        var velocity = fullLevel ? 127 : velocityMode.velocity(y: y, size: size)
        if view == .grid, seqEditor == .step {
            // Step editor: the 16 pads are the 16 steps of the selected lane.
            heldPads.insert(gridPad)
            toggleStepCell(gridIndex)
            return
        }
        if track.program == .clip {
            // Clip program: the 16 pads launch clips 1–16.
            heldPads.insert(gridPad)
            heldClips.insert(gridIndex)
            selectedClip = gridIndex
            send(.clipPad(gridIndex, down: true))
            return
        }
        if track.program.isNotes {
            // Pad Perform: this pad is a note on the track's program.
            let note = perform.note(gridIndex)
            stepNote = note
            heldPads.insert(gridPad)
            heldNotes[gridIndex] = (note, track.program)
            lastVelocity[gridPad] = velocity
            send(.liveNote(track.program, note: note, velocity: velocity))
            return
        }
        var pad = gridPad
        var tune = 0.0
        if let levels = sixteenLevels {
            pad = levelsSource
            switch levels {
            case .velocity: velocity = Self.levelVelocity(gridIndex)
            case .tune: tune = Self.levelTune(gridIndex)
            }
        }
        heldPads.insert(gridPad)
        heldGrid[gridIndex] = (pad, tune)
        lastVelocity[gridPad] = velocity

        if eraseHeld, transport.playing {
            erasePads.insert(pad) // erase instead of play
            return
        }
        if sixteenLevels == nil { selectedPad = pad }
        if noteRepeat {
            send(.repeatPad(pad: pad, velocity: velocity, tune: tune))
        } else {
            send(.trigger(pad: pad, velocity: velocity, tune: tune))
        }
    }

    /// A held touch moved or changed size: note repeat follows it for velocity.
    public func padPressure(gridIndex: Int, y: Double, size: Double) {
        guard noteRepeat, !fullLevel, sixteenLevels != .velocity, let h = heldGrid[gridIndex] else { return }
        let v = velocityMode.velocity(y: y, size: size)
        let gridPad = PadAddress.pad(bank: bank, gridIndex: gridIndex)
        guard v != lastVelocity[gridPad] else { return }
        lastVelocity[gridPad] = v
        send(.repeatPad(pad: h.pad, velocity: v, tune: h.tune))
    }

    public func padUp(gridIndex: Int) {
        let gridPad = PadAddress.pad(bank: bank, gridIndex: gridIndex)
        heldPads.remove(gridPad)
        if heldClips.remove(gridIndex) != nil {
            send(.clipPad(gridIndex, down: false))
            return
        }
        if let n = heldNotes.removeValue(forKey: gridIndex) {
            send(.liveNote(n.program, note: n.note, velocity: 0))
            return
        }
        guard let h = heldGrid.removeValue(forKey: gridIndex) else { return }
        if erasePads.remove(h.pad) != nil { return }
        if noteRepeat {
            send(.repeatPad(pad: h.pad, velocity: 0, tune: 0))
        } else {
            send(.release(pad: h.pad)) // ignored by the engine for one-shot pads
        }
    }

    /// Plays the selected pad (e.g. from the trim screen).
    public func audition(_ pad: Int? = nil, velocity: Int = 110) {
        let p = pad ?? selectedPad
        send(.trigger(pad: p, velocity: velocity))
    }

    public func stopAll() { send(.stopAll) }

    public func setNoteRepeat(_ on: Bool) {
        guard on != noteRepeat else { return }
        noteRepeat = on
        sendNoteRepeat()
    }

    public func setRepeatRate(_ r: RepeatRate) {
        repeatRate = r
        if noteRepeat { sendNoteRepeat() }
    }

    private func sendNoteRepeat() {
        send(.noteRepeat(beats: noteRepeat ? repeatRate.beats : 0, swing: project.timingCorrect.engineSwing))
    }

    /// Turns 16 Levels on for the selected pad (nil = off).
    public func setSixteenLevels(_ p: LevelsParameter?) {
        sixteenLevels = p
        if p != nil { levelsSource = selectedPad }
    }

    // MARK: - Transport

    /// Display-rate playhead update (the app calls this every screen refresh).
    public func updatePlayhead(_ ticks: Double) {
        if transport.playing { setPlayhead(ticks) }
    }

    private func setPlayhead(_ ticks: Double) {
        if ticks != playhead { playhead = ticks }
        let beat = Int((ticks / Double(PPQN.ticks)).rounded(.down))
        if beat != playheadBeat { playheadBeat = beat }
    }

    private func resetPlayhead(_ ticks: Double) {
        setPlayhead(ticks)
        polledPosition = ticks
    }

    public func play() {
        guard !transport.playing else { return }
        transport.playing = true
        resetPlayhead(0)
        send(.transport(playing: true, startTick: 0, countInBeats: 0))
    }

    public func stop() {
        if transport.recording != nil { endTake() }
        songIndex = nil
        queuedSequence = nil
        transport.playing = false
        resetPlayhead(0)
        send(.transport(playing: false, startTick: 0, countInBeats: 0))
    }

    /// Record: from stop it starts with the count-in; while playing it punches in.
    /// Pressing it again while recording punches out and keeps playing.
    public func record() {
        if transport.recording != nil {
            endTake()
            return
        }
        let audio = track.program == .audio
        if !audio { beginTake() }
        if !transport.playing {
            transport.playing = true
            let countIn = transport.countInBars * project.sequence.beatsPerBar
            resetPlayhead(Double(-countIn * PPQN.ticks))
            send(.transport(playing: true, startTick: 0, countInBeats: countIn))
        }
        if audio {
            // Audio track: the app records audio; it lands on the track when the take ends.
            audioTakeTrack = trackIndex
            transport.recording = .replace
            onAudioRecord(true, trackIndex)
        }
    }

    public func setMetronome(_ on: Bool) {
        transport.metronome = on
        send(.metronome(on))
    }

    public func setCountIn(bars: Int) { transport.countInBars = max(0, min(2, bars)) }

    private func beginTake() {
        takeBefore = project
        takeTrack = trackIndex
        take = TakeRecorder()
        transport.recording = recordMode
        let tc = project.timingCorrect
        send(.recording(true, guardTicks: tc.onInput ? tc.value.ticks / 2 : 60))
    }

    private func endTake() {
        if let t = audioTakeTrack {
            audioTakeTrack = nil
            transport.recording = nil
            onAudioRecord(false, t)
            return
        }
        guard var tk = take else { return }
        var seq = project.sequence
        let t = min(takeTrack, seq.tracks.count - 1)
        tk.finish(at: max(0, Int(playhead)), in: &seq, track: t)
        project.sequence = seq
        if let before = takeBefore, before != project {
            history.record(before, label: "Record", at: now())
        }
        take = nil
        takeBefore = nil
        transport.recording = nil
        send(.recording(false, guardTicks: 0))
        send(.sequence(project.sequence))
        onChange(project)
    }

    /// Feed engine telemetry here (~30×/s): recorded hits, the playhead, and whether the
    /// engine is still playing (a non-looping sequence stops at its end).
    public func poll(hits: [RecordedHit], position: Double, enginePlaying: Bool, sequenceGeneration gen: Int? = nil) {
        if let gen {
            if let last = sequenceGeneration, gen != last { sequenceSwapped() }
            sequenceGeneration = gen
        }
        let previous = polledPosition
        if transport.playing {
            setPlayhead(position)
            polledPosition = position
        }
        var seq = project.sequence
        var changed = false
        let t = min(take != nil ? takeTrack : trackIndex, seq.tracks.count - 1)

        // Only hits that match the track: pad hits on drum tracks, notes on note tracks,
        // clip starts and stops on clip tracks; audio tracks take no events.
        let program = seq.tracks[t].program
        let mine: [RecordedHit] = switch program {
        case .clip: hits.filter(\.isClip)
        case .audio: []
        default: hits.filter { !$0.isClip && $0.isNote == program.isNotes }
        }
        if var tk = take, !mine.isEmpty {
            let tc = project.timingCorrect
            tk.ingest(mine, into: &seq, track: t, timing: tc.onInput ? tc : nil)
            take = tk
            changed = true
        }
        if transport.playing, previous >= 0, position >= 0, Int(previous) != Int(position) {
            let from = Int(previous), to = Int(position)
            if transport.recording == .replace, let tk = take {
                let before = seq
                seq.erase(track: t, from: from, to: to, keep: tk.recordedIDs)
                changed = changed || before != seq
            }
            if eraseHeld, !erasePads.isEmpty {
                let before = seq
                seq.erase(track: t, from: from, to: to, pads: erasePads, keep: take?.recordedIDs ?? [])
                if before != seq {
                    if !eraseCheckpointed, take == nil {
                        history.record(project, label: "Erase", at: now())
                        eraseCheckpointed = true
                    }
                    changed = true
                }
            }
        }
        if changed {
            project.sequence = seq
            send(.sequence(seq))
            onChange(project)
        }
        if transport.playing, position >= 0, automationMode != .off { playAutomation(at: position) }
        if transport.playing, !enginePlaying, previous > 0 { stop() } // a one-shot sequence or song ended
    }

    // MARK: - Sequence editing

    public var sequence: PadSequence { project.sequence }

    /// Applies an undoable edit to the current sequence and sends it to the engine.
    public func editSequence(_ label: String, key: String? = nil, _ body: (inout PadSequence) -> Void) {
        var seq = project.sequence
        body(&seq)
        guard seq != project.sequence else { return }
        checkpoint(label, key: key)
        project.sequence = seq
        send(.sequence(seq))
        onChange(project)
    }

    /// Grid tap: removes the pad's note starting in [tick, tick + span), or adds one.
    public func toggleStep(pad: Int, tick: Int, span: Int, velocity: Int = 100) {
        let t = trackIndex
        editSequence("Edit notes") { seq in
            if let i = seq.tracks[t].events.firstIndex(where: { $0.pad == pad && $0.tick >= tick && $0.tick < tick + span }) {
                seq.tracks[t].events.remove(at: i)
            } else {
                seq.add(track: t, tick: tick, length: span, pad: pad, velocity: velocity)
            }
        }
    }

    public func moveEvent(_ id: UInt32, toTick tick: Int, pad: Int? = nil) {
        let t = trackIndex
        editSequence("Move note", key: "move-\(id)") { seq in
            guard let i = seq.tracks[t].events.firstIndex(where: { $0.id == id }) else { return }
            let len = seq.lengthTicks
            seq.tracks[t].events[i].tick = ((tick % len) + len) % len
            if let pad { seq.tracks[t].events[i].pad = pad }
            seq.sortEvents(track: t)
        }
    }

    public func setVelocity(_ id: UInt32, _ v: Int) {
        let t = trackIndex
        editSequence("Velocity", key: "velocity-\(id)") { seq in
            guard let i = seq.tracks[t].events.firstIndex(where: { $0.id == id }) else { return }
            seq.tracks[t].events[i].velocity = max(1, min(127, v))
        }
    }

    public func deleteEvent(_ id: UInt32) {
        let t = trackIndex
        editSequence("Delete note") { $0.tracks[t].events.removeAll { $0.id == id } }
    }

    /// Applies Timing Correct to every note of the track.
    public func quantizeTrack() {
        let t = trackIndex
        let tc = project.timingCorrect
        editSequence("Quantize") { seq in
            let len = seq.lengthTicks
            for i in seq.tracks[t].events.indices {
                seq.tracks[t].events[i].tick = ((tc.apply(seq.tracks[t].events[i].tick) % len) + len) % len
            }
            seq.sortEvents(track: t)
        }
    }

    public func clearTrack() {
        let t = trackIndex
        editSequence("Clear track") { $0.tracks[t].events.removeAll() }
    }

    public func setBars(_ n: Int) { editSequence("Length") { $0.setBars(n) } }

    public func doubleSequence() { editSequence("Double") { $0.double() } }

    public func setLoop(_ on: Bool) { editSequence("Loop") { $0.loop = on } }

    public func setTrackMute(_ on: Bool) {
        let t = trackIndex
        editSequence("Mute") { $0.tracks[t].mute = on }
    }

    // MARK: - Tracks (SAMPLER_SPEC §6)

    public var trackIndex: Int { max(0, min(selectedTrack, project.sequence.tracks.count - 1)) }
    public var track: Track { project.sequence.tracks[trackIndex] }

    public func selectTrack(_ i: Int) {
        guard project.sequence.tracks.indices.contains(i) else { return }
        selectedTrack = i
    }

    /// Adds a track (to every sequence, so track numbers line up) and selects it.
    public func addTrack(_ program: TrackProgram) {
        guard project.sequence.tracks.count < Track.maxTracks else { return }
        checkpoint("New track")
        let n = project.sequence.tracks.count + 1
        for i in project.sequences.indices where project.sequences[i].tracks.count < n {
            project.sequences[i].tracks.append(Track(name: "Track \(n)", program: program))
        }
        selectedTrack = n - 1
        send(.sequence(project.sequence))
        onChange(project)
    }

    public func deleteTrack(_ i: Int) {
        guard project.sequence.tracks.count > 1, project.sequence.tracks.indices.contains(i) else { return }
        editSequence("Delete track") { $0.tracks.remove(at: i) }
        selectedTrack = min(selectedTrack, project.sequence.tracks.count - 1)
    }

    public func setTrackProgram(_ i: Int, _ program: TrackProgram) {
        editSequence("Track program") { $0.tracks[i].program = program }
    }

    public func setTrackSolo(_ i: Int, _ on: Bool) {
        editSequence("Solo") { $0.tracks[i].solo = on }
    }

    // MARK: - Keygroups (SAMPLER_SPEC §3.2)

    /// Adds a keygroup program and returns its index (nil when all 8 are used).
    @discardableResult
    public func addKeygroup(_ program: KeygroupProgram) -> Int? {
        guard project.keygroups.count < KeygroupProgram.maxPrograms else { return nil }
        checkpoint("New keygroup")
        project.keygroups.append(program)
        let i = project.keygroups.count - 1
        send(.keygroup(i, program))
        onChange(project)
        return i
    }

    public func updateKeygroup(_ i: Int, key: String? = nil, _ body: (inout KeygroupProgram) -> Void) {
        guard project.keygroups.indices.contains(i) else { return }
        var k = project.keygroups[i]
        body(&k)
        k.zones = Array(k.zones.prefix(KeygroupProgram.maxZones))
        guard k != project.keygroups[i] else { return }
        checkpoint("Edit keygroup", key: key ?? "keygroup-\(i)")
        project.keygroups[i] = k
        send(.keygroup(i, k))
        onChange(project)
    }

    // MARK: - Step editor

    /// Ticks per step (the Timing Correct value) and steps per page.
    public var stepTicks: Int { project.timingCorrect.value.ticks }
    public static let stepsPerPage = 16

    /// The pad (drum tracks) or note (note tracks) the step editor writes.
    public var stepLane: Int {
        switch track.program {
        case .clip: selectedClip
        case let p where p.isNotes: stepNote
        default: selectedPad
        }
    }

    public var stepPages: Int {
        max(1, Int((Double(project.sequence.lengthTicks) / Double(stepTicks * Self.stepsPerPage)).rounded(.up)))
    }

    public func stepIsOn(_ step: Int) -> Bool {
        let tick = (min(stepPage, stepPages - 1) * Self.stepsPerPage + step) * stepTicks
        return track.events.contains { $0.pad == stepLane && $0.tick >= tick && $0.tick < tick + stepTicks }
    }

    public func toggleStepCell(_ step: Int) {
        let tick = (min(stepPage, stepPages - 1) * Self.stepsPerPage + step) * stepTicks
        guard tick < project.sequence.lengthTicks else { return }
        toggleStep(pad: stepLane, tick: tick, span: stepTicks)
    }

    /// Nudges an event by `steps` Timing Correct steps.
    public func nudgeEvent(_ id: UInt32, steps: Int) {
        guard let e = track.events.first(where: { $0.id == id }) else { return }
        moveEvent(id, toTick: e.tick + steps * stepTicks)
    }

    /// What lane / pad `g` of the grid means on the selected track: a pad index on drum
    /// tracks, a MIDI note (from Pad Perform) on note tracks.
    public func laneValue(_ g: Int) -> Int {
        switch track.program {
        case .clip: g
        case let p where p.isNotes: perform.note(g)
        default: PadAddress.pad(bank: bank, gridIndex: g)
        }
    }

    // MARK: - Arpeggiator, audio tracks, clips, retro (phase 6)

    public func setTrackArp(_ i: Int, _ body: (inout TrackArp) -> Void) {
        guard project.sequence.tracks.indices.contains(i) else { return }
        editSequence("Arpeggiator", key: "arp-\(i)") { seq in
            body(&seq.tracks[i].arp)
            seq.tracks[i].arp.octaves = max(1, min(4, seq.tracks[i].arp.octaves))
            seq.tracks[i].arp.gate = max(0.05, min(1, seq.tracks[i].arp.gate))
        }
    }

    public var canAddAudioTrack: Bool {
        project.sequence.audioSlots.count < PadSequence.maxAudioTracks && project.sequence.tracks.count < Track.maxTracks
    }

    /// Puts `sample` on audio track `i` (nil clears it).
    public func setAudioClip(_ i: Int, _ clip: AudioClip?, label: String = "Audio") {
        guard project.sequence.tracks.indices.contains(i), project.sequence.tracks[i].program == .audio else { return }
        if let id = clip?.sampleID, project.sample(id) == nil { return }
        editSequence(label, key: label == "Audio" ? "audio-\(i)" : nil) { $0.tracks[i].audio = clip }
    }

    /// A new audio track playing `info` (added to the pool if new) from `startTick`. One
    /// undo step. Returns the track.
    @discardableResult
    public func addAudioTrack(_ info: SampleInfo, startTick: Int = 0, name: String? = nil) -> Int? {
        guard canAddAudioTrack else { return nil }
        checkpoint("New audio track")
        if !project.samples.contains(where: { $0.id == info.id }) { project.samples.append(info) }
        let n = project.sequence.tracks.count + 1
        for i in project.sequences.indices where project.sequences[i].tracks.count < n {
            project.sequences[i].tracks.append(Track(name: "Track \(n)", program: .audio))
        }
        var seq = project.sequence
        seq.tracks[n - 1].name = name ?? info.name
        seq.tracks[n - 1].audio = AudioClip(sampleID: info.id, startTick: min(startTick, seq.lengthTicks - 1))
        project.sequence = seq
        selectedTrack = n - 1
        send(.sequence(project.sequence))
        onChange(project)
        return n - 1
    }

    /// The app finished recording an audio take for `track`: one undo step.
    public func finishAudioTake(track i: Int, sample info: SampleInfo, startTick: Int) {
        checkpoint("Record audio")
        if !project.samples.contains(where: { $0.id == info.id }) { project.samples.append(info) }
        guard project.sequence.tracks.indices.contains(i), project.sequence.tracks[i].program == .audio else { onChange(project); return }
        var seq = project.sequence
        seq.tracks[i].audio = AudioClip(sampleID: info.id, startTick: max(0, min(startTick, seq.lengthTicks - 1)))
        project.sequence = seq
        send(.sequence(seq))
        onChange(project)
    }

    public func updateClips(key: String? = nil, _ body: (inout ClipProgram) -> Void) {
        var c = project.clips
        body(&c)
        guard c != project.clips else { return }
        checkpoint("Edit clips", key: key)
        project.clips = c
        send(.clips(c, beatsPerBar: project.sequence.beatsPerBar))
        onChange(project)
    }

    public func stopClips() { send(.clipStopAll) }

    /// Engine telemetry for the clip pads.
    public func updateClipStates(_ states: [ClipState]) {
        if states != clipStates { clipStates = states }
    }

    /// Retrospective record: turns captured playing into a new sequence and selects it.
    /// Returns its name, or nil when there was nothing to capture.
    @discardableResult
    public func captureRetro(_ events: [RetroEvent], quantize: Bool) -> String? {
        guard project.sequences.count < SamplerProject.maxSequences else { return nil }
        let name = String(format: "Retro %02d", project.sequences.count + 1)
        guard let seq = RetroCapture.sequence(from: events, beatsPerBar: project.sequence.beatsPerBar, name: name,
                                              timing: quantize ? project.timingCorrect : nil) else { return nil }
        if transport.recording != nil { endTake() }
        checkpoint("Retro record")
        project.sequences.append(seq)
        project.currentSequence = project.sequences.count - 1
        selectedTrack = 0
        send(.beatsPerBar(seq.beatsPerBar))
        send(.sequence(seq))
        onChange(project)
        return name
    }

    // MARK: - Parameters, automation and Q-Links

    public func value(of p: AutoParam) -> Double {
        let m = project.mixer
        switch p {
        case .samplerLevel: return m.samplerLevel
        case .synthLevel: return m.synthLevel
        case .masterLevel: return m.masterLevel
        case .padLevel(let i): return project.program.pads[i].level
        case .padPan(let i): return project.program.pads[i].pan
        case .padTune(let i): return project.program.pads[i].layers.first?.tune ?? 0
        case .submixLevel(let i): return m.submixes[i].level
        case .returnLevel(let i): return m.returns[i].level
        case .xyX: return m.xy.x
        case .xyY: return m.xy.y
        }
    }

    /// The four knobs of the current Q-Link page.
    public var qlinks: [AutoParam?] {
        switch qlinkPage {
        case .pad: [.padLevel(selectedPad), .padPan(selectedPad), .padTune(selectedPad), .submixLevel(max(0, selected.output - 1))]
        case .mixer: [.samplerLevel, .synthLevel, .masterLevel, .xyX]
        case .returns: (0..<4).map { .returnLevel($0) }
        case .project: projectQLinks
        }
    }

    /// Writes a parameter without an undo step or a save (automation playback).
    private func apply(_ p: AutoParam, _ v: Double) {
        let v = min(p.range.upperBound, max(p.range.lowerBound, v))
        switch p {
        case .padLevel(let i), .padPan(let i), .padTune(let i):
            var pad = project.program.pads[i]
            switch p {
            case .padLevel: pad.level = v
            case .padPan: pad.pan = v
            default: if !pad.layers.isEmpty { pad.layers[0].tune = v.rounded() }
            }
            guard pad != project.program.pads[i] else { return }
            project.program.pads[i] = pad
            send(.pad(i, pad))
        case .xyX, .xyY:
            if p == .xyX { project.mixer.xy.x = v } else { project.mixer.xy.y = v }
            send(.xy(project.mixer.xy))
        default:
            var m = project.mixer
            switch p {
            case .samplerLevel: m.samplerLevel = v
            case .synthLevel: m.synthLevel = v
            case .masterLevel: m.masterLevel = v
            case .submixLevel(let i): m.submixes[i].level = v
            case .returnLevel(let i): m.returns[i].level = v
            default: break
            }
            guard m != project.mixer else { return }
            project.mixer = m
            send(.mixer(m))
        }
    }

    /// A knob or fader moved by hand. In Write mode while playing it's also recorded
    /// into the selected track (one undo step per gesture).
    public func setParam(_ p: AutoParam, _ v: Double) {
        let first = touching[p] == nil
        if first { checkpoint("Change \(p.label)", key: "param-\(p.label)") }
        if automationMode == .write, transport.playing, playhead >= 0 {
            let tick = Int(playhead)
            let t = trackIndex
            var seq = project.sequence
            var lanes = seq.tracks[t].automation
            let li = lanes.firstIndex { $0.param == p } ?? { lanes.append(AutomationLane(param: p)); return lanes.count - 1 }()
            lanes[li].write(min(p.range.upperBound, max(p.range.lowerBound, v)), at: tick, from: touching[p] ?? nil)
            seq.tracks[t].automation = lanes
            project.sequence = seq
            touching[p] = .some(tick)
        } else if first {
            touching[p] = .some(nil)
        }
        apply(p, v)
        onChange(project)
    }

    /// The knob was let go: automation reads that parameter again.
    public func endParam(_ p: AutoParam) { touching[p] = nil }

    public func clearAutomation(_ p: AutoParam? = nil) {
        let t = trackIndex
        editSequence("Clear automation") { seq in
            if let p { seq.tracks[t].automation.removeAll { $0.param == p } } else { seq.tracks[t].automation.removeAll() }
        }
    }

    private func playAutomation(at tick: Double) {
        let anySolo = project.sequence.tracks.contains { $0.solo }
        for track in project.sequence.tracks where !track.mute && (!anySolo || track.solo) {
            for lane in track.automation where touching[lane.param] == nil {
                guard let v = lane.value(at: tick), abs(v - value(of: lane.param)) > 1e-3 else { continue }
                apply(lane.param, v)
            }
        }
    }

    // MARK: - Song mode (SAMPLER_SPEC §7)

    public func editSong(_ label: String, _ body: (inout Song) -> Void) {
        var s = project.song
        body(&s)
        guard s != project.song else { return }
        checkpoint(label)
        project.song = s
        onChange(project)
    }

    public func addSongStep(sequence: Int) {
        editSong("Add step") { $0.steps.append(SongStep(sequence: sequence)) }
    }

    /// Plays the song from its first step.
    public func playSong() {
        let list = project.song.playlist.filter { project.sequences.indices.contains($0) }
        guard !list.isEmpty else { return }
        if transport.playing { stop() }
        project.currentSequence = list[0]
        songIndex = 0
        send(.beatsPerBar(project.sequence.beatsPerBar))
        var first = project.sequence
        first.loop = list.count > 1 || project.song.loop // a one-step song plays once
        send(.sequence(first)) // set directly: a queue while stopped would count as a swap
        queueNextSongStep()
        play()
    }

    private func queueNextSongStep() {
        guard let i = songIndex else { return }
        let list = project.song.playlist.filter { project.sequences.indices.contains($0) }
        var next = i + 1
        if next >= list.count {
            guard project.song.loop else { return }
            next = 0
        }
        let isLast = next == list.count - 1 && !project.song.loop
        queuedSequence = list[next]
        send(.queueSequence(project.sequences[list[next]], atBar: false, loop: isLast ? false : true))
    }

    private func sequenceSwapped() {
        if let i = songIndex {
            let list = project.song.playlist.filter { project.sequences.indices.contains($0) }
            let next = i + 1 < list.count ? i + 1 : 0
            songIndex = next
            project.currentSequence = list[next]
            queuedSequence = nil
            queueNextSongStep()
        } else if let q = queuedSequence {
            project.currentSequence = q
            queuedSequence = nil
        }
        selectedTrack = min(selectedTrack, project.sequence.tracks.count - 1)
    }

    /// Flattens the song into a new sequence and selects it.
    public func convertSongToSequence() {
        guard !project.song.steps.isEmpty, project.sequences.count < SamplerProject.maxSequences else { return }
        checkpoint("Song → sequence")
        let n = project.sequences.count + 1
        project.sequences.append(project.song.flattened(project.sequences, name: String(format: "Sequence %02d", n)))
        project.currentSequence = n - 1
        send(.sequence(project.sequence))
        onChange(project)
    }

    /// Switches sequence (creating it, with the current length, if it's new).
    public func selectSequence(_ index: Int) {
        guard (0..<SamplerProject.maxSequences).contains(index), index != project.currentSequence else { return }
        if nextSequenceMode, transport.playing, project.sequences.indices.contains(index) {
            queuedSequence = index
            send(.queueSequence(project.sequences[index], atBar: nextSequenceAtBar, loop: nil))
            return
        }
        if transport.recording != nil { endTake() }
        checkpoint("Sequence")
        let bars = project.sequence.bars
        while project.sequences.count <= index {
            let n = project.sequences.count + 1
            project.sequences.append(PadSequence(name: String(format: "Sequence %02d", n), bars: bars))
        }
        project.currentSequence = index
        send(.beatsPerBar(project.sequence.beatsPerBar))
        send(.sequence(project.sequence))
        onChange(project)
    }

    public func setTimingCorrect(_ body: (inout TimingCorrect) -> Void) {
        var tc = project.timingCorrect
        body(&tc)
        guard tc != project.timingCorrect else { return }
        checkpoint("Timing Correct", key: "tc")
        project.timingCorrect = tc
        if noteRepeat { sendNoteRepeat() }
        onChange(project)
    }

    // MARK: - Undo

    public func undo() {
        guard take == nil, let s = history.undo(current: project) else { return }
        restore(s)
    }

    public func redo() {
        guard take == nil, let s = history.redo(current: project) else { return }
        restore(s)
    }

    private func checkpoint(_ label: String, key: String? = nil) {
        guard take == nil else { return } // a take is one undo step, recorded when it ends
        history.record(project, label: label, key: key, at: now())
    }

    /// Restores a snapshot. The sample pool stays as it is (imports aren't undone, and the
    /// files of deleted samples are gone).
    private func restore(_ snapshot: SamplerProject) {
        var p = snapshot
        p.samples = project.samples
        let old = project
        project = p
        for i in project.program.pads.indices where project.program.pads[i] != old.program.pads[i] {
            send(.pad(i, project.program.pads[i]))
        }
        if project.mixer != old.mixer { send(.mixer(project.mixer)) }
        if project.keygroups != old.keygroups {
            for (i, k) in project.keygroups.enumerated() { send(.keygroup(i, k)) }
        }
        if project.clips != old.clips { send(.clips(project.clips, beatsPerBar: project.sequence.beatsPerBar)) }
        selectedTrack = min(selectedTrack, project.sequence.tracks.count - 1)
        if project.sequence != old.sequence || project.currentSequence != old.currentSequence {
            send(.sequence(project.sequence))
        }
        if project.timingCorrect != old.timingCorrect, noteRepeat { sendNoteRepeat() }
        selectedPad = min(selectedPad, DrumProgram.padCount - 1)
        onChange(project)
    }

    // MARK: - Chop, processes, sample versions

    /// Samples a pad or keygroup zone uses.
    public var usedSampleIDs: Set<SampleID> {
        Set(project.program.pads.flatMap { $0.layers.compactMap(\.sampleID) }
            + project.keygroups.flatMap { $0.zones.flatMap { $0.layers.compactMap(\.sampleID) } }
            + project.clips.pads.compactMap(\.sampleID)
            + project.sequences.flatMap { $0.tracks.compactMap { $0.audio?.sampleID } })
    }

    /// Clip pads and audio tracks that use `id`: point them at `new` (nil = clear).
    private func replaceInClipsAndAudio(_ id: SampleID, with new: SampleID?) {
        var c = project.clips
        for i in c.pads.indices where c.pads[i].sampleID == id { c.pads[i].sampleID = new }
        if c != project.clips {
            project.clips = c
            send(.clips(c, beatsPerBar: project.sequence.beatsPerBar))
        }
        var touched = false
        for s in project.sequences.indices {
            for t in project.sequences[s].tracks.indices where project.sequences[s].tracks[t].audio?.sampleID == id {
                if let new { project.sequences[s].tracks[t].audio?.sampleID = new } else { project.sequences[s].tracks[t].audio = nil }
                touched = true
            }
        }
        if touched { send(.sequence(project.sequence)) }
    }

    /// Samples to list: everything not archived, plus archived ones a pad still uses.
    public var visibleSamples: [SampleInfo] {
        let used = usedSampleIDs
        return project.samples.filter { !$0.archived || used.contains($0.id) }
    }

    /// Puts each slice on a pad, starting at `startPad` (A01 by default), as start/end trims
    /// of `sample`. Returns the pads used.
    @discardableResult
    public func assignSlices(_ slices: [Range<Int>], of sample: SampleID, startPad: Int = 0,
                             trigger: TriggerMode = .oneShot, label: String? = "Chop → pads") -> [Int] {
        guard let info = project.sample(sample) else { return [] }
        if let label { checkpoint(label) }
        var used: [Int] = []
        for (i, r) in slices.enumerated() where startPad + i < DrumProgram.padCount {
            let p = startPad + i
            var pad = project.program.pads[p]
            var layer = PadLayer(sampleID: sample)
            layer.start = r.lowerBound
            layer.end = r.upperBound >= info.frames ? nil : r.upperBound
            pad.layers = [layer]
            pad.trigger = trigger
            project.program.pads[p] = pad
            send(.pad(p, pad))
            used.append(p)
        }
        onChange(project)
        return used
    }

    /// Extracted slices: each new sample goes on its own pad from `startPad`.
    @discardableResult
    public func assignExtracted(_ infos: [SampleInfo], startPad: Int = 0) -> [Int] {
        checkpoint("Extract slices")
        project.samples.append(contentsOf: infos.filter { i in !project.samples.contains { $0.id == i.id } })
        var used: [Int] = []
        for (i, info) in infos.enumerated() where startPad + i < DrumProgram.padCount {
            var pad = project.program.pads[startPad + i]
            pad.layers = [PadLayer(sampleID: info.id)]
            project.program.pads[startPad + i] = pad
            send(.pad(startPad + i, pad))
            used.append(startPad + i)
        }
        onChange(project)
        return used
    }

    /// Slices on pads plus a new sequence that replays them at their original times:
    /// one undo step.
    @discardableResult
    public func convertToSliceSequence(_ slices: [Range<Int>], of sample: SampleID, startPad: Int,
                                       sampleRate: Double, bpm: Double) -> [Int] {
        guard project.sequences.count < SamplerProject.maxSequences else { return [] }
        checkpoint("Chop → sequence")
        let pads = assignSlices(slices, of: sample, startPad: startPad, label: nil)
        makeSliceSequence(slices, pads: pads, sampleRate: sampleRate, bpm: bpm, label: nil)
        return pads
    }

    /// The first bank (from `bank`) with all 16 pads empty, or nil.
    public func firstEmptyBank(from bank: Int) -> Int? {
        (0..<DrumProgram.banks).map { (bank + $0) % DrumProgram.banks }.first { b in
            (0..<DrumProgram.padsPerBank).allSatisfy { project.program.pads[PadAddress.pad(bank: b, gridIndex: $0)].isEmpty }
        }
    }

    /// A new sequence that replays slices (on `pads`) at their original times at `bpm`.
    public func makeSliceSequence(_ slices: [Range<Int>], pads: [Int], sampleRate: Double, bpm: Double,
                                  label: String? = "Chop → sequence") {
        let ticksPerFrame = bpm / 60 * Double(PPQN.ticks) / sampleRate
        let index = project.sequences.count
        guard index < SamplerProject.maxSequences else { return }
        if let label { checkpoint(label) }
        let total = Int((Double(slices.last?.upperBound ?? 0) * ticksPerFrame).rounded())
        var seq = PadSequence(name: String(format: "Sequence %02d", index + 1), bars: 1)
        seq.setBars(max(1, Int((Double(total) / Double(seq.ticksPerBar)).rounded(.up))))
        for (r, pad) in zip(slices, pads) {
            let tick = Int((Double(r.lowerBound) * ticksPerFrame).rounded())
            let length = max(1, Int((Double(r.count) * ticksPerFrame).rounded()))
            if tick < seq.lengthTicks { seq.add(tick: tick, length: length, pad: pad, velocity: 100) }
        }
        project.sequences.append(seq)
        project.currentSequence = index
        send(.beatsPerBar(seq.beatsPerBar))
        send(.sequence(seq))
        onChange(project)
    }

    /// A destructive process made `new` from `old`: every pad that used `old` now uses
    /// `new` (trims reset when the length changed). `old` stays, archived, for undo.
    public func replaceSample(_ old: SampleID, with new: SampleInfo, label: String) {
        guard let oldInfo = project.sample(old) else { return }
        checkpoint(label)
        project.samples.append(new)
        if let i = project.samples.firstIndex(where: { $0.id == old }) { project.samples[i].archived = true }
        let sameLength = oldInfo.frames == new.frames
        for p in project.program.pads.indices {
            var pad = project.program.pads[p]
            var changed = false
            for l in pad.layers.indices where pad.layers[l].sampleID == old {
                pad.layers[l].sampleID = new.id
                if !sameLength {
                    pad.layers[l].start = 0
                    pad.layers[l].end = nil
                }
                changed = true
            }
            if changed {
                project.program.pads[p] = pad
                send(.pad(p, pad))
            }
        }
        replaceInKeygroups(old) { $0 = new.id }
        replaceInClipsAndAudio(old, with: new.id)
        onChange(project)
    }

    /// What a destructive process on a pad acts on (SAMPLER_SPEC §5.3).
    public struct ProcessTarget: Equatable, Sendable {
        public var pad: Int
        /// The pad's first layer with a sample.
        public var layer: Int
        public var sample: SampleID
        /// The layer's trim, in the sample's frames.
        public var trim: Range<Int>
        /// The pad plays only this part of a sample that something else also uses. The
        /// process then runs on these frames alone, and only this pad gets the result.
        public var slice: Range<Int>?
    }

    public func processTarget(pad p: Int) -> ProcessTarget? {
        let pad = project.program.pads[p]
        guard let l = pad.layers.firstIndex(where: { $0.sampleID != nil }), let id = pad.layers[l].sampleID,
              let info = project.sample(id) else { return nil }
        let layer = pad.layers[l]
        let end = min(layer.end ?? info.frames, info.frames)
        let start = min(max(0, layer.start), max(0, end - 1))
        let trim = start..<end
        let partial = start > 0 || end < info.frames
        return ProcessTarget(pad: p, layer: l, sample: id, trim: trim,
                             slice: partial && isShared(id, outside: p, layer: layer) ? trim : nil)
    }

    /// Whether anything other than `pad`'s layers playing the same range as `layer` uses `id`.
    private func isShared(_ id: SampleID, outside pad: Int, layer: PadLayer) -> Bool {
        for (p, other) in project.program.pads.enumerated() {
            for l in other.layers where l.sampleID == id {
                if p != pad || l.start != layer.start || l.end != layer.end { return true }
            }
        }
        if project.keygroups.contains(where: { $0.zones.contains { $0.layers.contains { $0.sampleID == id } } }) { return true }
        if project.clips.pads.contains(where: { $0.sampleID == id }) { return true }
        return project.sequences.contains { $0.tracks.contains { $0.audio?.sampleID == id } }
    }

    /// A process ran on `target`'s slice and made `new`: only that pad's layers playing
    /// the slice now use `new`, from its start to its end. Other users of the old sample
    /// stay as they are. One undo step.
    public func replaceSlice(_ target: ProcessTarget, with new: SampleInfo, label: String) {
        guard target.slice != nil else { return }
        var pad = project.program.pads[target.pad]
        guard pad.layers.indices.contains(target.layer), pad.layers[target.layer].sampleID == target.sample else { return }
        let old = pad.layers[target.layer]
        checkpoint(label)
        if !project.samples.contains(where: { $0.id == new.id }) { project.samples.append(new) }
        for l in pad.layers.indices where pad.layers[l].sampleID == target.sample
            && pad.layers[l].start == old.start && pad.layers[l].end == old.end {
            pad.layers[l].sampleID = new.id
            pad.layers[l].start = 0
            pad.layers[l].end = nil
        }
        project.program.pads[target.pad] = pad
        send(.pad(target.pad, pad))
        onChange(project)
    }

    /// Puts a processed result where it belongs: on the slice pad alone, or in place of
    /// the whole sample everywhere.
    public func applyProcessed(_ target: ProcessTarget, new: SampleInfo, label: String) {
        if target.slice != nil { replaceSlice(target, with: new, label: label) }
        else { replaceSample(target.sample, with: new, label: label) }
    }

    private func replaceInKeygroups(_ id: SampleID, _ body: (inout SampleID?) -> Void) {
        for k in project.keygroups.indices {
            var kg = project.keygroups[k]
            for z in kg.zones.indices {
                for l in kg.zones[z].layers.indices where kg.zones[z].layers[l].sampleID == id {
                    body(&kg.zones[z].layers[l].sampleID)
                }
            }
            if kg != project.keygroups[k] {
                project.keygroups[k] = kg
                send(.keygroup(k, kg))
            }
        }
    }

    /// Archived samples no pad uses (their files can go). Clears undo history.
    public func discardUnused() -> [SampleInfo] {
        let used = usedSampleIDs
        let gone = project.samples.filter { $0.archived && !used.contains($0.id) }
        guard !gone.isEmpty else { return [] }
        project.samples.removeAll { s in gone.contains { $0.id == s.id } }
        history.clear()
        onChange(project)
        return gone
    }

    // MARK: - Pad editing

    public var selected: Pad { project.program.pads[selectedPad] }

    public func updatePad(_ index: Int, _ body: (inout Pad) -> Void) {
        updatePad(index, label: "Edit pad", key: "pad-\(index)", body)
    }

    public func updateSelected(_ body: (inout Pad) -> Void) { updatePad(selectedPad, body) }

    private func updatePad(_ index: Int, label: String, key: String?, _ body: (inout Pad) -> Void) {
        var pad = project.program.pads[index]
        body(&pad)
        pad.layers = Array(pad.layers.prefix(Pad.maxLayers))
        if pad.layers.isEmpty { pad.layers = [PadLayer()] }
        guard pad != project.program.pads[index] else { return }
        checkpoint(label, key: key)
        project.program.pads[index] = pad
        send(.pad(index, pad))
        onChange(project)
    }

    /// Adds samples to the pool and puts each on the next empty pad, starting at the
    /// selected pad (MPC-style auto-assign). Returns the pads used.
    @discardableResult
    public func addSamples(_ infos: [SampleInfo], autoAssign: Bool = true) -> [Int] {
        if autoAssign, !infos.isEmpty { checkpoint("Import") }
        project.samples.append(contentsOf: infos.filter { info in !project.samples.contains { $0.id == info.id } })
        var used: [Int] = []
        if autoAssign {
            var cursor = selectedPad
            for info in infos {
                while cursor < DrumProgram.padCount, !project.program.pads[cursor].isEmpty { cursor += 1 }
                guard cursor < DrumProgram.padCount else { break }
                assign(info.id, to: cursor, notify: false)
                used.append(cursor)
                cursor += 1
            }
        }
        onChange(project)
        return used
    }

    public func assign(_ sample: SampleID, to pad: Int) {
        checkpoint("Assign sample")
        assign(sample, to: pad, notify: true)
    }

    private func assign(_ sample: SampleID, to pad: Int, notify: Bool) {
        var p = project.program.pads[pad]
        var layer = PadLayer(sampleID: sample)
        if let old = p.layers.first {
            layer.tune = old.tune
            layer.level = old.level
            layer.pan = old.pan
        }
        p.layers[0] = layer
        project.program.pads[pad] = p
        send(.pad(pad, p))
        if notify { onChange(project) }
    }

    /// Removes a sample from the pool and clears every layer that used it. Its file is
    /// deleted, so this also clears the undo history.
    public func removeSample(_ id: SampleID) {
        project.samples.removeAll { $0.id == id }
        for i in project.program.pads.indices {
            var p = project.program.pads[i]
            var changed = false
            for j in p.layers.indices where p.layers[j].sampleID == id {
                p.layers[j] = PadLayer()
                changed = true
            }
            if changed {
                project.program.pads[i] = p
                send(.pad(i, p))
            }
        }
        replaceInKeygroups(id) { $0 = nil }
        replaceInClipsAndAudio(id, with: nil)
        history.clear()
        onChange(project)
    }

    /// Sets a layer's trim, clamped to the sample and to at least 2 frames.
    public func setTrim(pad: Int, layer: Int = 0, start: Int, end: Int) {
        guard let info = project.sample(project.program.pads[pad].layers[layer].sampleID) else { return }
        let s = max(0, min(start, info.frames - 2))
        let e = max(s + 2, min(end, info.frames))
        updatePad(pad, label: "Trim", key: "trim-\(pad)-\(layer)") {
            $0.layers[layer].start = s
            $0.layers[layer].end = e == info.frames ? nil : e
        }
    }

    /// XY pad moves: a performance gesture, so no undo step per move.
    public func setXY(_ body: (inout XYSettings) -> Void) {
        body(&project.mixer.xy)
        send(.xy(project.mixer.xy))
    }

    public func setMixer(_ body: (inout SamplerMixer) -> Void) {
        var m = project.mixer
        body(&m)
        guard m != project.mixer else { return }
        checkpoint("Mixer", key: "mixer")
        project.mixer = m
        send(.mixer(project.mixer))
        onChange(project)
    }

    public func replaceProject(_ p: SamplerProject) {
        if transport.recording != nil { endTake() }
        project = p
        history.clear()
        send(.stopAll)
        for i in project.program.pads.indices { send(.pad(i, project.program.pads[i])) }
        send(.mixer(project.mixer))
        send(.clips(project.clips, beatsPerBar: project.sequence.beatsPerBar))
        send(.sequence(project.sequence))
    }
}
