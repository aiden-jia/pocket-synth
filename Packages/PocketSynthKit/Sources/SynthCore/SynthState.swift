import ChordTheory

/// A pad pinned to a specific chord, independent of later key changes.
public struct ChordLock: Hashable, Codable, Sendable {
    public var chord: Chord
    /// MIDI root note at lock time (before octave shifts).
    public var rootNote: Int
    public var legacyNinthVoicing: Bool
    public var spelling: NoteSpelling
}

/// The Seq mode's chord steps (SYNTH_SPEC §4): up to 16, each a stored voicing or a rest.
public struct ChordSequence: Hashable, Codable, Sendable {
    public static let maxSteps = 16
    public static let pageSize = 4

    public var steps: [Voicing?] = Array(repeating: nil, count: 4)

    public init() {}

    public var length: Int { steps.count }

    /// Drops empty steps from the end (at least one step stays).
    public mutating func trimEmptyTail() {
        while steps.count > 1, steps.last! == nil { steps.removeLast() }
    }
}

/// Everything a preset captures (SYNTH_SPEC §8). Plain value type: easy to diff, save, test.
public struct SynthState: Hashable, Codable, Sendable {
    // Harmony
    public var key: Key = .c
    public var scale: Scale = .major
    public var globalOctave = 0                 // -2...2
    public var padOctave = [Int](repeating: 0, count: 7)          // -2...2, index pad-1
    public var padInversion = [Inversion](repeating: .root, count: 7)
    public var locks: [Int: ChordLock] = [:]    // pad -> lock
    public var stickMode: StickMode = .standard
    public var voiceCount: VoiceCount = .eight
    public var bassMode: BassMode = .off
    public var voiceLeading = false

    // Sound
    public var soundIndex = 0
    public var envelopePreset: EnvelopePreset = .short
    public var attackOverrideMs: Double?
    public var releaseOverrideMs: Double?
    public var glide: Glide = .off
    public var stereo = true
    public var fx: [FXKind: Int] = [:]          // option index, absent = OFF
    public var filterCutoffHz = 20_000.0

    // Mode & tempo
    public var mode: SynthMode = .play
    public var strumSpeed: StrumSpeed = .medium
    public var arpPattern: ArpPattern = .up
    public var arpLayer: ArpLayer = .arpOnly
    public var arpRate: RhythmRate = .eighth
    public var repeatRate: RhythmRate = .eighth
    public var drumKit = 1                      // 1...7
    public var beatStyle: BeatStyle = .rock
    public var beatVariation: BeatVariation = .original
    public var seqRate: RhythmRate = .quarter
    public var chordSequence = ChordSequence()
    public var bpm = 120.0
    /// Looper first-take length: 0 = free, else bars (SYNTH_SPEC §5).
    public var loopBars = 4
    public var metronome = true
    public var metronomeLevel = 0.6

    // Tools (phase 6)
    public var trainerLevel: TrainerLevel = .intervalUp
    /// Pitch (fractional MIDI note) of the Mic-mode sample; nil = none recorded yet.
    public var micSampleRoot: Double?

    // Settings
    public var midiIn = false
    public var midiOut = true
    public var volume = 0.8

    public init() {}

    public var envelope: Envelope {
        var e = envelopePreset.envelope
        if let a = attackOverrideMs { e.attackMs = a }
        if let r = releaseOverrideMs { e.releaseMs = r }
        if mode == .repeat { e.releaseMs = min(e.releaseMs, 200) }
        return e
    }

    public func fxIndex(_ kind: FXKind) -> Int { fx[kind] ?? 0 }

    public var filterEnabled: Bool { fxIndex(.filter) == 1 }

    public var sound: SoundInfo { SoundCatalog.all[soundIndex] }

    /// Changing scale clears chord locks (SYNTH_SPEC §2).
    public mutating func setScale(_ newScale: Scale) {
        if newScale != scale { locks.removeAll() }
        scale = newScale
    }

    public mutating func selectSound(_ index: Int) {
        soundIndex = index
        envelopePreset = sound.defaultEnvelope
        attackOverrideMs = nil
        releaseOverrideMs = nil
    }
}

