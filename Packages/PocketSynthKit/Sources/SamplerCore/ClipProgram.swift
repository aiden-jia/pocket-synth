import Foundation

/// Clip program (SAMPLER_SPEC §3.3): 16 pads of clips that launch in time. Each pad's
/// column (pads 1, 5, 9, 13 …) is a group: one clip per column plays at a time.
public enum ClipMode: String, CaseIterable, Codable, Sendable {
    case loop, oneShot, gate

    public var label: String {
        switch self {
        case .loop: "Loop (tap on/off)"
        case .oneShot: "One shot"
        case .gate: "Gate (while held)"
        }
    }
}

public enum ClipQuantize: String, CaseIterable, Codable, Sendable {
    case bar, beat, off

    public var label: String {
        switch self {
        case .bar: "1 bar"
        case .beat: "1 beat"
        case .off: "Immediate"
        }
    }

    public func beats(beatsPerBar: Int) -> Double {
        switch self {
        case .bar: Double(beatsPerBar)
        case .beat: 1
        case .off: 0
        }
    }
}

public struct ClipPad: Hashable, Codable, Sendable {
    public var sampleID: SampleID?
    public var mode: ClipMode = .loop
    public var level = 1.0
    /// Played over this many beats so it follows the tempo (varispeed); 0 = own speed.
    public var beats = 0.0

    public init(sampleID: SampleID? = nil) { self.sampleID = sampleID }

    /// Beats a loop of `seconds` most likely spans at `bpm`: the nearest of 1, 2, 4 … 64.
    public static func guessBeats(seconds: Double, bpm: Double) -> Double {
        let raw = seconds * bpm / 60
        guard raw > 0 else { return 0 }
        let options = (0...6).map { pow(2.0, Double($0)) }
        return options.min { abs(log2($0 / raw)) < abs(log2($1 / raw)) }!
    }
}

public struct ClipProgram: Hashable, Codable, Sendable {
    public static let count = 16

    public var name = "Clips 1"
    public var pads = [ClipPad](repeating: ClipPad(), count: ClipProgram.count)
    public var quantize: ClipQuantize = .bar

    public init() {}

    /// The group a clip belongs to: its column in the 4×4 grid.
    public static func group(_ i: Int) -> Int { i % 4 }
}

/// What a clip is doing (engine telemetry, for the pad lights).
public enum ClipState: Int, Sendable {
    case stopped, queued, playing, stopping
}
