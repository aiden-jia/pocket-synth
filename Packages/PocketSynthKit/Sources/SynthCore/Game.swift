import Foundation

/// Game mode (SYNTH_SPEC §4): chords scroll to a hit line and you play them on time.
/// Ten songs in five tiers, all our own charts.
public struct GameNote: Hashable, Sendable {
    /// Beat from the song's start (the first bar is a drum count-in).
    public var beat: Double
    public var pad: Int
}

public struct GameSong: Hashable, Sendable {
    public var name: String
    public var tier: Int
    public var bpm: Double
    public var style: BeatStyle
    public var notes: [GameNote]
    public var lengthBeats: Double

    public static let countInBeats = 4.0

    /// `progression`: one pad per bar. `rhythm`: 16 sixteenth steps per bar, `x` = hit.
    init(_ name: String, tier: Int, bpm: Double, style: BeatStyle, progression: [Int], rhythm: String) {
        self.name = name
        self.tier = tier
        self.bpm = bpm
        self.style = style
        var notes: [GameNote] = []
        for (bar, pad) in progression.enumerated() {
            for (i, c) in rhythm.enumerated() where c == "x" {
                notes.append(GameNote(beat: Self.countInBeats + Double(bar * 4) + Double(i) * 0.25, pad: pad))
            }
        }
        self.notes = notes
        lengthBeats = Self.countInBeats + Double(progression.count * 4) + 1
    }
}

public enum GameSongs {
    public static let all: [GameSong] = [
        GameSong("First Light", tier: 1, bpm: 80, style: .rock,
                 progression: [1, 5, 6, 4, 1, 5, 4, 1], rhythm: "x..............."),
        GameSong("Slow Tide", tier: 1, bpm: 84, style: .dub,
                 progression: [1, 4, 1, 5, 6, 4, 5, 1], rhythm: "x.......x......."),
        GameSong("Paper Kites", tier: 2, bpm: 96, style: .rock,
                 progression: [1, 6, 4, 5, 1, 6, 4, 5], rhythm: "x...x...x...x..."),
        GameSong("Late Bus", tier: 2, bpm: 92, style: .swing,
                 progression: [2, 5, 1, 6, 2, 5, 1, 1], rhythm: "x.......x...x..."),
        GameSong("Neon Steps", tier: 3, bpm: 110, style: .house,
                 progression: [6, 4, 1, 5, 6, 4, 1, 5], rhythm: "x...x...x.x.x..."),
        GameSong("Corner Store", tier: 3, bpm: 100, style: .funk,
                 progression: [1, 4, 6, 5, 1, 4, 6, 5], rhythm: "x..x..x...x.x..."),
        GameSong("Rooftop", tier: 4, bpm: 120, style: .breaks,
                 progression: [1, 3, 4, 5, 6, 4, 2, 5], rhythm: "x.x...x.x.x...x."),
        GameSong("Heatwave", tier: 4, bpm: 104, style: .dembow,
                 progression: [6, 5, 4, 5, 6, 5, 4, 5], rhythm: "x..x..x.x..x..x."),
        GameSong("Night Drive", tier: 5, bpm: 124, style: .house,
                 progression: [1, 5, 6, 3, 4, 1, 4, 5], rhythm: "x.x.x.xx.x.x.xx."),
        GameSong("Overclock", tier: 5, bpm: 136, style: .breaks,
                 progression: [6, 4, 1, 5, 6, 4, 2, 5], rhythm: "x.xx.x.xx.x.x.xx"),
    ]
}

public enum GameJudgement: String, Sendable {
    case perfect, good, miss
    public var label: String { rawValue.uppercased() }
}

/// One play of a song. Times are seconds on the same clock as the control events.
public struct GameRun: Sendable {
    public static let perfectWindow = 0.05
    public static let goodWindow = 0.12

    public let song: GameSong
    public let speed: Double
    /// When beat 0 sounds.
    public let startTime: Double
    public private(set) var results: [GameJudgement?]
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var last: (judgement: GameJudgement, at: Double)?

