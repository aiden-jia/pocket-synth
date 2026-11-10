/// Automation and Q-Links (SAMPLER_SPEC §6, §9): one parameter space for both.

public enum AutoParam: Hashable, Codable, Sendable {
    case samplerLevel, synthLevel, masterLevel
    case padLevel(Int), padPan(Int), padTune(Int)
    case submixLevel(Int), returnLevel(Int)
    case xyX, xyY

    public var label: String {
        switch self {
        case .samplerLevel: "Sampler"
        case .synthLevel: "Synth"
        case .masterLevel: "Master"
        case .padLevel(let p): "\(PadAddress.name(p)) level"
        case .padPan(let p): "\(PadAddress.name(p)) pan"
        case .padTune(let p): "\(PadAddress.name(p)) tune"
        case .submixLevel(let i): "Sub \(i + 1)"
        case .returnLevel(let i): "Return \(i + 1)"
        case .xyX: "XY x"
        case .xyY: "XY y"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .padPan: -1...1
        case .padTune: -24...24
        case .xyX, .xyY: 0...1
        default: 0...1.5
        }
    }

    /// Parameters a project Q-Link can be assigned to (pads: the selected one).
    public static func assignable(selectedPad p: Int) -> [AutoParam] {
        [.samplerLevel, .synthLevel, .masterLevel, .padLevel(p), .padPan(p), .padTune(p), .xyX, .xyY]
            + (0..<SamplerMixer.submixCount).map { .submixLevel($0) }
            + (0..<SamplerMixer.returnCount).map { .returnLevel($0) }
    }
}

public struct AutoPoint: Hashable, Codable, Sendable {
    public var tick: Int
    public var value: Double
    public init(tick: Int, value: Double) { self.tick = tick; self.value = value }
}

public struct AutomationLane: Hashable, Codable, Sendable {
    public var param: AutoParam
    public var points: [AutoPoint] = [] // sorted by tick

    public init(param: AutoParam) { self.param = param }

    /// Linear between points; held before the first and after the last.
    public func value(at tick: Double) -> Double? {
        guard let first = points.first else { return nil }
        if tick <= Double(first.tick) { return first.value }
        guard let j = points.firstIndex(where: { Double($0.tick) > tick }) else { return points.last!.value }
        let a = points[j - 1], b = points[j]
        let f = (tick - Double(a.tick)) / Double(max(1, b.tick - a.tick))
        return a.value + (b.value - a.value) * f
    }

    /// Writes a point, replacing points in (from, tick] (the stretch the knob just swept).
    public mutating func write(_ value: Double, at tick: Int, from: Int?) {
        if let from {
            if from < tick { points.removeAll { $0.tick > from && $0.tick <= tick } }
            else { points.removeAll { $0.tick == tick } }
        } else {
            points.removeAll { $0.tick == tick }
        }
        let i = points.firstIndex { $0.tick > tick } ?? points.count
        points.insert(AutoPoint(tick: tick, value: value), at: i)
    }
}

public enum AutomationMode: String, CaseIterable, Sendable {
    case off, read, write
    public var label: String { ["Off", "Read", "Write"][Self.allCases.firstIndex(of: self)!] }
}

/// Q-Link knob pages (SAMPLER_SPEC §9).
public enum QLinkPage: String, CaseIterable, Sendable {
    case pad, mixer, returns, project
    public var label: String { ["Pad", "Mixer", "Returns", "Project"][Self.allCases.firstIndex(of: self)!] }
}
