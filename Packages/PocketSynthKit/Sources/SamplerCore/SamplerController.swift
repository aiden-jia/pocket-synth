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
    case main, grid, sample, edit, program, mixer

    public var label: String {
        switch self {
        case .main: "Main"
        case .grid: "Grid"
        case .sample: "Sample"
        case .edit: "Edit"
        case .program: "Pad"
        case .mixer: "Mixer"
        }
    }
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

    public var label: String {
        switch self {
        case .pads: "Slices → pads"
        case .samples: "Extract new samples"
        case .sequence: "Pads + sequence"
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
    /// Ticks inside the sequence; negative during the count-in.
    public var position = 0.0
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
    public var recordMode: RecordMode = .overdub
    public private(set) var history = UndoHistory<SamplerProject>()

    @ObservationIgnored public var send: (SamplerCommand) -> Void
    /// Called after every project change (persistence hooks in here).
    @ObservationIgnored public var onChange: (SamplerProject) -> Void = { _ in }
    /// Clock for undo coalescing (seconds).
    @ObservationIgnored public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    @ObservationIgnored private var heldGrid: [Int: (pad: Int, tune: Double)] = [:]
    @ObservationIgnored private var erasePads: Set<Int> = []
    @ObservationIgnored private var eraseCheckpointed = false
    @ObservationIgnored private var take: TakeRecorder?
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
        send(.beatsPerBar(project.sequence.beatsPerBar))
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

    public func play() {
        guard !transport.playing else { return }
        transport.playing = true
        transport.position = 0
        send(.transport(playing: true, startTick: 0, countInBeats: 0))
    }

    public func stop() {
        if transport.recording != nil { endTake() }
        transport.playing = false
        transport.position = 0
        send(.transport(playing: false, startTick: 0, countInBeats: 0))
    }

    /// Record: from stop it starts with the count-in; while playing it punches in.
    /// Pressing it again while recording punches out and keeps playing.
    public func record() {
        if transport.recording != nil {
            endTake()
            return
        }
        beginTake()
        if !transport.playing {
            transport.playing = true
            let countIn = transport.countInBars * project.sequence.beatsPerBar
            transport.position = Double(-countIn * PPQN.ticks)
            send(.transport(playing: true, startTick: 0, countInBeats: countIn))
        }
    }

    public func setMetronome(_ on: Bool) {
        transport.metronome = on
        send(.metronome(on))
    }

    public func setCountIn(bars: Int) { transport.countInBars = max(0, min(2, bars)) }

    private func beginTake() {
        takeBefore = project
        take = TakeRecorder()
        transport.recording = recordMode
        let tc = project.timingCorrect
        send(.recording(true, guardTicks: tc.onInput ? tc.value.ticks / 2 : 60))
    }

    private func endTake() {
        guard var t = take else { return }
        var seq = project.sequence
        t.finish(at: max(0, Int(transport.position)), in: &seq, track: 0)
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
    public func poll(hits: [RecordedHit], position: Double, enginePlaying: Bool) {
        let previous = transport.position
        if transport.playing { transport.position = position }
        var seq = project.sequence
        var changed = false

        if var t = take, !hits.isEmpty {
            let tc = project.timingCorrect
            t.ingest(hits, into: &seq, track: 0, timing: tc.onInput ? tc : nil)
            take = t
            changed = true
        }
        if transport.playing, previous >= 0, position >= 0, Int(previous) != Int(position) {
            let from = Int(previous), to = Int(position)
            if transport.recording == .replace, let t = take {
                let before = seq
                seq.erase(track: 0, from: from, to: to, keep: t.recordedIDs)
                changed = changed || before != seq
            }
            if eraseHeld, !erasePads.isEmpty {
                let before = seq
                seq.erase(track: 0, from: from, to: to, pads: erasePads, keep: take?.recordedIDs ?? [])
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
        if transport.playing, !enginePlaying, previous > 0, !project.sequence.loop { stop() }
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
        editSequence("Edit notes") { seq in
            if let i = seq.tracks[0].events.firstIndex(where: { $0.pad == pad && $0.tick >= tick && $0.tick < tick + span }) {
                seq.tracks[0].events.remove(at: i)
            } else {
                seq.add(tick: tick, length: span, pad: pad, velocity: velocity)
            }
        }
    }

    public func moveEvent(_ id: UInt32, toTick tick: Int, pad: Int? = nil) {
        editSequence("Move note", key: "move-\(id)") { seq in
            guard let i = seq.tracks[0].events.firstIndex(where: { $0.id == id }) else { return }
            let len = seq.lengthTicks
            seq.tracks[0].events[i].tick = ((tick % len) + len) % len
            if let pad { seq.tracks[0].events[i].pad = pad }
            seq.sortEvents(track: 0)
        }
    }

    public func setVelocity(_ id: UInt32, _ v: Int) {
        editSequence("Velocity", key: "velocity-\(id)") { seq in
            guard let i = seq.tracks[0].events.firstIndex(where: { $0.id == id }) else { return }
            seq.tracks[0].events[i].velocity = max(1, min(127, v))
        }
    }

    public func deleteEvent(_ id: UInt32) {
        editSequence("Delete note") { $0.tracks[0].events.removeAll { $0.id == id } }
    }

    /// Applies Timing Correct to every note of the track.
    public func quantizeTrack() {
        let tc = project.timingCorrect
        editSequence("Quantize") { seq in
            let len = seq.lengthTicks
            for i in seq.tracks[0].events.indices {
                seq.tracks[0].events[i].tick = ((tc.apply(seq.tracks[0].events[i].tick) % len) + len) % len
            }
            seq.sortEvents(track: 0)
        }
    }

    public func clearTrack() { editSequence("Clear track") { $0.tracks[0].events.removeAll() } }

    public func setBars(_ n: Int) { editSequence("Length") { $0.setBars(n) } }

    public func doubleSequence() { editSequence("Double") { $0.double() } }

    public func setLoop(_ on: Bool) { editSequence("Loop") { $0.loop = on } }

    public func setTrackMute(_ on: Bool) { editSequence("Mute") { $0.tracks[0].mute = on } }

    /// Switches sequence (creating it, with the current length, if it's new).
    public func selectSequence(_ index: Int) {
        guard (0..<SamplerProject.maxSequences).contains(index), index != project.currentSequence else { return }
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
        if project.sequence != old.sequence || project.currentSequence != old.currentSequence {
            send(.sequence(project.sequence))
        }
        if project.timingCorrect != old.timingCorrect, noteRepeat { sendNoteRepeat() }
        selectedPad = min(selectedPad, DrumProgram.padCount - 1)
        onChange(project)
    }

    // MARK: - Chop, processes, sample versions

    /// Samples to list: everything not archived, plus archived ones a pad still uses.
    public var visibleSamples: [SampleInfo] {
        let used = Set(project.program.pads.flatMap { $0.layers.compactMap(\.sampleID) })
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
        onChange(project)
    }

    /// Archived samples no pad uses (their files can go). Clears undo history.
    public func discardUnused() -> [SampleInfo] {
        let used = Set(project.program.pads.flatMap { $0.layers.compactMap(\.sampleID) })
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
        send(.sequence(project.sequence))
    }
}
