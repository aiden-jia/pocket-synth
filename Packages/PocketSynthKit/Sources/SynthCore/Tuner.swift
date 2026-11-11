import ChordTheory
import Foundation

/// Tuner mode (SYNTH_SPEC §4): a detected frequency as the nearest note and how far off it is.
public struct TunerReading: Equatable, Sendable {
    public var hz: Double
    /// Nearest MIDI note.
    public var note: Int
    /// -50…+50: how far `hz` is from that note.
    public var cents: Double

    /// nil for no pitch, or one outside 25 Hz … 4.2 kHz.
    public init?(hz: Double?, a4: Double = 440) {
        guard let hz, hz.isFinite, (25...4200).contains(hz) else { return nil }
        let exact = 69 + 12 * log2(hz / a4)
        note = Int(exact.rounded())
        cents = (exact - Double(note)) * 100
        self.hz = hz
    }

    public var name: String { PitchName.noteName(note) }
    public var inTune: Bool { abs(cents) < 5 }
}

/// The tuner's needle, smoothed so it doesn't jitter: readings near the shown note are
/// averaged; a different note takes over after two readings in a row.
public struct TunerSmoother: Sendable {
    public private(set) var shown: TunerReading?
    private var candidate: Int?
    private var misses = 0

    public init() {}

    public mutating func add(_ r: TunerReading?) -> TunerReading? {
        guard let r else {
            misses += 1
            if misses >= 6 { shown = nil } // ~0.4 s of silence clears the display
            return shown
        }
        misses = 0
        if var s = shown, s.note == r.note {
            s.cents += (r.cents - s.cents) * 0.35
            s.hz += (r.hz - s.hz) * 0.35
            shown = s
            candidate = nil
        } else if shown == nil || candidate == r.note {
            shown = r
            candidate = nil
        } else {
            candidate = r.note
        }
        return shown
    }
}
