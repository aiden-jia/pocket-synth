import Foundation

/// Retrospective record (SAMPLER_SPEC §4): everything played in the last 30 s, on the
/// free-running beat clock, ready to become a sequence after the fact.
public struct RetroEvent: Equatable, Sendable {
    public enum Destination: Hashable, Sendable {
        case pad, keygroup(Int), synth, midi(channel: Int) // channel 1…16
    }

    public var beat: Double
    public var destination: Destination
    /// Pad or MIDI note.
    public var note: Int
    /// 0 = released.
    public var velocity: Int
    public var tune: Double
    /// When it arrived (seconds), for pruning.
    public var time: Double

    public init(beat: Double, destination: Destination, note: Int, velocity: Int, tune: Double = 0, time: Double = 0) {
        self.beat = beat
        self.destination = destination
        self.note = note
        self.velocity = velocity
        self.tune = tune
        self.time = time
    }

    public var program: TrackProgram {
        switch destination {
        case .pad: .drum
        case .keygroup(let i): .keygroup(i)
        case .synth: .synth
        case .midi(let ch): .midi(channel: ch)
        }
    }
}

public struct RetroBuffer: Sendable {
    public static let seconds = 30.0
    public private(set) var events: [RetroEvent] = []

    public init() {}

    /// Adds new events (arrival order). A clock jump backwards (the transport started)
    /// starts the buffer over, since older beats no longer line up.
    public mutating func add(_ new: [RetroEvent], now: Double) {
        for e in new {
            if let last = events.last, e.beat < last.beat - 0.01 { events.removeAll() }
            events.append(e)
        }
        if let i = events.firstIndex(where: { now - $0.time <= Self.seconds }) {
            if i > 0 { events.removeFirst(i) }
        } else {
            events.removeAll()
        }
    }

    public mutating func clear() { events.removeAll() }

    /// Hits (not releases) captured.
    public var hitCount: Int { events.filter { $0.velocity > 0 }.count }
}

public enum RetroCapture {
    /// Silence (in bars) that separates one phrase from the next.
    public static let phraseGapBars = 2.0

    /// A new sequence of whole bars around the latest phrase (what came after the last
    /// silence of `phraseGapBars` or more): one track per destination (pads first).
    /// Lengths come from the releases; Timing Correct is applied if given.
    public static func sequence(from all: [RetroEvent], beatsPerBar: Int, name: String,
                                timing: TimingCorrect?) -> PadSequence? {
        let gap = phraseGapBars * Double(max(1, beatsPerBar))
        let starts: [Double] = all.filter { $0.velocity > 0 }.map { $0.beat }.sorted()
        var phraseStart = -Double.infinity
        for i in starts.indices.dropFirst() where starts[i] - starts[i - 1] >= gap { phraseStart = starts[i] }
        let events = all.filter { $0.beat >= phraseStart - 1e-9 }
        let hits = events.filter { $0.velocity > 0 }
        guard let first = hits.map(\.beat).min(), let last = events.map(\.beat).max() else { return nil }
        let bpb = Double(max(1, beatsPerBar))
        let startBar = (first / bpb).rounded(.down)
        let bars = min(PadSequence.maxBars, max(1, Int(((last + 1e-6) / bpb).rounded(.down) - startBar) + 1))
        var seq = PadSequence(name: name, bars: bars)
        seq.beatsPerBar = Int(bpb)
        let origin = startBar * bpb

        var order: [RetroEvent.Destination] = []
        for e in hits where !order.contains(e.destination) { order.append(e.destination) }
        order.sort { a, b in a == .pad && b != .pad }
        seq.tracks = order.enumerated().map { i, d in
            let p = RetroEvent(beat: 0, destination: d, note: 0, velocity: 0).program
            return Track(name: p == .drum ? "Pads" : p.label, program: p)
        }
        for (t, d) in order.enumerated() {
            let mine = events.filter { $0.destination == d }
            for (i, e) in mine.enumerated() where e.velocity > 0 {
                let rawTick = Int(((e.beat - origin) * Double(PPQN.ticks)).rounded())
                let off = mine[(i + 1)...].first { $0.note == e.note }
                let length = off.map { max(1, Int((($0.beat - e.beat) * Double(PPQN.ticks)).rounded())) } ?? PPQN.ticks / 4
                let tick = timing.map { $0.apply(rawTick) } ?? rawTick
                guard tick >= 0, tick < seq.lengthTicks else { continue }
                seq.add(track: t, tick: tick, length: min(length, seq.lengthTicks), pad: e.note,
                        velocity: e.velocity, tune: e.tune)
            }
        }
        return seq
    }
}
