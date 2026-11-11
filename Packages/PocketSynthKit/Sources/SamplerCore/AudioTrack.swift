/// Audio tracks (SAMPLER_SPEC §6): a track that plays one recorded or imported sample
/// from a point in the sequence. It is cut where the sequence ends (or loops). Audio plays
/// at its own speed: tempo changes don't stretch it (warp is still to do).
public struct AudioClip: Hashable, Codable, Sendable {
    public var sampleID: SampleID
    /// Where it starts, in ticks from the sequence start.
    public var startTick = 0
    public var level = 1.0
    public var pan = 0.0

    public init(sampleID: SampleID, startTick: Int = 0) {
        self.sampleID = sampleID
        self.startTick = max(0, startTick)
    }
}

extension PadSequence {
    /// Audio tracks get engine slots in track order (at most 16 per sequence).
    public static let maxAudioTracks = 16

    /// (track index, slot) for each audio track that fits.
    public var audioSlots: [(track: Int, slot: Int)] {
        tracks.indices.filter { tracks[$0].program == .audio }.prefix(Self.maxAudioTracks)
            .enumerated().map { ($0.element, $0.offset) }
    }
}
