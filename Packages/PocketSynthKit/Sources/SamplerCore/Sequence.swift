/// Sequencer model (SAMPLER_SPEC §6): sequences of tracks of pad events, in ticks at
/// 960 PPQN, plus Timing Correct and the recording intake that turns raw engine hits
/// into events.

public enum PPQN {
    public static let ticks = 960
}

public struct NoteEvent: Hashable, Codable, Sendable, Identifiable {
    public var id: UInt32
    public var tick: Int
    public var length: Int
    public var pad: Int
    public var velocity: Int
    /// Semitones on top of the pad's own tune (16 Levels → tune).
    public var tune: Double

    public init(id: UInt32, tick: Int, length: Int, pad: Int, velocity: Int, tune: Double = 0) {
        self.id = id
        self.tick = tick
        self.length = length
        self.pad = pad
        self.velocity = velocity
        self.tune = tune
    }
}

public struct Track: Hashable, Codable, Sendable {
    public var name: String
    public var events: [NoteEvent] = []
    public var mute = false

    public init(name: String = "Track 1") { self.name = name }
}

/// A sequence (named PadSequence to stay clear of Swift's `Sequence`).
public struct PadSequence: Hashable, Codable, Sendable {
    public static let maxBars = 999

    public var name: String
    public var bars: Int
    public var beatsPerBar = 4
    public var loop = true
    public var tracks: [Track] = [Track()]
    public var nextEventID: UInt32 = 1

    public init(name: String, bars: Int = 2) {
        self.name = name
        self.bars = bars
    }

    public var lengthTicks: Int { bars * beatsPerBar * PPQN.ticks }
    public var ticksPerBar: Int { beatsPerBar * PPQN.ticks }

    /// Adds an event (tick wrapped into the sequence) and returns its id.
    @discardableResult
    public mutating func add(track: Int = 0, tick: Int, length: Int, pad: Int, velocity: Int, tune: Double = 0) -> UInt32 {
        let id = nextEventID
        nextEventID &+= 1
        let t = ((tick % lengthTicks) + lengthTicks) % lengthTicks
        let e = NoteEvent(id: id, tick: t, length: max(1, length), pad: pad,
                          velocity: max(1, min(127, velocity)), tune: tune)
        let events = tracks[track].events
        let at = events.firstIndex { $0.tick > t } ?? events.count
        tracks[track].events.insert(e, at: at)
        return id
    }

    public mutating func sortEvents(track: Int) {
        tracks[track].events.sort { $0.tick == $1.tick ? $0.id < $1.id : $0.tick < $1.tick }
    }

    /// Removes events (except `keep`) whose tick lies in [from, to), wrapping at the end.
    /// `pads` limits it to those pads (live erase); nil = every pad (replace recording).
    public mutating func erase(track: Int, from: Int, to: Int, pads: Set<Int>? = nil, keep: Set<UInt32> = []) {
        guard from != to else { return }
        func inRange(_ t: Int) -> Bool { from < to ? (t >= from && t < to) : (t >= from || t < to) }
        tracks[track].events.removeAll { e in
            !keep.contains(e.id) && inRange(e.tick) && (pads?.contains(e.pad) ?? true)
        }
    }

    /// Changes the length in bars. Events past the new end are dropped.
    public mutating func setBars(_ n: Int) {
        bars = max(1, min(Self.maxBars, n))
        let end = lengthTicks
        for i in tracks.indices { tracks[i].events.removeAll { $0.tick >= end } }
    }

    /// Doubles the length, copying every event into the new half.
    public mutating func double() {
        guard bars * 2 <= Self.maxBars else { return }
        let old = lengthTicks
        bars *= 2
        for i in tracks.indices {
            for e in tracks[i].events {
                add(track: i, tick: e.tick + old, length: e.length, pad: e.pad, velocity: e.velocity, tune: e.tune)
            }
        }
    }
}

// MARK: - Timing Correct

public enum NoteValue: String, CaseIterable, Codable, Sendable {
    case eighth, eighthTriplet, sixteenth, sixteenthTriplet, thirtySecond, thirtySecondTriplet

