/// The 8 joystick directions, clockwise from up.
public enum StickDirection: Int, CaseIterable, Codable, Sendable {
    case up, upRight, right, downRight, down, downLeft, left, upLeft

    public var arrow: String { ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"][rawValue] }

    /// Cardinal-only view used by menus (diagonals are ignored there).
    public var isCardinal: Bool { rawValue % 2 == 0 }
}

/// Joystick chord-modification modes (SYNTH_SPEC §2.1).
public enum StickMode: String, CaseIterable, Codable, Sendable {
    case standard, extended, chromatic, borrow, legacy

    public var shortName: String {
        switch self {
        case .standard: "STD"
        case .extended: "EXT"
        case .chromatic: "CHROM"
        case .borrow: "BORROW"
        case .legacy: "OG"
        }
    }
}

/// The result of pushing the stick while a pad is held.
public struct ChordModification: Equatable, Sendable {
    /// Semitones to move the chord root (BORROW / CHROM modes).
    public var rootShift: Int
    public var type: ChordType
    /// OG mode: 9th chords use the legacy voicing (doubled 3rd on top).
    public var legacyNinthVoicing: Bool
    /// Spell the resulting root with flats (borrowed flat-side / tritone chords).
    public var prefersFlats: Bool
}

public enum StickModifier {
    /// One row of a mode table.
    enum Rule {
        case set(ChordType)
        case byFamily(major: ChordType, minor: ChordType, diminished: ChordType,
                      augmented: ChordType, suspended: ChordType)
        case shiftKeepingType(Int)
        case shift(Int, to: ChordType)
    }

    // Maj↔min flip. Dim and aug have no "flipped" type in the vocabulary, so they go
    // to the nearest triad with the other third (a choice; the source is silent).
    static let flip = Rule.byFamily(major: .minor, minor: .major, diminished: .major,
                                    augmented: .minor, suspended: .major)

    /// Tables are indexed by `StickDirection.rawValue`: ↑ ↗ → ↘ ↓ ↙ ← ↖
    static let standard: [Rule] = [
        flip,
        .set(.dominant7),
        .byFamily(major: .major7, minor: .minor7, diminished: .halfDiminished7,
                  augmented: .major7, suspended: .dominant7sus4),
        .byFamily(major: .major9, minor: .minor9, diminished: .halfDiminished7,
                  augmented: .major9, suspended: .dominant9),
        .set(.sus4),
        .byFamily(major: .major6, minor: .sus2, diminished: .sus2,
                  augmented: .major6, suspended: .sus2),
        .byFamily(major: .diminished, minor: .diminished, diminished: .minor,
                  augmented: .diminished, suspended: .diminished),
        .byFamily(major: .augmented, minor: .augmented, diminished: .augmented,
                  augmented: .major, suspended: .augmented),
    ]

    static let extended: [Rule] = [
        flip,
        .set(.dominant9),
        .set(.add11),
        .set(.minor11),
        .set(.dominant7sharp9),
        .set(.add9),
        .set(.dominant7sus4),
        .set(.halfDiminished7),
    ]

    static let chromatic: [Rule] = [
        .set(.minorMajor7),
        .set(.dominant7alt),
        .shiftKeepingType(+1),
        .set(.halfDiminished7),
        .set(.major13),
        .set(.sixNine),
        .shiftKeepingType(-1),
        .set(.dominant7flat9),
    ]

    static let borrow: [Rule] = [
        .set(.dominant7),                 // secondary dominant
        .shift(-2, to: .dominant7),       // backdoor dominant
        .shift(+1, to: .diminished7),     // passing diminished
        .set(.halfDiminished7),
        flip,                             // parallel major/minor
        .byFamily(major: .minor7, minor: .major7, diminished: .major7,
                  augmented: .minor7, suspended: .minor7), // borrowed 7ths
        .shift(-1, to: .major),           // flat-side major
        .shift(+6, to: .dominant7),       // tritone substitute
    ]

    static func table(for mode: StickMode) -> [Rule] {
        switch mode {
        case .standard, .legacy: standard
        case .extended: extended
        case .chromatic: chromatic
        case .borrow: borrow
        }
    }

    /// Applies the stick to a base chord type. `nil` direction returns the chord unchanged.
    public static func apply(_ direction: StickDirection?, mode: StickMode,
                             to base: ChordType) -> ChordModification {
        guard let direction else {
            return ChordModification(rootShift: 0, type: base, legacyNinthVoicing: false,
                                     prefersFlats: false)
        }
        var shift = 0
        let type: ChordType
        switch table(for: mode)[direction.rawValue] {
        case .set(let t):
            type = t
        case .byFamily(let maj, let min, let dim, let aug, let sus):
            switch base.family {
            case .major: type = maj
            case .minor: type = min
            case .diminished: type = dim
            case .augmented: type = aug
            case .suspended: type = sus
            }
        case .shiftKeepingType(let s):
            shift = s
            type = base
        case .shift(let s, let t):
            shift = s
            type = t
        }
        return ChordModification(
            rootShift: shift,
            type: type,
            legacyNinthVoicing: mode == .legacy && type.isNinthChord,
            prefersFlats: shift < 0 || shift == 6
        )
    }
}
