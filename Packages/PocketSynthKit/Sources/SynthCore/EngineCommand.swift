import ChordTheory

/// What SynthCore asks the audio engine to do. The engine owns all timing (DESIGN §2):
/// SynthCore says "slot 3 now holds this voicing", and the engine's performer for the
/// current mode (play, strum, arp…) turns that into notes.
public enum EngineCommand: Equatable, Sendable {
    /// Set or clear (nil) the voicing held in a slot. Slots are pad numbers 1...7.
    case chord(slot: Int, voicing: Voicing?)
    case allNotesOff
    case mode(SynthMode)
    case sound(index: Int, engine: SoundEngineKind)
    case envelope(Envelope)
    case volume(Double)
    case tempo(Double)
    case filter(enabled: Bool, cutoffHz: Double)
    case fx(FXKind, Int)
    case glide(Glide)
    case stereo(Bool)
    case rhythm(strum: StrumSpeed, arpPattern: ArpPattern, arpLayer: ArpLayer,
                arpRate: RhythmRate, repeatRate: RhythmRate, seqRate: RhythmRate)
    // Drums & Beat modes
    case drumHit(DrumVoice, velocity: Int)
    /// Auto-repeat a drum voice; `beats` 0 stops it.
    case drumRepeat(DrumVoice, beats: Double, swing: Double)
    case drumKit(Int)
    /// Starts/switches (pattern) or stops the beat player.
    case beat(BeatPattern?, playing: Bool)
    // Seq mode
    case chordSequence([Voicing?])
    case chordSequencePlaying(Bool, length: Int)
    // Looper (the bridge allocates the buffers)
    /// First take; `bars` nil = free length.
    case looperRecordFirst(track: Int, bars: Int?, countInBeats: Int, generation: Int)
    case looperStopFirst(generation: Int)
    case looperArm(track: Int, generation: Int)
    case looperClear(track: Int, generation: Int)
    case looperPause(Bool)
    case looperGain(track: Int, gain: Double)
    case metronome(on: Bool, level: Double)
}

extension EngineCommand {
    /// Commands needed to move the engine from state `a` to state `b` (excluding chords).
    static func diff(from a: SynthState?, to b: SynthState) -> [EngineCommand] {
        var out: [EngineCommand] = []
        if a?.mode != b.mode { out += [.allNotesOff, .mode(b.mode)] }
        if a?.soundIndex != b.soundIndex { out.append(.sound(index: b.soundIndex, engine: b.sound.engine)) }
        if a?.envelope != b.envelope { out.append(.envelope(b.envelope)) }
        if a?.volume != b.volume { out.append(.volume(b.volume)) }
        if a?.bpm != b.bpm { out.append(.tempo(b.bpm)) }
        if a?.filterEnabled != b.filterEnabled || a?.filterCutoffHz != b.filterCutoffHz {
            out.append(.filter(enabled: b.filterEnabled, cutoffHz: b.filterCutoffHz))
        }
        for kind in FXKind.allCases where kind != .filter && a?.fxIndex(kind) != b.fxIndex(kind) {
            out.append(.fx(kind, b.fxIndex(kind)))
        }
        if a?.glide != b.glide { out.append(.glide(b.glide)) }
        if a?.stereo != b.stereo { out.append(.stereo(b.stereo)) }
        if a?.strumSpeed != b.strumSpeed || a?.arpPattern != b.arpPattern
            || a?.arpLayer != b.arpLayer || a?.arpRate != b.arpRate || a?.repeatRate != b.repeatRate
            || a?.seqRate != b.seqRate {
            out.append(.rhythm(strum: b.strumSpeed, arpPattern: b.arpPattern, arpLayer: b.arpLayer,
                               arpRate: b.arpRate, repeatRate: b.repeatRate, seqRate: b.seqRate))
        }
        if a?.drumKit != b.drumKit { out.append(.drumKit(b.drumKit)) }
        if a?.metronome != b.metronome || a?.metronomeLevel != b.metronomeLevel {
            out.append(.metronome(on: b.metronome, level: b.metronomeLevel))
        }
        if a?.chordSequence != b.chordSequence { out.append(.chordSequence(b.chordSequence.steps)) }
        return out
    }
}
