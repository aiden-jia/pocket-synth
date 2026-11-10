/// Chop mode (SAMPLER_SPEC §5.2): slice markers on one sample, plus the settings of the
/// four methods. Detection itself runs in DSPKit; this holds the result and the edits.

public enum ChopMethod: String, CaseIterable, Sendable {
    case threshold, regions, beats, manual

    public var label: String {
        switch self {
        case .threshold: "Hits"
        case .regions: "Regions"
        case .beats: "BPM"
        case .manual: "Manual"
        }
    }
}

/// Slice length for the BPM method.
public enum BeatDivision: String, CaseIterable, Sendable {
    case bar, half, quarter, eighth, sixteenth

    public var beats: Double { [4, 2, 1, 0.5, 0.25][Self.allCases.firstIndex(of: self)!] }
    public var label: String { ["1 bar", "1/2", "1/4", "1/8", "1/16"][Self.allCases.firstIndex(of: self)!] }
}

public struct ChopSession: Equatable, Sendable {
    public static let maxSlices = 128

    public var sample: SampleID
    public var frames: Int
    public var sampleRate: Double
    public var method: ChopMethod = .threshold
    public var sensitivity = 0.5          // 0…1
    public var minLengthMs = 60.0
    public var regionCount = 8
    public var bpm = 120.0
    public var division: BeatDivision = .quarter
    /// Slice starts in frames, sorted; the first is always 0.
    public private(set) var markers: [Int] = [0]
    public var selected: Int?

    public init(sample: SampleID, frames: Int, sampleRate: Double) {
        self.sample = sample
        self.frames = max(2, frames)
        self.sampleRate = sampleRate
    }

    public var minLengthFrames: Int { Int(minLengthMs / 1000 * sampleRate) }

    public var slices: [Range<Int>] {
        markers.indices.map { i in markers[i]..<(i + 1 < markers.count ? markers[i + 1] : frames) }
    }

    public func slice(containing frame: Int) -> Int? {
        slices.firstIndex { $0.contains(frame) }
    }

    /// Replaces every marker (from a detector); keeps 0, sorted, unique, in range.
    public mutating func setMarkers(_ m: [Int]) {
        let clean = Set(m.filter { $0 > 0 && $0 < frames - 1 }).sorted()
        markers = [0] + Array(clean.prefix(Self.maxSlices - 1))
        if let s = selected, s >= markers.count { selected = nil }
    }

    public mutating func addMarker(at frame: Int) {
        guard markers.count < Self.maxSlices, frame > 0, frame < frames - 1, !markers.contains(frame) else { return }
        markers.append(frame)
        markers.sort()
        selected = markers.firstIndex(of: frame)
    }

    /// Removes a marker (merging its slice into the previous one). Marker 0 stays.
    public mutating func removeMarker(_ i: Int) {
        guard i > 0, i < markers.count else { return }
        markers.remove(at: i)
        selected = nil
    }

    /// Moves a marker, kept between its neighbours.
    public mutating func moveMarker(_ i: Int, to frame: Int) {
        guard i > 0, i < markers.count else { return }
        let lo = markers[i - 1] + 1
        let hi = (i + 1 < markers.count ? markers[i + 1] : frames) - 1
        markers[i] = max(lo, min(hi, frame))
    }

    /// Splits slice `i` in half.
    public mutating func split(_ i: Int) {
        guard slices.indices.contains(i) else { return }
        let r = slices[i]
        addMarker(at: r.lowerBound + r.count / 2)
    }

    /// Merges slice `i` with the next one.
    public mutating func mergeWithNext(_ i: Int) { removeMarker(i + 1) }
}
