import Testing
@testable import ChordTheory

/// Name of the chord a pad plays with the stick pushed (mirrors SynthCore's resolver).
func padChord(_ pad: Int, key: Key = .c, scale: Scale = .major,
              _ dir: StickDirection? = nil, mode: StickMode = .standard) -> String {
    let (offset, base) = scale.triad(degree: pad - 1)
    let mod = StickModifier.apply(dir, mode: mode, to: base)
    let spelling: NoteSpelling = mod.prefersFlats ? .flats : key.spelling
    return Chord(root: key.tonic + offset + mod.rootShift, type: mod.type).name(spelling: spelling)
}

@Suite("Diatonic pads")
struct DiatonicTests {
    @Test func cMajor() {
        #expect((1...7).map { padChord($0) } == ["C", "Dm", "Em", "F", "G", "Am", "B°"])
    }

    @Test func aNaturalMinor() {
        #expect((1...7).map { padChord($0, key: Key(9), scale: .naturalMinor) }
                == ["Am", "B°", "C", "Dm", "Em", "F", "G"])
    }

    @Test func aHarmonicMinor() {
        #expect((1...7).map { padChord($0, key: Key(9), scale: .harmonicMinor) }
                == ["Am", "B°", "C+", "Dm", "E", "F", "G♯°"])
    }

    @Test func dDorian() {
        #expect((1...7).map { padChord($0, key: Key(2), scale: .dorian) }
                == ["Dm", "Em", "F", "G", "Am", "B°", "C"])
    }

    @Test func pentatonicUsesParentScale() {
        #expect((1...7).map { padChord($0, scale: .majorPentatonic) }
                == (1...7).map { padChord($0, scale: .major) })
        #expect((1...7).map { padChord($0, scale: .blues) }
                == (1...7).map { padChord($0, scale: .naturalMinor) })
    }

    @Test func flatKeySpelling() {
        #expect(padChord(4, key: Key(5)) == "B♭")
        #expect(Key(10).name == "B♭")
        #expect(Key(6).name == "F♯")
    }

    @Test func padRootRegister() {
        #expect(Key.c.padRootNote(degree: 0, scale: .major) == 60)
        #expect(Key(7).padRootNote(degree: 0, scale: .major) == 55) // G3
        #expect(Key(6).padRootNote(degree: 0, scale: .major) == 66) // F♯4
    }
}

@Suite("Stick modifiers (golden table)")
struct StickTests {
    // Expected results for pad 1 (C), pad 2 (Dm) and pad 7 (B°) in C major, by direction.
    // Order: ↑ ↗ → ↘ ↓ ↙ ← ↖
    @Test func standard() {
        let dirs = StickDirection.allCases
        #expect(dirs.map { padChord(1, $0) }
                == ["Cm", "C7", "Cmaj7", "Cmaj9", "Csus4", "C6", "C°", "C+"])
        #expect(dirs.map { padChord(2, $0) }
                == ["D", "D7", "Dm7", "Dm9", "Dsus4", "Dsus2", "D°", "D+"])
        #expect(dirs.map { padChord(7, $0) }
                == ["B", "B7", "Bø7", "Bø7", "Bsus4", "Bsus2", "Bm", "B+"])
    }

    @Test func extended() {
        #expect(StickDirection.allCases.map { padChord(1, $0, mode: .extended) }
                == ["Cm", "C9", "Cadd11", "Cm11", "C7♯9", "Cadd9", "C7sus4", "Cø7"])
        // Minor and dim chords become major for add11/add9.
        #expect(padChord(2, .right, mode: .extended) == "Dadd11")
        #expect(padChord(7, .downLeft, mode: .extended) == "Badd9")
    }

    @Test func chromatic() {
        #expect(StickDirection.allCases.map { padChord(1, $0, mode: .chromatic) }
                == ["Cm(maj7)", "C7alt", "C♯", "Cø7", "Cmaj13", "C6/9", "B", "C7♭9"])
        #expect(padChord(6, .right, mode: .chromatic) == "A♯m") // quality kept
        #expect(padChord(6, .left, mode: .chromatic) == "A♭m")
    }

    @Test func borrowExamplesFromSpec() {
        #expect(padChord(2, .up, mode: .borrow) == "D7")       // secondary dominant
        #expect(padChord(1, .upRight, mode: .borrow) == "B♭7") // backdoor
        #expect(padChord(4, .right, mode: .borrow) == "F♯°7")  // passing dim
        #expect(padChord(2, .downRight, mode: .borrow) == "Dø7")
        #expect(padChord(4, .down, mode: .borrow) == "Fm")     // parallel
        #expect(padChord(4, .downLeft, mode: .borrow) == "Fm7")
        #expect(padChord(7, .left, mode: .borrow) == "B♭")     // flat-side major
        #expect(padChord(2, .left, mode: .borrow) == "D♭")
        #expect(padChord(5, .upLeft, mode: .borrow) == "D♭7")  // tritone sub
    }

    @Test func legacyMatchesStandardExceptNinthVoicing() {
        for pad in 1...7 {
            for dir in StickDirection.allCases {
                #expect(padChord(pad, dir, mode: .legacy) == padChord(pad, dir))
            }
        }
        #expect(StickModifier.apply(.downRight, mode: .legacy, to: .major).legacyNinthVoicing)
        #expect(!StickModifier.apply(.downRight, mode: .standard, to: .major).legacyNinthVoicing)
        #expect(!StickModifier.apply(.right, mode: .legacy, to: .major).legacyNinthVoicing)
    }

    @Test func everyCombinationProducesAValidChord() {
        for mode in StickMode.allCases {
            for type in ChordType.allCases {
                for dir in StickDirection.allCases {
                    let m = StickModifier.apply(dir, mode: mode, to: type)
                    #expect(m.type.intervals.count <= 5)
                    #expect((-6...6).contains(m.rootShift))
                }
            }
        }
    }

    @Test func vocabularyHas26Types() {
        #expect(ChordType.allCases.count == 26)
        #expect(Set(ChordType.allCases.map(\.suffix)).count == 26)
    }
}

