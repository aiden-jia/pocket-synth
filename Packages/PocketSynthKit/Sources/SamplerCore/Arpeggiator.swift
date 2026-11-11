/// Per-track arpeggiator (SAMPLER_SPEC §6) for keygroup, synth and MIDI tracks. The
/// engine runs it; notes you play or record on the track are its input.
public enum ArpMode: String, CaseIterable, Codable, Sendable {
    case up, down, upDown, upDownIncl, random, order

    public var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .upDown: "Up/down (excl)"
        case .upDownIncl: "Up/down (incl)"
        case .random: "Random"
        case .order: "As played"
        }
    }
}

public struct TrackArp: Hashable, Codable, Sendable {
    public var on = false
    public var mode: ArpMode = .up
    /// 1…4 octaves.
    public var octaves = 1
    public var rate: RepeatRate = .sixteenth
    /// Note length as a share of a step, 0.05…1.
    public var gate = 0.5
    /// Notes keep playing after you let go, until the next chord.
    public var latch = false

    public init() {}

    enum CodingKeys: String, CodingKey { case on, mode, octaves, rate, gate, latch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
        mode = try c.decodeIfPresent(ArpMode.self, forKey: .mode) ?? .up
        octaves = max(1, min(4, try c.decodeIfPresent(Int.self, forKey: .octaves) ?? 1))
        rate = try c.decodeIfPresent(RepeatRate.self, forKey: .rate) ?? .sixteenth
        gate = max(0.05, min(1, try c.decodeIfPresent(Double.self, forKey: .gate) ?? 0.5))
        latch = try c.decodeIfPresent(Bool.self, forKey: .latch) ?? false
    }

    public var summary: String { on ? "\(mode.label) · \(rate.label)" + (octaves > 1 ? " · \(octaves) oct" : "") : "Off" }
}
