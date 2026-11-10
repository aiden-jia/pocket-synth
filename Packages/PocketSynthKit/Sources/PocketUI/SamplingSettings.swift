import SynthDSP

/// Sampler mode sources (SAMPLER_SPEC §4).
public enum SamplingSource: String, CaseIterable, Sendable {
    case input, master, synth, sampler

    public var label: String {
        switch self {
        case .input: "Mic / input"
        case .master: "Resample: master"
        case .synth: "Resample: synth"
        case .sampler: "Resample: sampler"
        }
    }

    var engineSource: Int {
        switch self {
        case .input: Int(PS_SOURCE_INPUT.rawValue)
        case .master: Int(PS_SOURCE_MASTER.rawValue)
        case .synth: Int(PS_SOURCE_SYNTH.rawValue)
        case .sampler: Int(PS_SOURCE_SAMPLER.rawValue)
        }
    }
}

public struct SamplingSettings: Equatable, Sendable {
    public var source: SamplingSource = .master
    public var useThreshold = false
    public var thresholdDB = -40.0
    public var preRollMs = 100.0
    public var maxSeconds = 30.0
    public var stereo = true
    public var trimSilence = true
    public var openEditAfter = false
}
