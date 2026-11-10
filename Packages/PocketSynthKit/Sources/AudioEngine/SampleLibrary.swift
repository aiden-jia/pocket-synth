import AVFoundation
import SamplerCore
import SynthDSP

/// Decoded sample buffers shared with the engine, plus waveform overviews for the UI.
@MainActor
public final class SampleLibrary {
    /// Waveform overview: per-bucket min and max (channel-merged).
    public struct Peaks: Sendable {
        public let min: [Float]
        public let max: [Float]
        public var count: Int { min.count }
    }

    public enum LoadError: Error, LocalizedError {
        case empty, tooLong(Double)
        public var errorDescription: String? {
            switch self {
            case .empty: "The file has no audio."
            case .tooLong(let s): "Sample is \(Int(s)) s long; the limit is 10 minutes."
            }
        }
    }

    static let maxSeconds = 600.0
    static let peakBuckets = 1024

    nonisolated(unsafe) var engine: OpaquePointer?
    private var handles: [SampleID: OpaquePointer] = [:]
    private var meta: [SampleID: (frames: Int, sampleRate: Double, channels: Int)] = [:]
    public private(set) var peaks: [SampleID: Peaks] = [:]

    init() {}

    public func handle(for id: SampleID) -> OpaquePointer? { handles[id] }
    public func isLoaded(_ id: SampleID) -> Bool { handles[id] != nil }

    /// Reads an audio file into a new engine sample. Returns metadata (frames, rate, channels).
    @discardableResult
    public func load(id: SampleID, from url: URL) throws -> (frames: Int, sampleRate: Double, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat // float32, deinterleaved
        let frames = Int(file.length)
        guard frames > 1 else { throw LoadError.empty }
        let seconds = Double(frames) / format.sampleRate
        guard seconds <= Self.maxSeconds else { throw LoadError.tooLong(seconds) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw LoadError.empty
        }
        try file.read(into: buffer)
        let channels = min(2, Int(format.channelCount))
        let count = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData, count > 1 else { throw LoadError.empty }

        let s = ps_sample_create(Int32(count), Int32(channels), format.sampleRate)!
        for ch in 0..<channels {
            ps_sample_channel(s, Int32(ch))!.update(from: data[ch], count: count)
        }
        install(id: id, sample: s, frames: count, channels: channels, sampleRate: format.sampleRate)
        return (count, format.sampleRate, channels)
    }

    /// Adds an already-filled sample (tests, generated audio).
    func install(id: SampleID, sample: OpaquePointer, frames: Int, channels: Int, sampleRate: Double = 48_000) {
        unload(id)
        handles[id] = sample
        meta[id] = (frames, sampleRate, channels)
        peaks[id] = Self.computePeaks(sample, frames: frames, channels: channels)
    }

    /// Hands the buffer back to the engine, which frees it once nothing plays it.
    public func unload(_ id: SampleID) {
        guard let h = handles.removeValue(forKey: id) else { return }
        peaks[id] = nil
        meta[id] = nil
        if let engine { ps_engine_release_sample(engine, h) } else { ps_sample_destroy(h) }
    }

    /// A copy of a loaded sample's audio (for offline processing and chop detection).
    public func audio(for id: SampleID) -> (channels: [[Float]], sampleRate: Double)? {
        guard let h = handles[id], let m = meta[id] else { return nil }
        let channels = (0..<m.channels).map { ch in
            Array(UnsafeBufferPointer(start: ps_sample_channel(h, Int32(ch)), count: m.frames))
        }
        return (channels, m.sampleRate)
    }

    /// Writes a WAV (1 or 2 channels). `bitDepth` 16 or 24 = integer PCM, 32 = float.
    public static func writeWAV(_ channels: [[Float]], sampleRate: Double, to url: URL, bitDepth: Int = 32) throws {
        let count = channels.first?.count ?? 0
        guard count > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                                     channels: AVAudioChannelCount(min(2, channels.count))),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { throw LoadError.empty }
        buffer.frameLength = AVAudioFrameCount(count)
        for (ch, data) in channels.prefix(2).enumerated() {
            buffer.floatChannelData![ch].update(from: data, count: count)
        }
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMIsNonInterleaved] = false // files are interleaved; the buffer isn't
        settings[AVLinearPCMBitDepthKey] = bitDepth == 32 ? 32 : bitDepth
        settings[AVLinearPCMIsFloatKey] = bitDepth == 32
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Frees buffers the engine has released. Call periodically.
    public func collectGarbage() {
        if let engine { ps_engine_collect_garbage(engine) }
    }

    static func computePeaks(_ s: OpaquePointer, frames: Int, channels: Int) -> Peaks {
        let buckets = min(peakBuckets, frames)
        var lo = [Float](repeating: 0, count: buckets)
        var hi = [Float](repeating: 0, count: buckets)
        for ch in 0..<channels {
            let d = ps_sample_channel(s, Int32(ch))!
            for b in 0..<buckets {
                let from = b * frames / buckets
                let to = max(from + 1, (b + 1) * frames / buckets)
                var mn: Float = 0, mx: Float = 0
                for i in from..<to {
                    mn = Swift.min(mn, d[i])
                    mx = Swift.max(mx, d[i])
                }
                lo[b] = Swift.min(lo[b], mn)
                hi[b] = Swift.max(hi[b], mx)
            }
        }
        return Peaks(min: lo, max: hi)
    }
}
