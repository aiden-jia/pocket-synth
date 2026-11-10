import Foundation

/// Song mode (SAMPLER_SPEC §7): sequences in order, each repeated a number of times.
public struct SongStep: Hashable, Codable, Sendable, Identifiable {
    public var id = UUID()
    public var sequence: Int
    public var repeats: Int

    public init(sequence: Int, repeats: Int = 1) {
        self.sequence = sequence
        self.repeats = max(1, repeats)
    }
}

public struct Song: Hashable, Codable, Sendable {
    public var steps: [SongStep] = []
    public var loop = false

    public init() {}

    /// Sequence indices in playing order (repeats unrolled).
    public var playlist: [Int] { steps.flatMap { Array(repeating: $0.sequence, count: max(1, $0.repeats)) } }

    /// One sequence with every step laid end to end (tracks matched by number).
    public func flattened(_ sequences: [PadSequence], name: String) -> PadSequence {
        let list = playlist.filter { sequences.indices.contains($0) }
        let trackCount = list.map { sequences[$0].tracks.count }.max() ?? 1
        var out = PadSequence(name: name, bars: 1)
        out.tracks = (0..<trackCount).map { i in
            let first = list.lazy.compactMap { s in sequences[s].tracks.indices.contains(i) ? sequences[s].tracks[i] : nil }.first
            return Track(name: first?.name ?? "Track \(i + 1)", program: first?.program ?? .drum)
        }
        let bars = min(PadSequence.maxBars, max(1, list.reduce(0) { $0 + sequences[$1].bars }))
        out.setBars(bars)
        var offset = 0
        for s in list {
            let seq = sequences[s]
            for (i, t) in seq.tracks.enumerated() {
                for e in t.events where offset + e.tick < out.lengthTicks {
                    out.add(track: i, tick: offset + e.tick, length: e.length, pad: e.pad, velocity: e.velocity, tune: e.tune)
                }
            }
            offset += seq.bars * out.ticksPerBar
        }
        return out
    }
}
