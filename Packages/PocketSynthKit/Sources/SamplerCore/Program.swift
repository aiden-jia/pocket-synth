import Foundation

/// Identifies a sample in the project's pool.
public struct SampleID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Metadata for an imported sample. Audio lives in `Samples/<fileName>`.
public struct SampleInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: SampleID
    public var name: String
    public var fileName: String
    public var frames: Int
    public var sampleRate: Double
    public var channels: Int
    /// Replaced by a processed version: hidden in the pool, kept so undo can go back.
    public var archived = false

    public init(id: SampleID = SampleID(), name: String, fileName: String, frames: Int,
                sampleRate: Double, channels: Int) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.frames = frames
        self.sampleRate = sampleRate
        self.channels = channels
    }

    enum CodingKeys: String, CodingKey { case id, name, fileName, frames, sampleRate, channels, archived }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SampleID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        frames = try c.decode(Int.self, forKey: .frames)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        channels = try c.decode(Int.self, forKey: .channels)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    public var duration: Double { Double(frames) / sampleRate }
}

public enum TriggerMode: String, CaseIterable, Codable, Sendable {
    case oneShot, noteOn
    public var label: String { self == .oneShot ? "One shot" : "Note on" }
}

/// One velocity layer of a pad (SAMPLER_SPEC §3.1).
public struct PadLayer: Hashable, Codable, Sendable {
    public var sampleID: SampleID?
    /// Trim in frames; `end == nil` means the sample's end.
    public var start = 0
    public var end: Int?
    /// Coarse + fine tune in semitones.
    public var tune = 0.0
    /// Linear gain, 0...2.
    public var level = 1.0
    public var pan = 0.0
    public var velocityLow = 0
    public var velocityHigh = 127
    public var reverse = false

    public init(sampleID: SampleID? = nil) { self.sampleID = sampleID }

    public func accepts(velocity: Int) -> Bool { (velocityLow...velocityHigh).contains(velocity) }
}

public struct PadEnvelope: Hashable, Codable, Sendable {
    public var attackMs = 0.0
    public var holdMs = 0.0
    /// 0 = no decay stage (level stays at 1 until the end or release).
    public var decayMs = 0.0
    public var sustain = 1.0
    public var releaseMs = 30.0

    public init() {}

    public init(attackMs: Double, holdMs: Double, decayMs: Double, sustain: Double, releaseMs: Double) {
        self.attackMs = attackMs
        self.holdMs = holdMs
        self.decayMs = decayMs
        self.sustain = sustain
        self.releaseMs = releaseMs
    }
}

public struct Pad: Hashable, Codable, Sendable {
    public static let maxLayers = 4

    public var layers: [PadLayer] = [PadLayer()]
    public var trigger: TriggerMode = .oneShot
    public var mono = false
    /// 0 = none, 1...32. Pads in the same group choke each other.
    public var muteGroup = 0
    public var envelope = PadEnvelope()
    public var level = 1.0
    public var pan = 0.0
    /// 0 = sampler main, 1…8 = submix (SAMPLER_SPEC §8).
    public var output = 0
    /// Send levels to returns 1…4.
    public var sends: [Double] = [0, 0, 0, 0]

    public init() {}

    enum CodingKeys: String, CodingKey { case layers, trigger, mono, muteGroup, envelope, level, pan, output, sends }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = try c.decodeIfPresent([PadLayer].self, forKey: .layers) ?? [PadLayer()]
        trigger = try c.decodeIfPresent(TriggerMode.self, forKey: .trigger) ?? .oneShot
        mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? false
        muteGroup = try c.decodeIfPresent(Int.self, forKey: .muteGroup) ?? 0
        envelope = try c.decodeIfPresent(PadEnvelope.self, forKey: .envelope) ?? PadEnvelope()
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 1
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        sends = try c.decodeIfPresent([Double].self, forKey: .sends) ?? [0, 0, 0, 0]
    }

    public var isEmpty: Bool { layers.allSatisfy { $0.sampleID == nil } }

    /// The sample shown for the pad (first non-empty layer).
    public var primarySample: SampleID? { layers.lazy.compactMap(\.sampleID).first }

    public func layers(forVelocity v: Int) -> [PadLayer] {
        layers.filter { $0.sampleID != nil && $0.accepts(velocity: v) }
    }
}

/// 8 banks × 16 pads. Pad index 0 is A01 (bottom-left of bank A).
public struct DrumProgram: Hashable, Codable, Sendable {
    public static let banks = 8
    public static let padsPerBank = 16
    public static let padCount = banks * padsPerBank

    public var name = "Drums 1"
    public var pads = [Pad](repeating: Pad(), count: padCount)

    public init() {}
}

public enum PadAddress {
    static let bankLetters = Array("ABCDEFGH")

    /// "A01" … "H16".
    public static func name(_ pad: Int) -> String {
        let bank = pad / DrumProgram.padsPerBank
        let number = pad % DrumProgram.padsPerBank + 1
        return "\(bankLetters[bank])\(number < 10 ? "0" : "")\(number)"
    }

    public static func bankName(_ bank: Int) -> String { String(bankLetters[bank]) }

    /// Program pad for a position in the 4×4 grid. `gridIndex` 0 = bottom-left, row-major upward.
    public static func pad(bank: Int, gridIndex: Int) -> Int { bank * DrumProgram.padsPerBank + gridIndex }

