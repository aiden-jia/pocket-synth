# PocketSynth — Synth Panel Spec (behavioral target)

Working name: **PocketSynth**. The app has two panels: the **Synth** (this file) and the **Sampler** ([SAMPLER_SPEC.md](SAMPLER_SPEC.md)). [DESIGN.md](DESIGN.md) covers *how it's built*.

**Product decisions:** phone-native presentation (same musical behavior, modern full-screen UI, no artificial hardware limits), landscape-first, sideloaded rather than distributed through the App Store.

The target behavior is the HiChord pocket chord synth, firmware **Rev 3.0**, Batch 4+ hardware feature set. It was compiled from the manufacturer's public online manual (updater.hichord.shop/manual). We copy **functionality** only: no HiChord name, logo, industrial design, sound samples, or wording. Where the source has gaps or contradicts itself, this spec states the behavior we chose.

---

## 1. Controls (abstract)

The device has the controls below. The app represents each one as an abstract control, so touch, game controllers and MIDI can all drive it (see DESIGN §4).

| Control | Detail |
|---|---|
| Chord pads 1–7 | Not velocity sensitive (fixed velocity 100). Multi-press allowed |
| Menu buttons ×3 | **K** = Key & Settings (gray on device), **S** = Sound & FX (yellow), **M** = Mode & Tempo (red) |
| Joystick | 8 directions plus click. In confirm dialogs Up = YES and Down = NO |
| Wheel | Plain turn = master volume. With a menu button held it adjusts a parameter (§11) |
| Display | Full-resolution status area: big chord name, key/scale, stick mode, mode, BPM, looper tracks. Menus are real touch lists, and the combos below also work as shortcuts |

## 2. Harmony model

- **Key:** 12 options, default C. **Scale:** 10 options, default Major: Major, Natural Minor, Harmonic Minor, Melodic Minor, Major Pentatonic, Minor Pentatonic, Blues, Dorian, Mixolydian, Lydian.
- **Pads = diatonic triads** built by stacking scale thirds. In C Major: 1=C, 2=Dm, 3=Em, 4=F, 5=G, 6=Am, 7=B°.
  - 5- and 6-note scales build their pad chords from a 7-note parent scale (Maj Pent → Major; Min Pent and Blues → Natural Minor). The pentatonic or blues scale then filters only the melodic notes (Lead, Arp RAND).
- **Global octave** −2…+2 (K + stick ↑/↓). **Per-pad octave** −2…+2 (hold pad + K = down, hold pad + M = up). The two add together, clamped to ±3.
- **Inversion per pad:** hold pad + S cycles Root → 1st → 2nd.
- **Voice leading (V.LEAD):** when on, each chord automatically uses the inversion closest to the previous chord. The display shows "VLEAD AUTO" when you press for an inversion.
- **Voice count:** 8 / 4 / 2 / 1 oscillators. That is full and doubled / lighter / root + 1 / mono.
- **Bass:** OFF / ROOT (root −2 oct) / SLASH (5th; 3rd on minor; 4th or 2nd on sus chords; −2 oct; the display shows e.g. "Cmaj/G").
- **Slash chords:** hold pad A, then press pad B. You get chord B over the root of A (hold 1 + press 6 = Am/C). This works in Play, Strum, Drone, Arp and Repeat.
- **Chord lock:** hold pad + push stick + press S. The pad keeps that modification until you repeat the same gesture. Locks are pinned to the key active when locked. A scale change clears all locks. Locks are saved in presets but not kept across app relaunches (session state).

### 2.1 Joystick chord modifications

Hold a pad and push the stick: the chord changes while held and snaps back on release. There are five stick modes (setting `Joystick`): **STD → EXT → CHROM → BORROW → OG**.

| Dir | STD (default) | EXT | CHROM | BORROW (may move root) |
|---|---|---|---|---|
| ↑ | flip 3rd (maj↔min) | flip 3rd | m(maj7) | secondary dom: same root → 7 |
| ↗ | dom7 (b7 on major) | dom9 | 7alt | backdoor: root −2 st → 7 |
| → | maj→maj7, min→m7, dim→m7♭5 | add11 (min/dim → major first) | whole chord +1 st | passing dim7: root +1 st → °7 |
| ↘ | 9th (maj→maj9, min→m9), dim→m7♭5 | m11 | ø7 | ø7 on same root |
| ↓ | sus4 | 7♯9 | maj13 | parallel maj↔min |
| ↙ | major→6, minor→sus2 | add9 (min/dim → major first) | 6/9 | borrowed 7th: maj-family→m7, min-family→maj7 |
| ← | maj/min→dim, dim→min | 7sus4 | whole chord −1 st | flat-side major: root −1 st → major |
| ↖ | aug (min gets maj 3rd; dim→aug) | ø7 | 7♭9 | tritone sub: root +6 st → 7 |

