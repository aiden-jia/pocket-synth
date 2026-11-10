/// Pitch-class helpers. Pitch classes are `Int` 0...11 (C = 0); notes are MIDI numbers.

@inlinable
public func mod12(_ x: Int) -> Int { ((x % 12) + 12) % 12 }

public enum NoteSpelling: String, Codable, Sendable {
    case sharps, flats
}

public enum PitchName {
    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    public static func name(_ pitchClass: Int, spelling: NoteSpelling = .sharps) -> String {
        let pc = mod12(pitchClass)
        return spelling == .sharps ? sharpNames[pc] : flatNames[pc]
    }

    /// e.g. 60 -> "C4"
    public static func noteName(_ midi: Int, spelling: NoteSpelling = .sharps) -> String {
        "\(name(midi, spelling: spelling))\(midi / 12 - 1)"
    }
}

/// A musical key: just the tonic pitch class. The scale is chosen separately.
public struct Key: Hashable, Codable, Sendable {
    public var tonic: Int

    public init(_ tonic: Int) { self.tonic = mod12(tonic) }

    public static let c = Key(0)

    /// Keys conventionally written with flats.
    public var spelling: NoteSpelling {
        [5, 10, 3, 8, 1].contains(tonic) ? .flats : .sharps
    }

    public var name: String { PitchName.name(tonic, spelling: spelling) }

    /// MIDI note of the tonic used for chord roots. Range F♯3 (54)...F♯4 (66), so all
    /// seven pads stay in a comfortable register whatever the key.
    public var tonicNote: Int { 60 + tonic - (tonic >= 7 ? 12 : 0) }

    public func transposed(by semitones: Int) -> Key { Key(tonic + semitones) }
}