    /// Grid index for a row/column as drawn on screen (row 0 = top).
    public static func gridIndex(row: Int, column: Int) -> Int { (3 - row) * 4 + column }
}

public enum InsertType: Int, CaseIterable, Codable, Sendable {
    case none, lowpass, highpass, drive, crush
    public var label: String { ["None", "Low-pass", "High-pass", "Drive", "Crush"][rawValue] }
}

public enum ReturnType: Int, CaseIterable, Codable, Sendable {
    case off, room, hall, plate, delay8, delay4, chorus
    public var label: String { ["Off", "Room", "Hall", "Plate", "Delay 1/8", "Delay 1/4", "Chorus"][rawValue] }
}

public enum XYType: Int, CaseIterable, Codable, Sendable {
    case off, filter, echo, crush
    public var label: String { ["Off", "Filter", "Echo", "Crush"][rawValue] }
    /// What x and y do, for the pad's labels.
    public var axes: (x: String, y: String) {
        switch self {
        case .off: ("", "")
        case .filter: ("LP ← cutoff → HP", "resonance")
        case .echo: ("time", "feedback")
        case .crush: ("bits", "rate")
        }
    }
}

public struct Submix: Hashable, Codable, Sendable {
    public var level = 1.0
    public var pan = 0.0
    public var mute = false
    public var insert: InsertType = .none
    public var amount = 0.5
    public init() {}
}

public struct ReturnBus: Hashable, Codable, Sendable {
    public var type: ReturnType = .off
    public var level = 1.0
    public init(type: ReturnType = .off) { self.type = type }
}

/// XY performance FX (SAMPLER_SPEC §8): latched or held.
public struct XYSettings: Hashable, Codable, Sendable {
    public var type: XYType = .filter
    public var x = 0.5
    public var y = 0.3
    public var active = false
    public init() {}
}

public struct SamplerMixer: Hashable, Codable, Sendable {
    public static let submixCount = 8
    public static let returnCount = 4

    public var synthLevel = 1.0
    public var samplerLevel = 1.0
    public var masterLevel = 1.0
    public var submixes = Array(repeating: Submix(), count: SamplerMixer.submixCount)
    /// Returns start as room, hall, 1/8 delay and chorus (each still at send 0).
    public var returns = [ReturnBus(type: .room), ReturnBus(type: .hall), ReturnBus(type: .delay8), ReturnBus(type: .chorus)]
    public var xy = XYSettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case synthLevel, samplerLevel, masterLevel, submixes, returns, xy }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        synthLevel = try c.decodeIfPresent(Double.self, forKey: .synthLevel) ?? 1
        samplerLevel = try c.decodeIfPresent(Double.self, forKey: .samplerLevel) ?? 1
        masterLevel = try c.decodeIfPresent(Double.self, forKey: .masterLevel) ?? 1
        if let s = try c.decodeIfPresent([Submix].self, forKey: .submixes), s.count == Self.submixCount { submixes = s }
        if let r = try c.decodeIfPresent([ReturnBus].self, forKey: .returns), r.count == Self.returnCount { returns = r }
        xy = try c.decodeIfPresent(XYSettings.self, forKey: .xy) ?? XYSettings()
    }
}

public struct SamplerProject: Hashable, Codable, Sendable {
    /// 2: sequences and Timing Correct (phase 3). Version 1 files load with defaults.
    public static let currentSchema = 2
    public static let maxSequences = 128

    public var schemaVersion = SamplerProject.currentSchema
    public var samples: [SampleInfo] = []
    public var program = DrumProgram()
    public var mixer = SamplerMixer()
    public var sequences: [PadSequence] = [PadSequence(name: "Sequence 01")]
    public var currentSequence = 0
    public var timingCorrect = TimingCorrect()
    public var keygroups: [KeygroupProgram] = []
    public var song = Song()
    public var clips = ClipProgram()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, samples, program, mixer, sequences, currentSequence, timingCorrect, keygroups, song, clips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([SampleInfo].self, forKey: .samples) ?? []
        program = try c.decodeIfPresent(DrumProgram.self, forKey: .program) ?? DrumProgram()
        mixer = try c.decodeIfPresent(SamplerMixer.self, forKey: .mixer) ?? SamplerMixer()
        sequences = try c.decodeIfPresent([PadSequence].self, forKey: .sequences) ?? []
        if sequences.isEmpty { sequences = [PadSequence(name: "Sequence 01")] }
        currentSequence = min(max(0, try c.decodeIfPresent(Int.self, forKey: .currentSequence) ?? 0),
                              sequences.count - 1)
        timingCorrect = try c.decodeIfPresent(TimingCorrect.self, forKey: .timingCorrect) ?? TimingCorrect()
        keygroups = try c.decodeIfPresent([KeygroupProgram].self, forKey: .keygroups) ?? []
        song = try c.decodeIfPresent(Song.self, forKey: .song) ?? Song()
        clips = try c.decodeIfPresent(ClipProgram.self, forKey: .clips) ?? ClipProgram()
        schemaVersion = Self.currentSchema
    }

    public var sequence: PadSequence {
        get { sequences[currentSequence] }
        set { sequences[currentSequence] = newValue }
    }

    public func sample(_ id: SampleID?) -> SampleInfo? {
        guard let id else { return nil }
        return samples.first { $0.id == id }
    }
}
