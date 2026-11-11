import ChordTheory

/// Trainer mode (SYNTH_SPEC §4): ear training in six levels, in the current key and scale.
public enum TrainerLevel: Int, CaseIterable, Codable, Sendable {
    case intervalUp = 1, intervalUpDown, triad, progression, modifiedChord, modifiedProgression

    public var label: String {
        ["INTERVAL ↑", "INTERVAL ↑↓", "TRIAD", "PROGRESSION", "MOD CHORD", "MOD PROG"][rawValue - 1]
    }

    /// Answers are single notes (the pad's root) rather than chords.
    public var isInterval: Bool { self == .intervalUp || self == .intervalUpDown }
    /// Answers need the stick (hold pad + push, judged on release).
    public var usesStick: Bool { self == .modifiedChord || self == .modifiedProgression }
    public var answerCount: Int { self == .progression || self == .modifiedProgression ? 4 : 1 }
}

/// One answer: a pad, plus a stick direction on the modified-chord levels.
public struct TrainerAnswer: Hashable, Sendable {
    public var pad: Int
    public var stick: StickDirection?

    public init(pad: Int, stick: StickDirection? = nil) {
        self.pad = pad
        self.stick = stick
    }
}

public struct TrainerQuestion: Equatable, Sendable {
    public var level: TrainerLevel
    /// What to press, in order.
    public var answers: [TrainerAnswer]
    /// Interval levels: the note asked for (the answer is any pad with that pitch class).
    public var targetNote: Int?
    /// What gets played: the key's context first, then the question.
    public var playback: [Voicing]
}

/// Question generation and scoring. Answers are compared by sound, not by pad, so two
/// modifications that make the same chord both count.
public struct EarTrainer: Sendable {
    public enum Result: Equatable, Sendable { case partial, right, wrong }

    public private(set) var level: TrainerLevel
    public private(set) var question: TrainerQuestion?
    public private(set) var given: [TrainerAnswer] = []
    public private(set) var asked = 0
    public private(set) var correct = 0
    public private(set) var streak = 0
    private var rng: SplitMix64
    private var lastPads: [Int] = []

    public init(level: TrainerLevel = .intervalUp, seed: UInt64 = 0xEA2) {
        self.level = level
        rng = SplitMix64(seed: seed)
    }

    public mutating func setLevel(_ l: TrainerLevel) {
        level = l
        question = nil
        given = []
        streak = 0
    }

    /// Makes (and keeps) a new question.
    @discardableResult
    public mutating func next(state: SynthState) -> TrainerQuestion {
        given = []
        let tonicChord = Self.chordVoicing(TrainerAnswer(pad: 1), state: state)
        let q: TrainerQuestion
        switch level {
        case .intervalUp, .intervalUpDown:
            let tonic = Self.padNote(1, state: state)
            let degree = pick(2...8)                       // 8 = the octave
            var target = degree == 8 ? tonic + 12 : Self.padNote(degree, state: state)
            if target <= tonic { target += 12 }
            if level == .intervalUpDown, Bool.random(using: &rng) { target -= 12 }
            q = TrainerQuestion(level: level, answers: [TrainerAnswer(pad: degree == 8 ? 1 : degree)],
                                targetNote: target,
                                playback: [Self.noteVoicing(tonic), Self.noteVoicing(target)])
        case .triad:
            let pad = pick(1...7)
            q = TrainerQuestion(level: level, answers: [TrainerAnswer(pad: pad)], targetNote: nil,
                                playback: [tonicChord, Self.chordVoicing(TrainerAnswer(pad: pad), state: state)])
        case .modifiedChord:
            let a = TrainerAnswer(pad: pick(1...7), stick: StickDirection.allCases.randomElement(using: &rng))
            q = TrainerQuestion(level: level, answers: [a], targetNote: nil,
                                playback: [tonicChord, Self.chordVoicing(a, state: state)])
        case .progression, .modifiedProgression:
            var answers = [TrainerAnswer(pad: 1)]
            while answers.count < 4 {
                var a = TrainerAnswer(pad: pick(2...7))
                if a.pad == answers.last?.pad { continue }
                if level == .modifiedProgression, Bool.random(using: &rng) {
                    a.stick = StickDirection.allCases.randomElement(using: &rng)
                }
                answers.append(a)
            }
            q = TrainerQuestion(level: level, answers: answers, targetNote: nil,
                                playback: answers.map { Self.chordVoicing($0, state: state) })
        }
        question = q
        return q
    }

    /// Records an answer. nil when there's no open question.
    public mutating func answer(_ a: TrainerAnswer, state: SynthState) -> Result? {
        guard let q = question, given.count < q.answers.count else { return nil }
        let i = given.count
        given.append(a)
        let ok: Bool
        if let target = q.targetNote {
            ok = mod12(Self.padNote(a.pad, state: state)) == mod12(target)
        } else {
            ok = Self.sameSound(q.answers[i], a, state: state)
        }
        if !ok {
            finish(right: false)
            return .wrong
        }
        if given.count < q.answers.count { return .partial }
        finish(right: true)
        return .right
    }

    private mutating func finish(right: Bool) {
        asked += 1
        if right { correct += 1; streak += 1 } else { streak = 0 }
        question = nil
    }

    /// What a pad plays when it's pressed as an answer (and when the answer is revealed).
    public static func answerVoicing(_ a: TrainerAnswer, level: TrainerLevel, state: SynthState) -> Voicing {
        level.isInterval ? noteVoicing(padNote(a.pad, state: state)) : chordVoicing(a, state: state)
    }

    /// Names of the expected answers, for the reveal.
    public static func names(_ q: TrainerQuestion, state: SynthState) -> [String] {
        if let t = q.targetNote { return [PitchName.name(t, spelling: state.key.spelling)] }
        return q.answers.map { chordVoicing($0, state: state).name }
    }

    // MARK: Helpers

    /// The pad's root note at the current global octave (Trainer uses no per-pad shifts).
    static func padNote(_ pad: Int, state: SynthState) -> Int {
        ChordResolver.baseChord(pad: pad, state: state).rootNote + 12 * state.globalOctave
    }

    static func chordVoicing(_ a: TrainerAnswer, state: SynthState) -> Voicing {
        var s = state
        s.mode = .trainer
        s.padInversion = Array(repeating: .root, count: 7)
        s.padOctave = Array(repeating: 0, count: 7)
        s.locks = [:]
        s.voiceLeading = false
        return ChordResolver.voicing(pad: a.pad, state: s, stick: a.stick)
    }

    static func noteVoicing(_ note: Int) -> Voicing {
        Voicing(notes: [note], bass: nil, chord: Chord(root: note, type: .major), name: PitchName.noteName(note))
    }

    static func sameSound(_ a: TrainerAnswer, _ b: TrainerAnswer, state: SynthState) -> Bool {
        let x = chordVoicing(a, state: state), y = chordVoicing(b, state: state)
        return x.chord.root == y.chord.root && Set(x.notes.map(mod12)) == Set(y.notes.map(mod12))
    }

    /// A random value, avoiding a repeat of the last question's first answer.
    private mutating func pick(_ r: ClosedRange<Int>) -> Int {
        var v = Int.random(in: r, using: &rng)
        if v == lastPads.last { v = Int.random(in: r, using: &rng) }
        lastPads = [v]
        return v
    }
}