/// Rows of the Sound → ↑ list: effects first, then settings (SYNTH_SPEC §3.1, §11).
public enum SettingRow: Hashable, CaseIterable, Sendable {
    case fx(FXKind)
    case voice, envelope, bass, glide, scale, voiceLeading, stereo, stickMode, loopLength, metronome, midiIn, midiOut

    public static var allCases: [SettingRow] {
        FXKind.allCases.map { .fx($0) }
            + [.voice, .envelope, .bass, .glide, .scale, .voiceLeading, .stereo, .stickMode, .loopLength, .metronome, .midiIn, .midiOut]
    }

    public var title: String {
        switch self {
        case .fx(let k): k.label
        case .voice: "VOICE"
        case .envelope: "ADSR"
        case .bass: "BASS"
        case .glide: "GLIDE"
        case .scale: "SCALE"
        case .voiceLeading: "V.LEAD"
        case .stereo: "STEREO"
        case .stickMode: "JOYSTICK"
        case .loopLength: "LOOP"
        case .metronome: "METRONOME"
        case .midiIn: "MIDI IN"
        case .midiOut: "MIDI OUT"
        }
    }

    public var options: [String] {
        switch self {
        case .fx(let k): k.options
        case .voice: VoiceCount.allCases.map(\.label)
        case .envelope: EnvelopePreset.allCases.map(\.label)
        case .bass: BassMode.allCases.map(\.label)
        case .glide: Glide.allCases.map(\.label)
        case .scale: Scale.allCases.map(\.displayName)
        case .voiceLeading, .stereo, .midiIn, .midiOut, .metronome: ["OFF", "ON"]
        case .stickMode: StickMode.allCases.map(\.shortName)
        case .loopLength: ["FREE"] + (1...8).map { "\($0) BAR" + ($0 == 1 ? "" : "S") }
        }
    }

    public func value(in s: SynthState) -> Int {
        switch self {
        case .fx(let k): s.fxIndex(k)
        case .voice: VoiceCount.allCases.firstIndex(of: s.voiceCount)!
        case .envelope: EnvelopePreset.allCases.firstIndex(of: s.envelopePreset)!
        case .bass: BassMode.allCases.firstIndex(of: s.bassMode)!
        case .glide: Glide.allCases.firstIndex(of: s.glide)!
        case .scale: Scale.allCases.firstIndex(of: s.scale)!
        case .voiceLeading: s.voiceLeading ? 1 : 0
        case .stereo: s.stereo ? 1 : 0
        case .stickMode: StickMode.allCases.firstIndex(of: s.stickMode)!
        case .loopLength: max(0, min(8, s.loopBars))
        case .metronome: s.metronome ? 1 : 0
        case .midiIn: s.midiIn ? 1 : 0
        case .midiOut: s.midiOut ? 1 : 0
        }
    }

    public func set(_ i: Int, in s: inout SynthState) {
        switch self {
        case .fx(let k):
            s.fx[k] = i == 0 ? nil : i
            // Turning the vocoder on forces chorus, flanger and delay off (SYNTH_SPEC §3.1).
            if k == .vocoder, i != 0 { s.fx[.chorus] = nil; s.fx[.flanger] = nil; s.fx[.delay] = nil }
        case .voice: s.voiceCount = VoiceCount.allCases[i]
        case .envelope:
            s.envelopePreset = EnvelopePreset.allCases[i]
            s.attackOverrideMs = nil   // picking a preset clears fine-tune
            s.releaseOverrideMs = nil
        case .bass: s.bassMode = BassMode.allCases[i]
        case .glide: s.glide = Glide.allCases[i]
        case .scale: s.setScale(Scale.allCases[i])
        case .voiceLeading: s.voiceLeading = i == 1
        case .stereo: s.stereo = i == 1
        case .stickMode: s.stickMode = StickMode.allCases[i]
        case .loopLength: s.loopBars = i
        case .metronome: s.metronome = i == 1
        case .midiIn: s.midiIn = i == 1
        case .midiOut: s.midiOut = i == 1
        }
    }

    public func cycle(in s: inout SynthState) {
        set((value(in: s) + 1) % options.count, in: &s)
    }
}
