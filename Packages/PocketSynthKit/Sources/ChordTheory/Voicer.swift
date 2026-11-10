/// How many tones of the chord sound (the `Voice` setting).
public enum VoiceCount: Int, CaseIterable, Codable, Sendable {
    case eight = 8, four = 4, two = 2, one = 1

    /// Max chord tones (bass excluded). `.eight` = all tones with stereo partners.
    public var toneLimit: Int {
        switch self {
        case .eight: 5
        case .four: 4
        case .two: 2
        case .one: 1
        }
    }

    public var label: String { "\(rawValue) OSC" }
}

public enum BassMode: String, CaseIterable, Codable, Sendable {
    case off, root, slash

    public var label: String { rawValue.uppercased() }
}

public enum Inversion: Int, CaseIterable, Codable, Sendable {
    case root, first, second

    public var next: Inversion { Inversion(rawValue: (rawValue + 1) % 3)! }

    public var label: String { ["ROOT", "1ST INV", "2ND INV"][rawValue] }
}

/// A concrete, playable chord: MIDI notes plus an optional bass note.
public struct Voicing: Hashable, Codable, Sendable {
    public var notes: [Int]
    public var bass: Int?
    public var chord: Chord
    public var name: String

    public init(notes: [Int], bass: Int?, chord: Chord, name: String) {
        self.notes = notes
        self.bass = bass
        self.chord = chord
        self.name = name
    }

    /// Every note that should sound, bass included.
    public var allNotes: [Int] { (bass.map { [$0] } ?? []) + notes }
}

public struct VoicingRequest: Sendable {
    public var chord: Chord
    /// MIDI note of the chord root before octave shifting.
    public var rootNote: Int
    public var inversion: Inversion = .root
    /// Total octave shift (global + per pad).
    public var octaveShift: Int = 0
    public var voiceCount: VoiceCount = .eight
    public var bassMode: BassMode = .off
    /// Slash chord: the bass pad's root note (MIDI, before shifting). Overrides `bassMode`.
    public var slashBassNote: Int?
    public var legacyNinthVoicing = false
    public var spelling: NoteSpelling = .sharps
    /// When set, voice leading picks the inversion closest to these notes.
    public var voiceLeadFrom: [Int]?

    public init(chord: Chord, rootNote: Int) {
        self.chord = chord
        self.rootNote = rootNote
    }
}

public enum Voicer {
    public static let playableRange = 40...88

    public static func voice(_ r: VoicingRequest) -> Voicing {
        let shift = 12 * r.octaveShift
        let root = r.rootNote + shift

        // 1. Chord tones in chord-tone order.
        var intervals = r.chord.type.intervals
        if r.legacyNinthVoicing {
            // Legacy 9th voicing: drop the 5th and double the 3rd an octave up.
            intervals.removeAll { $0 == 7 }
            intervals.append(intervals[1] + 12)
        }
        intervals = limit(intervals, to: r.voiceCount.toneLimit)
        let rootPosition = intervals.map { root + $0 }

        // 2. Inversion, or voice leading.
        let notes: [Int]
        if let previous = r.voiceLeadFrom, !previous.isEmpty, rootPosition.count > 1 {
            notes = closestVoicing(to: previous, rootPosition: rootPosition)
        } else {
            notes = invert(rootPosition, r.inversion.rawValue)
        }

        // 3. Bass.
        var bass: Int?
        var name = r.chord.name(spelling: r.spelling)
        if let slash = r.slashBassNote {
            bass = slash + shift - 24
            name += "/" + PitchName.name(slash, spelling: r.spelling)
        } else {
            switch r.bassMode {
            case .off:
                break
            case .root:
                bass = root - 24
            case .slash:
                let tones = r.chord.type.intervals
                // 5th; 3rd on minor; the suspended tone on sus chords (SYNTH_SPEC §2).
                let interval = switch r.chord.type.family {
                case .minor, .suspended: tones[1]
                default: tones[2]
                }
                bass = root + interval - 24
                name += "/" + PitchName.name(root + interval, spelling: r.spelling)
            }
        }
        return Voicing(notes: notes, bass: bass, chord: r.chord, name: name)
    }

    /// Drops the perfect 5th first, then the highest extensions, until `limit` tones remain.
    static func limit(_ intervals: [Int], to limit: Int) -> [Int] {
        var result = intervals
        while result.count > limit {
            if result.count > 2, let i = result.firstIndex(of: 7) {
                result.remove(at: i)
            } else {
                result.removeLast()
            }
        }
        return result
    }

    /// Moves the lowest `count` notes up an octave.
    static func invert(_ notes: [Int], _ count: Int) -> [Int] {
        var result = notes
        for _ in 0..<min(count, max(notes.count - 1, 0)) {
            let low = result.removeFirst()
            result.append(low + 12)
        }
        return result
    }

    /// Picks the inversion/octave of the chord that moves least from `previous`.
    static func closestVoicing(to previous: [Int], rootPosition: [Int]) -> [Int] {
        let center = Double(rootPosition.reduce(0, +)) / Double(rootPosition.count)
        var best = rootPosition
        var bestCost = Double.infinity
        for inversion in 0..<rootPosition.count {
            for octave in [-1, 0, 1] {
                let candidate = invert(rootPosition, inversion).map { $0 + 12 * octave }
                guard candidate.allSatisfy(playableRange.contains) else { continue }
                let mean = Double(candidate.reduce(0, +)) / Double(candidate.count)
                // Small pull toward the root-position register to stop gradual drift.
                let cost = movement(previous, candidate) + 0.1 * abs(mean - center)
                if cost < bestCost - 1e-9 {
                    bestCost = cost
                    best = candidate
                }
            }
        }
        return best
    }

    /// Voice-leading distance between two note sets.
    static func movement(_ a: [Int], _ b: [Int]) -> Double {
        if a.count == b.count {
            return Double(zip(a.sorted(), b.sorted()).map { abs($0 - $1) }.reduce(0, +))
        }
        func nearest(_ from: [Int], _ to: [Int]) -> Int {
            from.map { n in to.map { abs($0 - n) }.min() ?? 0 }.reduce(0, +)
        }
        return Double(nearest(a, b) + nearest(b, a)) / 2
    }
}
