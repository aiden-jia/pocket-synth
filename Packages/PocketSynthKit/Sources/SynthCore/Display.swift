/// Which menu screen is open (SYNTH_SPEC §11).
public enum OpenMenu: Equatable, Sendable {
    case key
    case sound
    case settings(row: Int)
    case mode(highlight: Int)
    case bpm
    case presets(slot: Int)

    /// The menu key that owns this screen (pressing it again closes the screen).
    var owner: MenuKey? {
        switch self {
        case .key: .key
        case .sound, .settings: .sound
        case .mode, .bpm: .mode
        case .presets: nil
        }
    }
}

public enum Dialog: Equatable, Sendable {
    case save(slot: Int)
    case load(slot: Int)

    public var text: String {
        switch self {
        case .save(let s): "SAVE P\(s + 1)?"
        case .load(let s): "LOAD P\(s + 1)?"
        }
    }
}

public struct Toast: Equatable, Sendable {
    public var text: String
    public var until: Double
}

public struct MenuDisplay: Equatable, Sendable {
    public var title: String
    public var items: [String]
    public var selected: Int?
    public var hint: String
}

/// Everything the status screen shows, derived from controller state.
public struct DisplayModel: Equatable, Sendable {
    public var status: String
    public var bpm: Int
    public var chordName: String?
    public var menu: MenuDisplay?
    public var dialog: String?
    public var toast: String?
    /// Mode-specific line: kit, beat style, sequencer state.
    public var detail: String? = nil
    /// Seq mode: the current page of steps.
    public var steps: [StepCell]? = nil
    public var looper: LooperDisplay? = nil
    /// Tuner and Game draw their own screens.
    public var tool: ToolScreen? = nil
}

public enum ToolScreen: Equatable, Sendable {
    /// nil reading = no pitch heard.
    case tuner(TunerReading?)
    case game(GameScreen)
}

/// Game mode's song picker / results (the running lane comes from `gameLane(at:)`).
public struct GameScreen: Equatable, Sendable {
    public var running: Bool
    public var song: String
    public var tier: Int
    public var bpm: Int
    public var speedPercent: Int
    public var best: Int?
    /// After a run: grade, accuracy and counts.
    public var result: String?
}

public struct LoopCell: Equatable, Sendable {
    public var index: Int
    public var state: LoopTrackState
    public var muted: Bool
    public var solo: Bool
    public var isCursor: Bool
}

public struct LooperDisplay: Equatable, Sendable {
    public var cells: [LoopCell]
    public var transportSelected: Bool
    /// Playhead 0…1, nil before the first take.
    public var position: Double?
    public var paused: Bool
    public var lengthText: String
}

public struct StepCell: Equatable, Sendable {
    public var index: Int
    public var label: String
    public var isCursor: Bool
    public var isPlaying: Bool
}
