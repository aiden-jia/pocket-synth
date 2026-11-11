public enum ChordFamily: String, Codable, Sendable {
    case major, minor, diminished, augmented, suspended
}

/// The 26 chord types the synth can produce (SYNTH_SPEC §2.2).
public enum ChordType: String, CaseIterable, Codable, Sendable {
    case major, minor, diminished, diminished7, augmented, sus4, sus2
    case major7, minor7, dominant7, major6, minor6
    case major9, minor9, dominant7sharp9, halfDiminished7, dominant9
    case add9, add11, minor11, dominant7sus4, minorMajor7, major13, sixNine
    case dominant7flat9, dominant7alt

    /// Semitones above the root, in chord-tone order (root, 3rd, 5th, 7th, extensions).
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .diminished: [0, 3, 6]
        case .diminished7: [0, 3, 6, 9]
        case .augmented: [0, 4, 8]
        case .sus4: [0, 5, 7]
        case .sus2: [0, 2, 7]
        case .major7: [0, 4, 7, 11]
        case .minor7: [0, 3, 7, 10]
        case .dominant7: [0, 4, 7, 10]
        case .major6: [0, 4, 7, 9]
        case .minor6: [0, 3, 7, 9]
        case .major9: [0, 4, 7, 11, 14]
        case .minor9: [0, 3, 7, 10, 14]
        case .dominant7sharp9: [0, 4, 7, 10, 15]
        case .halfDiminished7: [0, 3, 6, 10]
        case .dominant9: [0, 4, 7, 10, 14]
        case .add9: [0, 4, 7, 14]
        case .add11: [0, 4, 7, 17]
        case .minor11: [0, 3, 7, 10, 17]
        case .dominant7sus4: [0, 5, 7, 10]
        case .minorMajor7: [0, 3, 7, 11]
        case .major13: [0, 4, 11, 14, 21] // 5th dropped to fit the 5-tone budget
        case .sixNine: [0, 4, 7, 9, 14]
        case .dominant7flat9: [0, 4, 7, 10, 13]
        case .dominant7alt: [0, 4, 8, 10, 15] // ♯5 ♯9 (SYNTH_SPEC §2.2)
        }
    }

    public var suffix: String {
        switch self {
        case .major: ""
        case .minor: "m"
        case .diminished: "°"
        case .diminished7: "°7"
        case .augmented: "+"
        case .sus4: "sus4"
        case .sus2: "sus2"
        case .major7: "maj7"
        case .minor7: "m7"
        case .dominant7: "7"
        case .major6: "6"
        case .minor6: "m6"
        case .major9: "maj9"
        case .minor9: "m9"
        case .dominant7sharp9: "7♯9"
        case .halfDiminished7: "ø7"
        case .dominant9: "9"
        case .add9: "add9"
        case .add11: "add11"
        case .minor11: "m11"
        case .dominant7sus4: "7sus4"
        case .minorMajor7: "m(maj7)"
        case .major13: "maj13"
        case .sixNine: "6/9"
        case .dominant7flat9: "7♭9"
        case .dominant7alt: "7alt"
        }
    }

    public var family: ChordFamily {
        switch self {
        case .minor, .minor7, .minor6, .minor9, .minor11, .minorMajor7: .minor
        case .diminished, .diminished7, .halfDiminished7: .diminished
        case .augmented: .augmented
        case .sus4, .sus2, .dominant7sus4: .suspended
        default: .major
        }
    }

    /// True for the 9th chords whose voicing differs in the legacy ("OG") stick mode.
    public var isNinthChord: Bool { self == .major9 || self == .minor9 || self == .dominant9 }
}

public struct Chord: Hashable, Codable, Sendable {
    public var root: Int // pitch class
    public var type: ChordType

    public init(root: Int, type: ChordType) {
        self.root = mod12(root)
        self.type = type
    }

    public func name(spelling: NoteSpelling = .sharps) -> String {
        PitchName.name(root, spelling: spelling) + type.suffix
    }

    public var pitchClasses: Set<Int> { Set(type.intervals.map { mod12(root + $0) }) }
}
