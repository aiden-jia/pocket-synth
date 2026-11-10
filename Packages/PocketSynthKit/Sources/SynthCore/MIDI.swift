import Foundation

/// MIDI 1.0 messages as CoreMIDI's Universal MIDI Packets carry them (SYNTH_SPEC §9).
public enum MIDIMessage: Equatable, Sendable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case clock, start, `continue`, stop
    case other

    /// One 32-bit UMP word (message types 1 = system, 2 = MIDI 1.0 channel voice).
    public init(ump word: UInt32) {
        let type = word >> 28
        let status = Int((word >> 16) & 0xff)
        let d1 = Int((word >> 8) & 0x7f), d2 = Int(word & 0x7f)
        switch type {
        case 0x1:
            switch status {
            case 0xF8: self = .clock
            case 0xFA: self = .start
            case 0xFB: self = .continue
            case 0xFC: self = .stop
            default: self = .other
            }
        case 0x2:
            let ch = status & 0x0f
            switch status & 0xf0 {
            case 0x90: self = d2 > 0 ? .noteOn(channel: ch, note: d1, velocity: d2) : .noteOff(channel: ch, note: d1)
            case 0x80: self = .noteOff(channel: ch, note: d1)
            case 0xB0: self = .controlChange(channel: ch, controller: d1, value: d2)
            default: self = .other
            }
        default:
            self = .other
        }
    }

    /// Status / data bytes for the engine (nil for system messages).
    public var bytes: (status: Int, data1: Int, data2: Int)? {
        switch self {
        case .noteOn(let c, let n, let v): (0x90 | c, n, v)
        case .noteOff(let c, let n): (0x80 | c, n, 0)
        case .controlChange(let c, let cc, let v): (0xB0 | c, cc, v)
        default: nil
        }
    }

    /// A MIDI 1.0 channel-voice / system UMP word for `status, data1, data2`.
    public static func ump(status: Int, data1: Int, data2: Int, group: Int = 0) -> UInt32 {
        let type: UInt32 = status >= 0xF0 ? 0x1 : 0x2
        return type << 28 | UInt32(group & 0xf) << 24 | UInt32(status & 0xff) << 16
            | UInt32(data1 & 0x7f) << 8 | UInt32(data2 & 0x7f)
    }
}

/// Follows an incoming 24 PPQN clock: tempo from the average of the last 24 tick intervals.
/// After `holdTime` without ticks the last tempo simply stays (SYNTH_SPEC §6).
public struct ClockFollower: Sendable {
    public static let holdTime = 0.5
    private var ticks: [Double] = []
    public private(set) var bpm: Double?

    public init() {}

    /// Feed a tick time (seconds). Returns a new tempo when it moved by ≥ 0.5 BPM.
    public mutating func tick(at t: Double) -> Double? {
        if let last = ticks.last, t - last > Self.holdTime { ticks.removeAll() }
        ticks.append(t)
        if ticks.count > 25 { ticks.removeFirst(ticks.count - 25) }
        guard ticks.count >= 13 else { return nil } // half a beat of clock first
        let interval = (ticks.last! - ticks.first!) / Double(ticks.count - 1)
        let tempo = min(300, max(40, (60 / (interval * 24) * 10).rounded() / 10))
        guard bpm.map({ abs($0 - tempo) >= 0.5 }) ?? true else { return nil }
        bpm = tempo
        return tempo
    }
}

/// Control CCs (SYNTH_SPEC §9): only after CC 127 = 1 on that channel (CC 127 = 0 turns
/// it off again). 20 + 50 = BPM as a 14-bit value (MSB, then LSB), 21 = key, 22 = octave,
/// 29 = filter cutoff, 31 = reverb type.
public struct MIDIControlMap: Sendable {
    public enum Action: Equatable, Sendable {
        case tempo(Double)
        case key(Int)
        case octave(Int)
        case cutoff(Double)
        case reverb(Int)
    }

    private var enabled: Set<Int> = []
    private var bpmMSB: [Int: Int] = [:]

    public init() {}

    public mutating func handle(channel: Int, controller: Int, value: Int) -> Action? {
        if controller == 127 {
            if value == 1 { enabled.insert(channel) } else if value == 0 { enabled.remove(channel) }
            return nil
        }
        guard enabled.contains(channel) else { return nil }
        switch controller {
        case 20:
            bpmMSB[channel] = value
            return nil
        case 50:
            let v = (bpmMSB[channel] ?? 0) << 7 | value
            return .tempo(Double(min(300, max(40, v))))
        case 21: return .key(value % 12)
        case 22: return .octave(max(-2, min(2, value - 64)))
        case 29: return .cutoff(20 * pow(1000, Double(value) / 127))
        case 31: return .reverb(min(6, value * 7 / 128))
        default: return nil
        }
    }
}
