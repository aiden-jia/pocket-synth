import ChordTheory

/// The three menu keys. On the device: K = gray (Key & Settings), S = yellow
/// (Sound & FX), M = red (Mode & Tempo).
public enum MenuKey: String, CaseIterable, Codable, Sendable {
    case key, sound, mode

    public var label: String {
        switch self {
        case .key: "KEY"
        case .sound: "SOUND"
        case .mode: "MODE"
        }
    }
}

/// Abstract input. Touch, game controllers and MIDI all produce these (DESIGN §4).
public enum ControlEvent: Equatable, Sendable {
    case padDown(Int)            // 1...7
    case padUp(Int)
    case menuDown(MenuKey)
    case menuUp(MenuKey)
    case stick(StickDirection?)  // nil = centered
    case clickDown
    case clickUp
    /// Relative wheel movement; one full-length drag of the wheel strip is 1.0.
    case wheel(Double)
}
