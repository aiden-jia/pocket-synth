import ChordTheory

/// A keygroup program (SAMPLER_SPEC §3.2): samples spread across the keyboard, each
/// zone pitched from its root note.
public struct KeygroupZone: Hashable, Codable, Sendable {
    public var lowNote = 0
    public var highNote = 127
    public var rootNote = 60
    public var layers: [PadLayer] = [PadLayer()]

    public init(lowNote: Int = 0, highNote: Int = 127, rootNote: Int = 60, sample: SampleID? = nil) {
        self.lowNote = lowNote
        self.highNote = highNote
        self.rootNote = rootNote
        layers = [PadLayer(sampleID: sample)]
    }

    public var primarySample: SampleID? { layers.first?.sampleID }
}

public struct KeygroupProgram: Hashable, Codable, Sendable {
    public static let maxZones = 32
    public static let maxPrograms = 8

    public var name: String
    public var zones: [KeygroupZone] = []
    public var envelope = PadEnvelope(attackMs: 2, holdMs: 0, decayMs: 0, sustain: 1, releaseMs: 250)
    public var level = 1.0
    public var pan = 0.0
    public var mono = false

    public init(name: String) { self.name = name }

    /// Auto-map (SAMPLER_SPEC §3.2): sorts samples by their root note and gives each the
    /// keys up to halfway to its neighbours; the lowest and highest reach the ends.
    public static func autoMap(name: String, samples: [(id: SampleID, root: Int)]) -> KeygroupProgram {
        var p = KeygroupProgram(name: name)
        let sorted = samples.prefix(maxZones).sorted { $0.root < $1.root }
        for (i, s) in sorted.enumerated() {
            let lo = i == 0 ? 0 : (sorted[i - 1].root + s.root) / 2 + 1
            let hi = i == sorted.count - 1 ? 127 : (s.root + sorted[i + 1].root) / 2
            p.zones.append(KeygroupZone(lowNote: lo, highNote: max(lo, hi), rootNote: s.root, sample: s.id))
        }
        return p
    }

    public func zone(for note: Int) -> KeygroupZone? {
        zones.first { note >= $0.lowNote && note <= $0.highNote }
    }
}

/// Pad Perform (SAMPLER_SPEC §2): on a note track the 16 pads play notes.
public struct PadPerform: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case chromatic, scale
        public var label: String { self == .chromatic ? "Chromatic" : "Scale" }
    }

    public var mode: Mode = .chromatic
    /// Pitch class of pad 1.
    public var root = 0
    public var scale: Scale = .major
    /// Octave of pad 1 (3 → C3 = MIDI 48).
    public var octave = 3

    public init() {}

    public var baseNote: Int { 12 * (octave + 1) + root }

    /// The note grid pad `g` plays (pad 1 = bottom-left).
    public func note(_ g: Int) -> Int {
        switch mode {
        case .chromatic:
            return min(127, baseNote + g)
        case .scale:
            let iv = scale.intervals
            return min(127, baseNote + 12 * (g / iv.count) + iv[g % iv.count])
        }
    }
}
