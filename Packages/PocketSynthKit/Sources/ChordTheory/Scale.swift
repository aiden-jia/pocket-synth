public enum Scale: String, CaseIterable, Codable, Sendable {
    case major, naturalMinor, harmonicMinor, melodicMinor
    case majorPentatonic, minorPentatonic, blues
    case dorian, mixolydian, lydian

    public var displayName: String {
        switch self {
        case .major: "Major"
        case .naturalMinor: "Minor"
        case .harmonicMinor: "Harm Minor"
        case .melodicMinor: "Mel Minor"
        case .majorPentatonic: "Maj Pent"
        case .minorPentatonic: "Min Pent"
        case .blues: "Blues"
        case .dorian: "Dorian"
        case .mixolydian: "Mixolydian"
        case .lydian: "Lydian"
        }
    }

    /// Semitones above the tonic.
    public var intervals: [Int] {
        switch self {
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: [0, 2, 3, 5, 7, 8, 10]
        case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor: [0, 2, 3, 5, 7, 9, 11]
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .blues: [0, 3, 5, 6, 7, 10]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
        case .lydian: [0, 2, 4, 6, 7, 9, 11]
        }
    }

    /// The 7-note scale the pads' chords are built from. Pentatonic and blues scales
    /// use a parent scale (SYNTH_SPEC §2 [DECIDE]); their own notes still drive
    /// melodic features such as Lead and random arps.
    public var chordScale: Scale {
        switch self {
        case .majorPentatonic: .major
        case .minorPentatonic, .blues: .naturalMinor
        default: self
        }
    }

    /// The diatonic triad on a scale degree (0...6), built by stacking scale thirds.
    public func triad(degree: Int) -> (rootOffset: Int, type: ChordType) {
        let s = chordScale.intervals
        precondition(s.count == 7 && (0..<7).contains(degree))
        let root = s[degree]
        let third = mod12(s[(degree + 2) % 7] - root)
        let fifth = mod12(s[(degree + 4) % 7] - root)
        let type: ChordType = switch (third, fifth) {
        case (4, 7): .major
        case (3, 7): .minor
        case (3, 6): .diminished
        case (4, 8): .augmented
        default: .major // unreachable for the supported scales
        }
        return (root, type)
    }
}

extension Key {
    /// MIDI root note for a pad's scale degree (0...6) before any octave shift.
    public func padRootNote(degree: Int, scale: Scale) -> Int {
        tonicNote + scale.chordScale.intervals[degree]
    }
}