    public init(song: GameSong, speed: Double, startTime: Double) {
        self.song = song
        self.speed = speed
        self.startTime = startTime
        results = Array(repeating: nil, count: song.notes.count)
    }

    public var bpm: Double { song.bpm * speed }
    public var secondsPerBeat: Double { 60 / bpm }
    public func time(of i: Int) -> Double { startTime + song.notes[i].beat * secondsPerBeat }
    public var endTime: Double { startTime + song.lengthBeats * secondsPerBeat }

    /// Judges a pad press against the nearest open note on that pad. nil = nothing near
    /// (stray presses aren't punished).
    @discardableResult
    public mutating func hit(pad: Int, at t: Double) -> GameJudgement? {
        var best: (i: Int, d: Double)?
        for i in song.notes.indices where results[i] == nil && song.notes[i].pad == pad {
            let d = abs(time(of: i) - t)
            if d <= Self.goodWindow, d < (best?.d ?? .infinity) { best = (i, d) }
        }
        guard let b = best else { return nil }
        let j: GameJudgement = b.d <= Self.perfectWindow ? .perfect : .good
        record(b.i, j, at: t)
        return j
    }

    /// Marks notes whose window has passed as missed. Returns how many.
    @discardableResult
    public mutating func expire(at t: Double) -> Int {
        var n = 0
        for i in song.notes.indices where results[i] == nil && t > time(of: i) + Self.goodWindow {
            record(i, .miss, at: time(of: i) + Self.goodWindow)
            n += 1
        }
        return n
    }

    private mutating func record(_ i: Int, _ j: GameJudgement, at t: Double) {
        results[i] = j
        combo = j == .miss ? 0 : combo + 1
        maxCombo = max(maxCombo, combo)
        last = (j, t)
    }

    public func isFinished(at t: Double) -> Bool { t >= endTime }

    public func count(_ j: GameJudgement) -> Int { results.filter { $0 == j }.count }

    /// 0…100 over the notes judged so far: perfect = full marks, good = half.
    public var accuracy: Int {
        let judged = results.compactMap { $0 }.count
        guard judged > 0 else { return 0 }
        let points = 2 * count(.perfect) + count(.good)
        return Int((Double(points) / Double(2 * judged) * 100).rounded())
    }

    public var grade: String {
        switch accuracy {
        case 95...: "S"
        case 85..<95: "A"
        case 70..<85: "B"
        case 50..<70: "C"
        default: "D"
        }
    }

    /// What the lane shows at `t`: notes within `lookahead` seconds of the hit line.
    public func lane(at t: Double, lookahead: Double = 2.0) -> GameLane {
        var notes: [GameLane.Note] = []
        for i in song.notes.indices {
            let dt = time(of: i) - t
            guard dt > -0.25, dt < lookahead else { continue }
            notes.append(.init(id: i, pad: song.notes[i].pad, position: dt / lookahead, result: results[i]))
        }
        let flash = last.flatMap { t - $0.at < 0.5 ? $0.judgement : nil }
        let firstBeat = song.notes.first.map { startTime + $0.beat * secondsPerBeat } ?? startTime
        let countdown = t < firstBeat ? Int(((firstBeat - t) / secondsPerBeat).rounded(.up)) : nil
        return GameLane(notes: notes, flash: flash, combo: combo, accuracy: accuracy,
                        progress: min(1, max(0, (t - startTime) / (endTime - startTime))), countdown: countdown)
    }
}

/// The scrolling lane, as drawn: `position` 0 = on the hit line, 1 = top of the lane.
public struct GameLane: Equatable, Sendable {
    public struct Note: Equatable, Sendable {
        public var id: Int
        public var pad: Int
        public var position: Double
        public var result: GameJudgement?
    }

    public var notes: [Note]
    public var flash: GameJudgement?
    public var combo: Int
    public var accuracy: Int
    public var progress: Double
    /// Beats left in the count-in.
    public var countdown: Int?
}