- **OG** works like STD, except 9th chords use the legacy voicing (doubled 3rd on top).
- Minor and dim cases the table doesn't cover (e.g. STD ↗ on a minor chord, or EXT ↓ on dim) apply the chord type literally to the pad's root (↗ on Dm → D7). The golden-table tests (DESIGN §9) pin down every one of the 7 pads × 8 directions × 5 modes.

### 2.2 Chord vocabulary (26 types, semitones from root)

| Type | Intervals | Type | Intervals |
|---|---|---|---|
| maj | 0 4 7 | 7sus4 | 0 5 7 10 |
| min | 0 3 7 | m(maj7) | 0 3 7 11 |
| dim | 0 3 6 | maj9 | 0 4 7 11 14 |
| dim7 | 0 3 6 9 | m9 | 0 3 7 10 14 |
| aug | 0 4 8 | 9 | 0 4 7 10 14 |
| sus4 | 0 5 7 | 7♯9 | 0 4 7 10 15 |
| sus2 | 0 2 7 | 7♭9 | 0 4 7 10 13 |
| maj7 | 0 4 7 11 | 7alt | 0 4 8 10 15 (♯5♯9) |
| m7 | 0 3 7 10 | add9 | 0 4 7 14 |
| 7 | 0 4 7 10 | add11 | 0 4 7 17 |
| 6 | 0 4 7 9 | m11 | 0 3 7 10 17 |
| m6 | 0 3 7 9 | maj13 | 0 4 11 14 21 (5th dropped) |
| ø7 | 0 3 6 10 | 6/9 | 0 4 7 9 14 |

The voice budget is 5 chord tones + 1 bass. When a chord has more tones, the 5th is dropped first.

## 3. Sound engine

- **Polyphony:** each chord uses up to 5 tones plus bass, as on the device. Phone-native change: the voice pool is 32, so release tails overlap instead of being stolen. Each voice is a stereo pair. Each pair is a main oscillator panned L and a detuned (±5–15 cents) partner panned R. Bass is one centered oscillator. A Stereo setting switches between this spread and mono.
- **Engines:** Analog (sine, saw, square, triangle) · 2-operator FM · Sample (±24 st transpose) · Noise (white, pink, resonant, metallic) · Hybrid (stack of the others).
- **Built-in sounds (28, our own designs):** saw, saw bass (glide on), piano, tine EP, organ, strings, horns, brass, electric guitar, clarinet, flute, grand piano, retro EP, vox "ahh", vibraphone, FM EP, acoustic guitar, harp, buzz organ, humming, sine, FM "wow", synth bass, percussive "shutter", triangle, square, saw+square, ocean pad. Two hidden sounds: FM piano (quick-select only) and wind (randomize only). Sample-based sounds use samples you own or record; the device's own samples are never extracted.
- **Quick sound:** S + pad 1–7 → saw, sine, FM EP, FM piano, strings, clarinet, FM wow.
- **Envelope presets:**

| Preset | A | D | S | R |
|---|---|---|---|---|
| LONG | 800 ms | 1000 ms | 70% | 2000 ms |
| SHORT | 100 | 100 | 100% | 1000 |
| SWELL | 800 | 300 | 80% | 2000 |
| PLUCK | 5 | 80 | 0% | 180 |
| TOUCH | 25 | 260 | 66% | 50 |
| SUSTAIN | 200 | 300 | 85% | 3000; keeps ringing after release until mode or preset change |
| KEYS | 5 | 1200 | 55% | 700 |

  Fine-tune: K + wheel = attack, S + wheel = release (0.1–5000 ms). Picking a preset clears the fine-tune. Keys, piano and guitar sounds default to KEYS. Horns, brass, organ, clarinet and samples default to TOUCH.
- **Glide:** OFF / SHORT / MEDIUM / LONG.
- **LFO vibrato:** OFF / LOW / MED / HIGH. It applies to chord voices only, never the bass.
- **Low-pass filter:** 20 Hz–20 kHz. With Filter ON, M + wheel sweeps the cutoff. Resonance is editor-only.

### 3.1 Effects (fixed order)

`voices → ADSR → mix → Delay → +Bass → LP Filter → Tremolo → Vocoder → Chorus → Flanger → Gate → Drive → Tape → Reverb → Looper → Out`