    public var ticks: Int {
        switch self {
        case .eighth: 480
        case .eighthTriplet: 320
        case .sixteenth: 240
        case .sixteenthTriplet: 160
        case .thirtySecond: 120
        case .thirtySecondTriplet: 80
        }
    }

    public var label: String {
        ["1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T"][Self.allCases.firstIndex(of: self)!]
    }
}

/// Timing Correct (SAMPLER_SPEC §6): pull note starts toward a (swung) grid.
public struct TimingCorrect: Hashable, Codable, Sendable {
    public var value: NoteValue = .sixteenth
    /// 50 (straight) … 75 %: where the second note of each pair lands.
    public var swing = 50.0
    /// 0 … 100 %: how far notes move toward the grid.
    public var strength = 100.0
    /// Apply while recording ("TC on input").
    public var onInput = true

    public init() {}

    /// Grid step k in ticks, with swing pushing odd steps late.
    public func gridTick(_ k: Int) -> Int {
        let g = Double(value.ticks)
        let offset = k & 1 == 1 ? (swing / 50 - 1) * g : 0
        return Int((Double(k) * g + offset).rounded())
    }

    /// Corrected tick for `tick` (not wrapped).
    public func apply(_ tick: Int) -> Int {
        let g = value.ticks
        let k0 = Int((Double(tick) / Double(g)).rounded(.down))
        var best = gridTick(k0)
        for k in [k0 - 1, k0 + 1, k0 + 2] where abs(gridTick(k) - tick) < abs(best - tick) {
            best = gridTick(k)
        }
        return tick + Int((Double(best - tick) * strength / 100).rounded())
    }

    /// Swing as the engine's 0.5 … 0.75 fraction (note repeat follows it).
    public var engineSwing: Double { swing / 100 }
}

// MARK: - Recording intake

/// A hit the engine stamped while recording (velocity 0 = pad released).
public struct RecordedHit: Equatable, Sendable {
    public var tick: Int
    public var pad: Int
    public var velocity: Int
    public var tune: Double

    public init(tick: Int, pad: Int, velocity: Int, tune: Double = 0) {
        self.tick = tick
        self.pad = pad
        self.velocity = velocity
        self.tune = tune
    }
}

/// Turns a stream of raw hits into events for one take: applies Timing Correct, wraps
/// into the loop, and sets each note's length from its release.
public struct TakeRecorder: Sendable {
    public private(set) var recordedIDs: Set<UInt32> = []
    private var open: [Int: (id: UInt32, start: Int)] = [:]

    public init() {}

    public mutating func ingest(_ hits: [RecordedHit], into seq: inout PadSequence, track: Int,
                                timing: TimingCorrect?) {
        let len = seq.lengthTicks
        for h in hits {
            if h.velocity > 0 {
                close(h.pad, at: h.tick, in: &seq, track: track)
                var t = timing.map { $0.apply(h.tick) } ?? h.tick
                // A hit in the count-in only counts if it corrects onto the downbeat.
                if t < 0 {
                    guard t > -(timing?.value.ticks ?? 0) / 2 || t == 0 else { continue }
                    t = 0
                }
                if seq.loop { t = ((t % len) + len) % len } else if t >= len { continue }
                let id = seq.add(track: track, tick: t, length: PPQN.ticks / 4, pad: h.pad,
                                 velocity: h.velocity, tune: h.tune)
                recordedIDs.insert(id)
                open[h.pad] = (id, h.tick)
            } else {
                close(h.pad, at: h.tick, in: &seq, track: track)
            }
        }
    }

    /// Ends the take: notes still held run to `tick`.
    public mutating func finish(at tick: Int, in seq: inout PadSequence, track: Int) {
        for pad in Array(open.keys) { close(pad, at: tick, in: &seq, track: track) }
    }

    private mutating func close(_ pad: Int, at tick: Int, in seq: inout PadSequence, track: Int) {
        guard let o = open.removeValue(forKey: pad) else { return }
        var length = tick - o.start
        if length <= 0 { length += seq.lengthTicks }
        guard let i = seq.tracks[track].events.firstIndex(where: { $0.id == o.id }) else { return }
        seq.tracks[track].events[i].length = max(1, min(length, seq.lengthTicks))
    }
}
