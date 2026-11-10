/// Static option lists: modes, sounds, envelopes, effects and per-mode parameters.

public enum SynthMode: String, CaseIterable, Codable, Sendable {
    case play, strum, lead, drone, arp, `repeat`, seq, drums, beat
    case game, trainer, tuner, mic, mixer

    public var label: String { rawValue.uppercased() }

    /// Tools that only start when confirmed (M press or click), not while browsing.
    public var needsConfirm: Bool {
        switch self {
        case .game, .trainer, .tuner, .mic, .mixer: true
        default: false
        }
    }

    /// M + pad quick select.
    public static func quickSelect(pad: Int) -> SynthMode? {
        let modes: [SynthMode] = [.play, .strum, .lead, .drone, .arp, .repeat, .mic]
        return (1...7).contains(pad) ? modes[pad - 1] : nil
    }

    /// Modes where holding one pad then pressing another makes a slash chord.
    public var supportsSlashChords: Bool {
        [.play, .strum, .drone, .arp, .repeat].contains(self)
    }
}

public enum SoundEngineKind: String, Codable, Sendable {
    case analog, fm, sample, noise, hybrid
}

public struct SoundInfo: Hashable, Sendable {
    public let name: String
    public let engine: SoundEngineKind
    public let defaultEnvelope: EnvelopePreset
}