| FX | Options |
|---|---|
| Reverb | OFF, ROOM, HALL, PLATE, SPRING, AMBIENT, LEGACY |
| Delay (tempo-synced) | OFF, 1/4, 1/8, 1/16, 1/16T, 1/32 |
| Chorus | OFF, LIGHT, WARM, WIDE, LUSH |
| Flanger | OFF, SLOW, JET, DEEP, METAL |
| Drive | OFF, TUBE, DRIVE, DIST, FUZZ |
| Tape | OFF, LOFI, VINYL, TAPE |
| Tremolo (synced) | OFF, 1/4, 1/8, 1/16, 1/16T, 1/32 |
| Vocoder | OFF, MIC, LOOP (12 bands; turning it on forces chorus, flanger and delay off) |

The device refuses some effect combinations because of CPU limits. We **do not emulate** those limits (DESIGN §8). The one exception: drive and tape are bypassed in drum modes, because that is a musical choice.

## 4. Modes (14)

Order: **PLAY, STRUM, LEAD, DRONE, ARP, REPEAT, SEQ, DRUMS, BEAT, GAME, TRAINER, TUNER, MIC, MIXER**. Open the list with M, then use ←/→. M + pad 1–7 quick-selects Play, Strum, Lead, Drone, Arp, Repeat, Mic. M + stick ↓ opens the mode's parameters. MIXER only appears once the looper holds audio.

| Mode | Behavior |
|---|---|
| Play | Polyphonic: the chord sounds while held |
| Strum | Notes roll root→3rd→5th→ext at 200 / 80 (default) / 40 ms. Bass sounds on the first note |
| Lead | Mono, plays the root note only, and the newest note cuts the previous one (multiple held pads sound multiple roots). Stick ↑/↓ = ±octave, →/← = ±1 semitone, snapping back; diagonals do nothing. Notes don't wrap |
| Drone | The chord latches until the mode changes. A new chord crossfades in |
| Arp | One note at a time, tempo-synced. Patterns UP, DOWN, UP/DN, DN/UP, RAND (K + pad 1–5) plus user fingerpick patterns. Layer modes ARP / CHORD+ARP / RHYTHM+ARP (K + pad 7). Rates 1/1, 1/2, 1/4, 1/8 (default), 1/16, 1/16T, 1/32, swing 8, swing 16. The release time sets the gate |
| Repeat | The chord retriggers at the arp rates, or with STUT (a 32-step gate pattern). Release is capped at 200 ms while active |
| Seq | Up to 16 chord steps in pages of 4. Each step holds root, type and bass mode. See §4.1 |
| Drums | Each pad plays a drum hit. Pick a kit with menu + pad. Hold a pad + push the stick to auto-repeat it at a rate set by the direction: ↑ 1/4, → 1/8, ↓ 1/16, ← 1/32, ↗ swing 8, ↘ swing 16, ↙ 1/16T, ↖ 1/8T |
| Beat | 7 styles (rock, break, dub, funk, house, dembow, swing) × 8 variations (orig, ghost, 16th, push, fill, half, double, perc). A pad starts, stops or switches the style. Hold the pad + ↑/↓ for variation. Click bounces the beat to the looper |
| Game | Rhythm game: chords scroll to a hit line. 10 songs in 5 tiers, practice speed 50–100%. **Our own songs and design** |
| Trainer | Ear training in 6 levels: interval up; interval up/down; diatonic triad; 4-chord progression; modified chord; modified progression |
| Tuner | Chromatic tuner using the mic |
| Mic | Hold pad 1 to record (up to 3 s; the app keeps 1 s from the first sound). The take is pitch-detected and transposed to C, then the app switches to Lead |
| Mixer | Pad 1–6 tap = mute. Hold + wheel = level. Hold + S = solo. Pad 7 = metronome on/off; hold 7 + wheel = metronome level. Click = stop/start all |

**Rhythm details.** Swing rates (S8, S16, ↗/↘ rolls) use 62 %. "Hold →" in Seq mode is a stick push released without pressing a pad, so a push *with* a pad stores a modified chord instead. The arp gate is the release time, kept between 10 % and 95 % of the step. CHORD+ARP and RHYTHM+ARP play the arp an octave up so it doesn't collide with the held chord.

**Looper details.** The looper cursor moves with the stick when nothing is held and no menu is open: ←/→ pick a track, ↓ the transport, ↑ back. Loop length is a setting (Sound › ↑ › LOOP: FREE or 1–8 bars). The first take can go on any track when no loop exists yet. In Mixer mode a pad tap mutes; holding a pad for solo or level doesn't. In Beat mode the click records the beat into the looper like any other take.

**Sequencer controls.** Press a pad to fill the cursor step. Hold → to advance; holding → on the last step adds one. Stick + pad stores a modified chord. Editing only works while stopped. Click = play/stop, quantized to the looper's loop point if one is playing. Hold ↓ / ↑ = next / previous page; ↑ on page 1 cycles the rhythm rate. Hold click + ↑ for 1 s trims empty steps. Leaving the mode while playing auto-bounces the sequence to the looper.

