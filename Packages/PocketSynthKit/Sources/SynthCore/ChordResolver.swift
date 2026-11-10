import ChordTheory

/// Pure function from (state, pad, stick) to the voicing that pad should sound.
public enum ChordResolver {
    /// The pad's chord before octave/inversion: from its lock, or the key's diatonic triad.
    public static func baseChord(pad: Int, state: SynthState)
        -> (chord: Chord, rootNote: Int, spelling: NoteSpelling, legacy: Bool) {
        if let lock = state.locks[pad] {
            return (lock.chord, lock.rootNote, lock.spelling, lock.legacyNinthVoicing)
        }
        let degree = pad - 1
        let (offset, type) = state.scale.triad(degree: degree)
        return (Chord(root: state.key.tonic + offset, type: type),
                state.key.padRootNote(degree: degree, scale: state.scale),
                state.key.spelling, false)
    }

    /// The chord a pad plays with the stick in `direction` (nil = centered).
    public static func modifiedChord(pad: Int, state: SynthState, stick direction: StickDirection?)
        -> (chord: Chord, rootNote: Int, spelling: NoteSpelling, legacy: Bool) {
        let base = baseChord(pad: pad, state: state)
        guard direction != nil else { return base }
        let mod = StickModifier.apply(direction, mode: state.stickMode, to: base.chord.type)
        return (Chord(root: base.chord.root + mod.rootShift, type: mod.type),
                base.rootNote + mod.rootShift,
                mod.prefersFlats ? .flats : base.spelling,
                mod.legacyNinthVoicing)
    }

    public static func octaveShift(pad: Int, state: SynthState) -> Int {
        max(-3, min(3, state.globalOctave + state.padOctave[pad - 1]))
    }

    public static func voicing(pad: Int, state: SynthState, stick: StickDirection?,
                               slashBassPad: Int? = nil, previous: [Int]? = nil) -> Voicing {
        if state.mode == .lead { return leadVoicing(pad: pad, state: state, stick: stick) }
        let m = modifiedChord(pad: pad, state: state, stick: stick)
        var r = VoicingRequest(chord: m.chord, rootNote: m.rootNote)
        r.inversion = state.padInversion[pad - 1]
        r.octaveShift = octaveShift(pad: pad, state: state)
        r.voiceCount = state.voiceCount
        r.bassMode = state.bassMode
        r.legacyNinthVoicing = m.legacy
        r.spelling = m.spelling
        if let bassPad = slashBassPad {
            r.slashBassNote = baseChord(pad: bassPad, state: state).rootNote
        }
        if state.voiceLeading { r.voiceLeadFrom = previous }
        return Voicer.voice(r)
    }

    /// Lead mode: the pad's root alone. Stick ↑/↓ = ±octave, →/← = ±semitone.
    static func leadVoicing(pad: Int, state: SynthState, stick: StickDirection?) -> Voicing {
        let base = baseChord(pad: pad, state: state)
        var note = base.rootNote + 12 * octaveShift(pad: pad, state: state)
        switch stick {
        case .up: note += 12
        case .down: note -= 12
        case .right: note += 1
        case .left: note -= 1
        default: break
        }
        let spelling = state.key.spelling
        return Voicing(notes: [note], bass: nil, chord: Chord(root: note, type: .major),
                       name: PitchName.noteName(note, spelling: spelling))
    }
}