public enum SoundCatalog {
    /// Built-in browse list. Our own names; sample sounds need our own samples.
    public static let builtIn: [SoundInfo] = [
        .init(name: "Saw", engine: .analog, defaultEnvelope: .short),
        .init(name: "Saw Bass", engine: .analog, defaultEnvelope: .short),
        .init(name: "Piano", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Tine EP", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Organ", engine: .sample, defaultEnvelope: .touch),
        .init(name: "Strings", engine: .sample, defaultEnvelope: .long),
        .init(name: "Horns", engine: .sample, defaultEnvelope: .touch),
        .init(name: "Brass", engine: .sample, defaultEnvelope: .touch),
        .init(name: "E Guitar", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Clarinet", engine: .sample, defaultEnvelope: .touch),
        .init(name: "Flute", engine: .sample, defaultEnvelope: .touch),
        .init(name: "Grand", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Retro EP", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Choir Ah", engine: .sample, defaultEnvelope: .long),
        .init(name: "Vibes", engine: .fm, defaultEnvelope: .keys),
        .init(name: "FM EP", engine: .fm, defaultEnvelope: .keys),
        .init(name: "Acoustic", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Harp", engine: .sample, defaultEnvelope: .keys),
        .init(name: "Reed Organ", engine: .sample, defaultEnvelope: .touch),
        .init(name: "Hum Choir", engine: .sample, defaultEnvelope: .long),
        .init(name: "Sine", engine: .analog, defaultEnvelope: .short),
        .init(name: "FM Sweep", engine: .fm, defaultEnvelope: .swell),
        .init(name: "Synth Bass", engine: .sample, defaultEnvelope: .short),
        .init(name: "Click Perc", engine: .sample, defaultEnvelope: .pluck),
        .init(name: "Triangle", engine: .analog, defaultEnvelope: .short),
        .init(name: "Square", engine: .analog, defaultEnvelope: .short),
        .init(name: "Saw+Square", engine: .hybrid, defaultEnvelope: .short),
        .init(name: "Sea Pad", engine: .hybrid, defaultEnvelope: .long),
    ]

    /// Not in the browse list: FM Piano (quick select only), Wind (randomize only).
    public static let fmPiano = SoundInfo(name: "FM Piano", engine: .fm, defaultEnvelope: .keys)
    public static let wind = SoundInfo(name: "Wind", engine: .noise, defaultEnvelope: .long)

    public static var all: [SoundInfo] { builtIn + [fmPiano, wind] }
    public static var fmPianoIndex: Int { builtIn.count }
    public static var windIndex: Int { builtIn.count + 1 }

    /// S + pad quick select: Saw, Sine, FM EP, FM Piano, Strings, Clarinet, FM Sweep.
    public static func quickSelect(pad: Int) -> Int? {
        func index(_ name: String) -> Int { builtIn.firstIndex { $0.name == name }! }
        switch pad {
        case 1: return index("Saw")
        case 2: return index("Sine")
        case 3: return index("FM EP")
        case 4: return fmPianoIndex
        case 5: return index("Strings")
        case 6: return index("Clarinet")
        case 7: return index("FM Sweep")
        default: return nil
        }
    }
}

public struct Envelope: Hashable, Codable, Sendable {
    public var attackMs: Double
    public var decayMs: Double
    public var sustain: Double // 0...1
    public var releaseMs: Double

    public init(attackMs: Double, decayMs: Double, sustain: Double, releaseMs: Double) {
        self.attackMs = attackMs
        self.decayMs = decayMs
        self.sustain = sustain
        self.releaseMs = releaseMs
    }
}

public enum EnvelopePreset: String, CaseIterable, Codable, Sendable {
    case long, short, swell, pluck, touch, sustain, keys

    public var label: String { rawValue.uppercased() }

    public var envelope: Envelope {
        switch self {
        case .long: Envelope(attackMs: 800, decayMs: 1000, sustain: 0.70, releaseMs: 2000)
        case .short: Envelope(attackMs: 100, decayMs: 100, sustain: 1.00, releaseMs: 1000)
        case .swell: Envelope(attackMs: 800, decayMs: 300, sustain: 0.80, releaseMs: 2000)
        case .pluck: Envelope(attackMs: 5, decayMs: 80, sustain: 0.00, releaseMs: 180)
        case .touch: Envelope(attackMs: 25, decayMs: 260, sustain: 0.66, releaseMs: 50)
        case .sustain: Envelope(attackMs: 200, decayMs: 300, sustain: 0.85, releaseMs: 3000)
        case .keys: Envelope(attackMs: 5, decayMs: 1200, sustain: 0.55, releaseMs: 700)
        }
    }
}

/// Effects in the synth's fixed chain. Each stores an option index (0 = OFF).
public enum FXKind: String, CaseIterable, Codable, Sendable {
    case reverb, delay, chorus, flanger, drive, tape, tremolo, lfo, filter, vocoder

    public var label: String { rawValue.uppercased() }

    public var options: [String] {
        switch self {
        case .reverb: ["OFF", "ROOM", "HALL", "PLATE", "SPRING", "AMBIENT", "LEGACY"]
        case .delay, .tremolo: ["OFF", "1/4", "1/8", "1/16", "1/16T", "1/32"]
        case .chorus: ["OFF", "LIGHT", "WARM", "WIDE", "LUSH"]
        case .flanger: ["OFF", "SLOW", "JET", "DEEP", "METAL"]
        case .drive: ["OFF", "TUBE", "DRIVE", "DIST", "FUZZ"]
        case .tape: ["OFF", "LOFI", "VINYL", "TAPE"]
        case .lfo: ["OFF", "LOW", "MEDIUM", "HIGH"]
        case .filter: ["OFF", "ON"]
        case .vocoder: ["OFF", "MIC", "LOOP"]
        }
    }
}

public enum Glide: String, CaseIterable, Codable, Sendable {
    case off, short, medium, long
    public var label: String { rawValue.uppercased() }
}

public enum StrumSpeed: String, CaseIterable, Codable, Sendable {
    case slow, medium, fast
    public var label: String { ["SLO", "MED", "FST"][Self.allCases.firstIndex(of: self)!] }
    public var stepMs: Double { [200, 80, 40][Self.allCases.firstIndex(of: self)!] }
}

public enum ArpPattern: String, CaseIterable, Codable, Sendable {
    case up, down, upDown, downUp, random
    public var label: String { ["UP", "DOWN", "UP/DN", "DN/UP", "RAND"][Self.allCases.firstIndex(of: self)!] }
}

public enum ArpLayer: String, CaseIterable, Codable, Sendable {
    case arpOnly, chordArp, rhythmArp
    public var label: String { ["ARP ONLY", "CHORD+ARP", "RHYTHM+ARP"][Self.allCases.firstIndex(of: self)!] }
}

/// Tempo-synced rates shared by Arp and Repeat (Repeat adds `stutter`).
public enum RhythmRate: String, CaseIterable, Codable, Sendable {
    case whole, half, quarter, eighth, sixteenth, sixteenthTriplet, thirtySecond
    case swing8, swing16, stutter

    public var label: String {
        ["1/1", "1/2", "1/4", "1/8", "1/16", "1/16T", "1/32", "S8", "S16", "STUT"][
            Self.allCases.firstIndex(of: self)!]
    }

    /// Note length in beats (swing rates use their straight value).
    public var beats: Double {
        switch self {
        case .whole: 4
        case .half: 2
        case .quarter: 1
        case .eighth, .swing8: 0.5
        case .sixteenth, .swing16, .stutter: 0.25
        case .sixteenthTriplet: 1.0 / 6
        case .thirtySecond: 0.125
        }
    }

    /// Swing for the engine grid (0.5 = straight).
    public var swing: Double {
        switch self {
        case .swing8, .swing16: 0.62
        default: 0.5
        }
    }

    public static let arpRates: [RhythmRate] = allCases.filter { $0 != .stutter }
    /// Chord sequencer step lengths (↑ on page 1 cycles them).
    public static let seqRates: [RhythmRate] = [.whole, .half, .quarter, .eighth, .sixteenth]
}
