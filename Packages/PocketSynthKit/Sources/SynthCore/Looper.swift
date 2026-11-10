/// Synth looper model (SYNTH_SPEC §5). The engine owns the audio and the timing; this is
/// the controller's view of it. Every command to a track bumps its generation, and engine
/// telemetry is only believed when it reports the same generation, so a report that
/// predates a command can't undo it.

public enum LoopTrackState: Int, Sendable {
    case off, waiting, record, play

    public var symbol: String { ["—", "WAIT", "REC", "▶"][rawValue] }
}

public struct LoopTrack: Equatable, Sendable {
    public var state: LoopTrackState = .off
    public var generation = 0
    public var muted = false
    public var solo = false
    public var level = 1.0
}

public struct LooperState: Equatable, Sendable {
    public static let trackCount = 6
    /// Cursor position of the looper transport (pause / clear all).
    public static let transport = 6

    public var tracks = Array(repeating: LoopTrack(), count: trackCount)
    public var cursor = 0
    /// The engine has a loop length (the first take is done).
    public var hasLoop = false
    public var position = 0.0
    public var paused = false
    /// Free mode: this track waits for the first chord to start recording.
    public var freeArmed: Int?
    /// The track whose take sets the loop length, while it's in progress.
    public var firstTake: Int?

    public var hasAudio: Bool { tracks.contains { $0.state == .play } }
    public var isRecording: Bool { tracks.contains { $0.state == .record } }

    /// Effective playback gain after mute and solo.
    public func gain(_ i: Int) -> Double {
        let t = tracks[i]
        let anySolo = tracks.contains { $0.solo }
        if t.muted || (anySolo && !t.solo) { return 0 }
        return t.level
    }

    public func nextEmpty(after i: Int) -> Int? {
        (1...Self.trackCount).map { (i + $0) % Self.trackCount }.first { tracks[$0].state == .off }
    }
}

/// Telemetry from the engine for one track.
public struct LoopTrackReport: Equatable, Sendable {
    public var state: LoopTrackState
    public var generation: Int

    public init(state: LoopTrackState, generation: Int) {
        self.state = state
        self.generation = generation
    }

    /// Unpacks `ps_looper_track` (state in the low 3 bits).
    public init(packed: Int) {
        self.init(state: LoopTrackState(rawValue: packed & 7) ?? .off, generation: packed >> 3)
    }
}