## 5. Looper

- 6 tracks, no overdub and no undo. Phone-native change: up to 2 minutes per track (the device allows about 20 s). Each track records **audio** (post-FX) **plus the MIDI events**, which play back on track N's MIDI channel N.
- Track 1 sets the length: FREE or 1–8 bars, default 4. Bar mode gives a 4-beat count-in; FREE arms and starts on the first chord. Track 1 stops itself at the bar end.
- Any loop can be sent to the Sampler as a sample, or as an audio track.
- Tracks 2–6: click arms the track (WAITING), recording starts at track 1's loop point and lasts one pass, then the looper auto-advances to the next empty track. A click while waiting cancels.
- States: OFF → WAITING → RECORD → LOOP. On a playing track, click then hold 0.7 s clears it; clearing the last playing track resets the whole looper.
- Transport (position 7, stick ↓): click = pause/resume with a tape-stop effect. Hold 0.7 s = clear all.
- Display: 2 tracks per page × 3 pages.
- The metronome is on by default. The looper is disabled in Seq mode.

## 6. Tempo & clock

BPM 40–300 (M + ↑ opens the BPM menu). Tapping M three times sets tap tempo. MIDI clock goes out at 24 PPQN at all times, with Start and Stop following the internal timeline. With MIDI In on, the tempo follows incoming clock and holds the last tempo about 0.5 s after the clock stops.

## 7. Randomize (menu held + click)

- **S:** new sound and FX.
- **K:** sound, FX, key and tempo. Tempo is kept while the looper has audio.
- **M:** new arp pattern, voicing and sequence.

S and K randomize are refused while a looper track is recording.

## 8. Presets & library

- 4 quick slots: open the preset menu, use ←/→ for the slot, ↑ = save, ↓ = load, then confirm. A save is skipped while recording. A preset is a full session snapshot of 100+ parameters, including chord locks plus the scale they were locked in, and the sequence.
- Sound library: **unlimited** in-app (the device has 32 slots). User samples are imported from Files and trimmed to ~1.4 s, with a root note set by the user.
- Session state (loops, sound, key, tempo, mode) is restored on relaunch. The device loses its session on power-off; the app keeps it, because a phone app should survive being backgrounded.

## 9. MIDI

| Out | Detail |
|---|---|
| Live playing | On the channel of the layer being built: ch 1 with an empty looper; the next empty track's channel after each take; ch 7 when all 6 tracks are full |
| Loop playback | Track N → channel N |
| Drums | Channel 10, GM notes: kick 36, snare 38, closed hat 42, tom 45, open hat 46, cowbell 56 |
| Notes | Full voicing including bass (when on). Arp, repeat and strum send each event as it sounds |
| Velocity | Fixed at 100 |
| Clock | 24 PPQN plus Start/Stop |

| In (default OFF) | Detail |
|---|---|
| Notes | Play the current sound with velocity. In Drums mode, GM drum notes |
| CC 64 | Sustain |
| CC 120/123 | Panic |
| Clock | Tempo follow |
| Control CCs | Only after CC127=1 on that channel (CC127=0 releases). 20+50 = BPM (MSB/LSB), 21 = key, 22 = octave, 29 = cutoff, 31 = reverb; the full map is ours to define |

## 10. Not carried over (hardware-only)

The 64×32 OLED look, the 6-voice stealing, the 20 s loop cap, battery meter, sleep, calibration, firmware/DFU, TRS-MIDI jack mode, the speaker toggle, output level HOT/LINE (replaced by an output gain), USB audio class (replaced by AUv3 / Inter-device audio), the CPU-protect refusals, and the web companion app (its editors become in-app screens).

## 11. Combo reference

| Gesture | Action |
|---|---|
| K tap | Key menu: ←/→ key, ↑/↓ global octave |
| K + wheel / S + wheel / M + wheel | attack / release / filter cutoff |
| S tap | Sound list ←/→; ↑ = FX & settings list; ↓ = back |
| S + pad 1–7 | Quick sound (in Drums/Beat: select kit) |
| M tap | Mode list ←/→; ↓ = mode params; ↑ = BPM |
| M ×3 fast | Tap tempo |
| M + pad 1–7 | Quick mode |
| K/S/M held + click | Randomize all / sound / pattern |
| pad + K / pad + M | That pad's octave −1 / +1 |
| pad + S | Cycle that pad's inversion |
| pad + stick + S | Toggle chord lock |
| K + S together | Preset menu |
| any pad press | Closes the open menu and plays the chord |
| idle 5 s | Closes the K menu and the preset menu |
