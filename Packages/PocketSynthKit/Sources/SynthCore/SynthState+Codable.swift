import Foundation

/// Tolerant decoding: a session or preset saved by an older build loads with defaults
/// for anything it doesn't have, instead of failing.
extension SynthState {
    enum CodingKeys: String, CodingKey {
        case key, scale, globalOctave, padOctave, padInversion, locks, stickMode, voiceCount, bassMode, voiceLeading, soundIndex, envelopePreset, attackOverrideMs, releaseOverrideMs, glide, stereo, fx, filterCutoffHz, mode, strumSpeed, arpPattern, arpLayer, arpRate, repeatRate, drumKit, beatStyle, beatVariation, seqRate, chordSequence, bpm, loopBars, metronome, metronomeLevel, midiIn, midiOut, volume, trainerLevel, micSampleRoot
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x }
        }
        get(.key, &key)
        get(.scale, &scale)
        get(.globalOctave, &globalOctave)
        get(.padOctave, &padOctave)
        get(.padInversion, &padInversion)
        get(.locks, &locks)
        get(.stickMode, &stickMode)
        get(.voiceCount, &voiceCount)
        get(.bassMode, &bassMode)
        get(.voiceLeading, &voiceLeading)
        get(.soundIndex, &soundIndex)
        get(.envelopePreset, &envelopePreset)
        get(.attackOverrideMs, &attackOverrideMs)
        get(.releaseOverrideMs, &releaseOverrideMs)
        get(.glide, &glide)
        get(.stereo, &stereo)
        get(.fx, &fx)
        get(.filterCutoffHz, &filterCutoffHz)
        get(.mode, &mode)
        get(.strumSpeed, &strumSpeed)
        get(.arpPattern, &arpPattern)
        get(.arpLayer, &arpLayer)
        get(.arpRate, &arpRate)
        get(.repeatRate, &repeatRate)
        get(.drumKit, &drumKit)
        get(.beatStyle, &beatStyle)
        get(.beatVariation, &beatVariation)
        get(.seqRate, &seqRate)
        get(.chordSequence, &chordSequence)
        get(.bpm, &bpm)
        get(.loopBars, &loopBars)
        get(.metronome, &metronome)
        get(.metronomeLevel, &metronomeLevel)
        get(.midiIn, &midiIn)
        get(.midiOut, &midiOut)
        get(.volume, &volume)
        get(.trainerLevel, &trainerLevel)
        get(.micSampleRoot, &micSampleRoot)
        if !SoundCatalog.all.indices.contains(soundIndex) { soundIndex = 0 }
    }
}

/// The synth session saved between launches (SYNTH_SPEC §8): settings, sound, mode and the
/// four presets. Chord locks live in presets but not in the session.
public struct SynthSession: Codable, Sendable {
    public var state: SynthState
    public var presets: [SynthState?]
    /// Game mode: best accuracy (0…100) by song name.
    public var gameBest: [String: Int]?

    public init(state: SynthState, presets: [SynthState?], gameBest: [String: Int] = [:]) {
        self.state = state
        self.presets = presets
        self.gameBest = gameBest
    }

    public static func load(from url: URL) -> SynthSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SynthSession.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
