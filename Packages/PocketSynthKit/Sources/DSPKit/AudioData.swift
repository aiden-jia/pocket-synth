import Accelerate

/// Plain deinterleaved audio for offline work (DESIGN §7). Value type: processes return
/// a new value, so the original stays around for undo.
public struct AudioData: Equatable, Sendable {
    public var channels: [[Float]]
    public var sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        precondition(!channels.isEmpty)
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public init(mono: [Float], sampleRate: Double) { self.init(channels: [mono], sampleRate: sampleRate) }

    public var frames: Int { channels[0].count }
    public var channelCount: Int { channels.count }
    public var duration: Double { Double(frames) / sampleRate }

    /// Channel average.
    public var mono: [Float] {
        guard channels.count > 1 else { return channels[0] }
        var out = channels[0]
        for c in channels.dropFirst() { vDSP.add(out, c, result: &out) }
        vDSP.multiply(1 / Float(channels.count), out, result: &out)
        return out
    }

    public var peak: Float { channels.map { vDSP.maximumMagnitude($0) }.max() ?? 0 }

    /// Frames in `range`, clamped to the audio.
    public func clamp(_ range: Range<Int>) -> Range<Int> {
        let lo = max(0, min(frames, range.lowerBound))
        return lo..<max(lo, min(frames, range.upperBound))
    }

    public func slice(_ range: Range<Int>) -> AudioData {
        let r = clamp(range)
        return AudioData(channels: channels.map { Array($0[r]) }, sampleRate: sampleRate)
    }

    func map(_ f: ([Float]) -> [Float]) -> AudioData {
        AudioData(channels: channels.map(f), sampleRate: sampleRate)
    }
}

public extension Float {
    /// Decibels → linear gain.
    static func gain(dB: Float) -> Float { pow(10, dB / 20) }
}