@Suite("Voicer")
struct VoicerTests {
    func request(_ root: Int, _ type: ChordType, note: Int) -> VoicingRequest {
        VoicingRequest(chord: Chord(root: root, type: type), rootNote: note)
    }

    @Test func inversions() {
        var r = request(0, .major, note: 60)
        #expect(Voicer.voice(r).notes == [60, 64, 67])
        r.inversion = .first
        #expect(Voicer.voice(r).notes == [64, 67, 72])
        r.inversion = .second
        #expect(Voicer.voice(r).notes == [67, 72, 76])
    }

    @Test func octaveShift() {
        var r = request(0, .major, note: 60)
        r.octaveShift = 1
        #expect(Voicer.voice(r).notes == [72, 76, 79])
    }

    @Test func bassModes() {
        var r = request(0, .major, note: 60)
        r.bassMode = .root
        #expect(Voicer.voice(r).bass == 36)
        r.bassMode = .slash
        let v = Voicer.voice(r)
        #expect(v.bass == 43)
        #expect(v.name == "C/G")

        var m = request(9, .minor, note: 69)
        m.bassMode = .slash
        let am = Voicer.voice(m)
        #expect(am.bass == 48)
        #expect(am.name == "Am/C")
    }

    @Test func slashChordFromSecondPad() {
        var r = request(9, .minor, note: 69)
        r.slashBassNote = 60
        let v = Voicer.voice(r)
        #expect(v.name == "Am/C")
        #expect(v.bass == 36)
        #expect(v.allNotes == [36, 69, 72, 76])
    }

    @Test func voiceCountDropsFifthFirst() {
        var r = request(0, .major9, note: 60)
        #expect(Voicer.voice(r).notes == [60, 64, 67, 71, 74])
        r.voiceCount = .four
        #expect(Voicer.voice(r).notes == [60, 64, 71, 74])
        r.voiceCount = .two
        #expect(Voicer.voice(r).notes == [60, 64])
        r.voiceCount = .one
        #expect(Voicer.voice(r).notes == [60])
    }

    @Test func legacyNinthDoublesThird() {
        var r = request(0, .major9, note: 60)
        r.legacyNinthVoicing = true
        #expect(Voicer.voice(r).notes == [60, 64, 71, 74, 76])
    }

    @Test func voiceLeadingPicksNearestInversion() {
        var r = request(5, .major, note: 65)          // F after C
        r.voiceLeadFrom = [60, 64, 67]
        #expect(Voicer.voice(r).notes == [60, 65, 69]) // F/C shape, 3 semitones of motion
        var g = request(7, .major, note: 67)          // G after C
        g.voiceLeadFrom = [60, 64, 67]
        #expect(Voicer.voice(g).notes == [59, 62, 67])
    }

    @Test func voiceLeadingDoesNotDrift() {
        // Cycle through the circle of fifths many times and stay in range.
        var prev = [60, 64, 67]
        for step in 0..<48 {
            let pc = (step * 7) % 12
            var r = request(pc, .major, note: 60 + pc)
            r.voiceLeadFrom = prev
            prev = Voicer.voice(r).notes
            #expect(prev.allSatisfy { (48...84).contains($0) })
        }
    }
}
