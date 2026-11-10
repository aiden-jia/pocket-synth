/// Drum voices, kits and the Beat mode's styles × variations (SYNTH_SPEC §4).
/// All patterns are our own simple genre grooves.

public enum DrumVoice: Int, CaseIterable, Codable, Sendable {
    case kick, snare, closedHat, tom, openHat, cowbell, clap, shaker

    /// Drums mode: pad 1–7 → voice.
    public static func forPad(_ pad: Int) -> DrumVoice? { DrumVoice(rawValue: pad - 1) }

    /// General MIDI drum note (SYNTH_SPEC §9).
    public var gmNote: Int { [36, 38, 42, 45, 46, 56, 39, 70][rawValue] }

    public var label: String { ["KICK", "SNARE", "HAT", "TOM", "OPEN HAT", "BELL", "CLAP", "SHAKER"][rawValue] }
}

public enum DrumKitCatalog {
    public static let names = ["CLASSIC", "TIGHT", "BOOM", "LO-FI", "METAL", "SOFT", "BIG ROOM"]
}

public enum BeatStyle: Int, CaseIterable, Codable, Sendable {
    case rock, breaks, dub, funk, house, dembow, swing

    public var label: String { ["ROCK", "BREAK", "DUB", "FUNK", "HOUSE", "DEMBOW", "SWING"][rawValue] }
}

public enum BeatVariation: Int, CaseIterable, Codable, Sendable {
    case original, ghost, sixteenths, push, fill, half, double, perc

    public var label: String { ["ORIG", "GHOST", "16TH", "PUSH", "FILL", "HALF", "DOUBLE", "PERC"][rawValue] }
}

/// A step pattern for the engine's beat player: velocity per step per drum voice.
public struct BeatPattern: Hashable, Sendable {
    public var stepBeats: Double
    public var swing: Double
    public var hits: [[Int]] // [step][voice], 0 = silent

    public var steps: Int { hits.count }

    public init(stepBeats: Double = 0.25, swing: Double = 0.5, steps: Int) {
        self.stepBeats = stepBeats
        self.swing = swing
        hits = Array(repeating: Array(repeating: 0, count: DrumVoice.allCases.count), count: steps)
    }

    public func velocity(_ step: Int, _ voice: DrumVoice) -> Int { hits[step][voice.rawValue] }

    /// Lanes as strings: X = accent, x = normal, g = ghost, . = rest.
    init(stepBeats: Double = 0.25, swing: Double = 0.5, _ lanes: [DrumVoice: String]) {
        let steps = lanes.values.map(\.count).max() ?? 16
        self.init(stepBeats: stepBeats, swing: swing, steps: steps)
        for (voice, lane) in lanes {
            for (i, c) in lane.enumerated() { hits[i][voice.rawValue] = Self.velocity(c) }
        }
    }

    static func velocity(_ c: Character) -> Int {
        switch c {
        case "X": 120
        case "x": 96
        case "g": 44
        default: 0
        }
    }

    // MARK: Library

    public static func base(_ style: BeatStyle) -> BeatPattern {
        switch style {
        case .rock:
            BeatPattern([.kick: "X.......x.x.....", .snare: "....X.......X...", .closedHat: "x.x.x.x.x.x.x.x."])
        case .breaks:
            BeatPattern([.kick: "X.........x.....", .snare: "....X..g.g..X..g", .closedHat: "x.x.x.x.x.xxx.x.",
                         .openHat: ".............x.."])
        case .dub:
            BeatPattern([.kick: "........X.......", .snare: "........x.......", .closedHat: "x.x.x.x.x.x.x.x.",
                         .cowbell: "..x...x...x...x."])
        case .funk:
            BeatPattern([.kick: "X..x..x...x..x..", .snare: "....X..g.g..X..g", .closedHat: "XxxxXxxxXxxxXxxx"])
        case .house:
            BeatPattern([.kick: "X...X...X...X...", .clap: "....X.......X...", .openHat: "..x...x...x...x.",
                         .closedHat: "x.x.x.x.x.x.x.x."])
        case .dembow:
            BeatPattern([.kick: "X...X...X...X...", .snare: "...x..x....x..x.", .closedHat: "x.x.x.x.x.x.x.x."])
        case .swing:
            // Swung 8ths: eight steps per bar.
            BeatPattern(stepBeats: 0.5, swing: 0.66,
                        [.kick: "X...x...", .snare: "..x...x.", .closedHat: "xxxxxxxx", .openHat: "........"])
        }
    }

    public static func make(_ style: BeatStyle, _ variation: BeatVariation) -> BeatPattern {
        let b = base(style)
        switch variation {
        case .original: return b
        case .ghost: return b.addingGhosts()
        case .sixteenths: return b.withEveryStep(.closedHat, velocity: 70, accentEvery: b.stepsPerBeat)
        case .push: return b.withPush()
        case .fill: return b.withFill()
        case .half:
            var p = b
            p.stepBeats *= 2
            return p
        case .double:
            var p = b
            p.stepBeats /= 2
            return p
        case .perc: return b.withPerc()
        }
    }

    var stepsPerBeat: Int { max(1, Int((1 / stepBeats).rounded())) }

    func addingGhosts() -> BeatPattern {
        var p = self
        for i in 0..<steps where p.hits[i][DrumVoice.snare.rawValue] == 0 && i % 2 == 1 && i % 4 != 1 {
            p.hits[i][DrumVoice.snare.rawValue] = 40
        }
        return p
    }

    func withEveryStep(_ voice: DrumVoice, velocity: Int, accentEvery: Int) -> BeatPattern {
        var p = self
        for i in 0..<steps {
            p.hits[i][voice.rawValue] = i % accentEvery == 0 ? 105 : velocity
            if voice == .closedHat { p.hits[i][DrumVoice.openHat.rawValue] = 0 }
        }
        return p
    }

    /// Kick anticipates the next downbeat (last 8th of the bar).
    func withPush() -> BeatPattern {
        var p = self
        let k = DrumVoice.kick.rawValue
        let at = steps - max(1, stepsPerBeat / 2)
        p.hits[at][k] = 110
        return p
    }

    /// Two bars: the groove, then the groove with a tom/snare fill on the last beat.
    func withFill() -> BeatPattern {
        var p = BeatPattern(stepBeats: stepBeats, swing: swing, steps: steps * 2)
        for i in 0..<steps { p.hits[i] = hits[i]; p.hits[steps + i] = hits[i] }
        let fillStart = steps * 2 - stepsPerBeat
        for i in fillStart..<(steps * 2) {
            let j = i - fillStart
            p.hits[i] = Array(repeating: 0, count: DrumVoice.allCases.count)
            p.hits[i][(j < stepsPerBeat / 2 ? DrumVoice.snare : DrumVoice.tom).rawValue] = 80 + 10 * j
        }
        p.hits[steps * 2 - 1][DrumVoice.kick.rawValue] = 100
        return p
    }

    func withPerc() -> BeatPattern {
        var p = self
        for i in 0..<steps {
            p.hits[i][DrumVoice.shaker.rawValue] = i % 2 == 0 ? 70 : 45
            if i % (stepsPerBeat * 2) == stepsPerBeat + stepsPerBeat / 2 { p.hits[i][DrumVoice.cowbell.rawValue] = 80 }
        }
        return p
    }
}
