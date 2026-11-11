# PocketSynth — iOS Framework Design (rev 2)

The app has two panels:

- **Synth** — the pocket chord synth. Behavior: [SYNTH_SPEC.md](SYNTH_SPEC.md).
- **Sampler** — an MPC-style pad sampler, sequencer and arranger. Behavior: [SAMPLER_SPEC.md](SAMPLER_SPEC.md).

This doc describes how both are built on one shared core.

**Product decisions**

- Phone-native UI: the same musical behavior, with a modern full-screen layout and no artificial hardware limits.
- Landscape-first.
- Sideloaded build, not distributed through the App Store.
- A Sampler panel alongside the Synth.

## 1. Goals & constraints

- **Feature parity** with both behavioral specs.
- **Instrument-grade timing.** Touch-to-sound latency under 15 ms. Arp, sequencer, note repeat, looper and MIDI clock are sample-accurate.
- **One project, one transport, one mixer** across both panels. The Synth is an instrument inside the Sampler's world, not a separate app.
- **Testable cores.** Musical rules and the project model live in pure Swift packages that run `swift test` on macOS. DSP has an offline render harness.

**Platform**

- iOS 17+, iPhone landscape first; iPad layout in a later phase.
- Swift 6, SwiftUI + Observation; C++20 DSP via Swift–C++ interop.
- Building the app needs full Xcode. The package's tests run with just the Command Line Tools.

**Sideloading.** A free Apple ID signs builds that expire after **7 days**. A paid developer account ($99/yr) gives 1-year builds and TestFlight.

## 2. Layered architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ UI (SwiftUI, landscape)                                                    │
│  TopBar: [Synth | Sampler] · transport · BPM/tap · rec · CPU               │
│  SynthPanel: status screen · 7 pads · joystick · K/S/M · wheel             │
│  SamplerPanel: mode views (Main/Grid/List/Step/SampleEdit/ProgramEdit/      │
│                Sampler/Song/Mixer/Browser) · 4×4 pads · banks · Q-Links    │
└──────────▲───────────────────────────────────────────┬───────────────────┘
           │ observable view models                     │ ControlEvent / user intents
┌──────────┴───────────────────────────────────────────▼───────────────────┐
│ Input layer: TouchSource · GameControllerSource · MIDIInSource            │
├──────────────────────────────────────────────────────────────────────────┤
│ SynthCore (Swift)            │ SamplerCore (Swift)                         │
│  GestureInterpreter, menus,  │  Project model, programs, sequences,         │
│  modes, chord locks          │  editing commands + undo, Timing Correct,    │
│                              │  chop/convert, song, automation              │
│ ─────────── ChordTheory (Swift, shared): notes, scales, chords, Voicer ─────── │
│ ─────────── ProjectStore (Swift): .psproj packages, sample pool, autosave ── │
│            ↓ EngineCommands + immutable snapshots (sequences, programs)      │
├──────────────────────────────────────────────────────────────────────────┤
│ AudioEngine (C++ real-time, one AUAudioUnit)                               │
│  Transport/Clock ─┬─ SynthInstrument (performers, voices, synth FX chain)   │
│                   ├─ SamplerInstrument (drum/keygroup/clip voices)          │
│                   ├─ SequencerPlayer (MIDI tracks → instruments, audio trks)│
│                   ├─ Recorder (sampling, resampling, audio tracks, retro)   │
│                   └─ Mixer (channels, inserts, 8 submixes, 4 returns, master)│
│  Synth looper · metronome · vocoder · pitch detector · MIDI-out event queue  │
├──────────────────────────────────────────────────────────────────────────┤
│ DSPKit (C++ offline/worker): time-stretch, pitch-shift, onset/BPM detect,   │
│  normalize/fade/reverse…, sample-rate conversion, waveform peaks            │
├──────────────────────────────┬───────────────────────────────────────────┤
│ AudioHost (AVAudioSession +  │ MIDIBridge (CoreMIDI: virtual ports, USB,   │
│ AVAudioEngine, mic/interface)│ BLE, clock, CC map, MIDI learn)             │
└──────────────────────────────┴───────────────────────────────────────────┘
```

**Core split.** Swift decides *what* (chords, menu actions, project edits). C++ decides *when* (every note, step, loop wrap and clock tick), sample-accurately on the audio thread.

- **Swift → engine, small commands:** pad down, a parameter change, transport. These go through a lock-free SPSC queue.
- **Swift → engine, big data:** a sequence's event list, a program's pad map. Swift compiles these into **immutable snapshots** and hands them over with an atomic pointer swap. The old snapshot goes back on a release queue and is freed off the audio thread.
- **Engine → Swift:** telemetry (playhead, meters, looper/recorder state, tuner pitch, waveform-in-progress) and **recorded events**. Both travel in ring buffers: the UI reads playheads and pad lights every screen refresh (up to 120 Hz) and drains the rest at ~30 Hz.

## 3. Repository layout

All Swift and C++ modules live in **one local Swift package** with several targets. This is simpler than separate packages and keeps a single test command. (The theory module is named `ChordTheory`, because `MusicKit` collides with Apple's framework of the same name.)

```
pocketsynth/
├─ PocketSynth.xcodeproj        # iOS app target; depends on the package's PocketUI product
├─ App/PocketSynthApp.swift     # @main, just shows RootView
├─ Packages/PocketSynthKit/
│  ├─ Sources/
│  │  ├─ ChordTheory/   Key, Scale, ChordType (26), StickModifier tables, Voicer
│  │  ├─ SynthCore/     ControlEvent, SynthController (gestures/menus), SynthState,
│  │  │                 ChordResolver, EngineCommand, StickQuantizer, catalogs
│  │  ├─ SamplerCore/   DrumProgram/Pad/PadLayer model, SamplerController, ProjectStore
│  │  ├─ SynthDSP/      C++ real-time engine behind a C API (include/SynthDSP.h):
│  │  │                 Synth.hpp (voices) · Effects.hpp (FX library) · Sampler.hpp ·
│  │  │                 DSPCommon.hpp (queue, SVF, delay line, noise) · Engine.cpp (mixer, FIFO)
│  │  ├─ DSPKit/        offline audio: onset/tempo/pitch detection, stretch, processes
│  │  ├─ AudioEngine/   EngineBridge, SoundPatches, SampleLibrary (decode + peaks), AudioHost,
│  │  │                 InputMonitor, MIDIManager (CoreMIDI)
│  │  └─ PocketUI/      RootView, synth panel, sampler panel (pads, editors, mixer, song)
│  └─ Tests/            ChordTheory · SynthCore · SamplerCore · SynthDSP · DSPKit · AudioEngine
└─ docs/
```

## 4. Input layer

All sources normalize into events, so the cores never see touches.

- **ControlEvent (Synth panel):**
  - `padDown/Up(1…7)`
  - `menuDown/Up(K|S|M)`
  - `stick(dir?)`
  - `clickDown/Up`
  - `wheel(delta)`
  - `midi(...)`
- **PadEvent (Sampler panel):**
  - `padDown(index 0…15, velocity, bank)` / `padUp`
  - `pressure(index, value)`
  - plus function keys: Full Level, 16 Levels, Note Repeat, Erase, Shift, Undo, Banks.

**TouchSource**

- One multitouch `UIView` per panel's play surface, wrapped for SwiftUI. Combos like "hold pad + flick stick" or "hold Note Repeat + roll pads" need raw per-touch tracking, which SwiftUI gestures don't give.
- **Joystick:**
  - Deadzone is 30% of the radius. 8 sectors with a 6° hysteresis band, so the direction doesn't flicker on a boundary.
  - Tap inside the deadzone = click. A center hold over 250 ms = held click. Sliding out while held = click + direction.
  - Haptic tick on each direction change.
- **Sampler pads:**
  - Velocity is read from the vertical touch position (default) or from `majorRadius`. It is taken at touch-down.
  - Aftertouch comes from drift and radius change.
  - Pads keep tracking a finger that slides across them, for finger-drumming rolls.

**GameControllerSource.** Left stick = joystick, L3 = click, face/shoulder buttons = pads.

**MIDIInSource**

- Synth: notes and CCs per SYNTH_SPEC §9.
- Sampler: notes are mapped to pads or keygroups via the program's note map. MIDI-learn works for Q-Links.

## 5. Swift cores

### 5.1 ChordTheory (shared)

- Pitch math, the 10 scales, and the 26 chord types.
- `Voicer`: inversions, voice leading, bass and slash chords.
- Used by both the Synth and the Sampler's Pad Perform (chord and scale modes).

### 5.2 SynthCore

Unchanged from rev 1, except that the menus are now real touch lists *and* the combo shortcuts.

- **GestureInterpreter:** a single explicit state machine that resolves events in this order: dialog → combo → open menu → mode. It owns all the timers: hold, tap-tempo, idle.
- **ModeController:** sends `EngineCommand`s.
- **Stick modifiers:** 5 data tables.

### 5.3 SamplerCore

- **Model:** value types (`struct`), `Codable`, mirroring SAMPLER_SPEC §1.
  - Samples are referenced by `SampleID` into the pool and never embedded.
- **Edits go through `Command` objects** (`apply`/`revert`), kept in a history stack with 200+ levels. Covered:
  - event edits, track and sequence ops;
  - program parameter changes, coalesced while a knob is dragged;
  - chop markers;
  - destructive sample processes, where revert swaps back to the previous file version.
- **TimingCorrect:** pure functions (events, settings) → events. Used live (TC on input), on selections, and by the Note Repeat preview.
- **Chop:** a `ChopSession` holds markers and method settings. Detection runs in DSPKit on a background task.
  - **Smart** keeps the user's search window (`searchRange`) and the detector's answer (`snapFrame`) in the session. `AppModel` reruns `Analysis.snapOnset` (debounced 40 ms) whenever the window moves, on a copy of the sample's audio made once per chop.
  - **Convert** produces commands: new Drum program, new samples, patched-phrase keygroup, or a generated slice-replay sequence.
- **Compiler:** model → engine snapshots.
  - A `SequenceSnapshot` is a sorted, flattened event array in ticks (960 PPQN) with resolved program targets.
  - A `ProgramSnapshot` is a pad → layers table with sample buffer handles.
  - It recompiles incrementally on edits and swaps at the next block. Playback never stops for an edit.
- **Recording intake:** the engine hands back raw timestamped events. SamplerCore applies TC and overdub/replace rules, then commits them as one undoable command per take.

### 5.4 ProjectStore

- `.psproj` is a package directory containing `project.json`, `Samples/*.caf` (32-bit float) and `Versions/`.
  - It is visible in the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).
- Autosave happens 2 s after the last edit and on backgrounding.
- **Sample pool memory policy:**
  - Samples under 30 s load fully into RAM (preallocated `AudioBuffer`s, mmap-backed where possible).
  - Longer audio tracks **stream from disk**. A prefetch thread fills ring buffers 2 s ahead of the playhead.
  - Memory budget is about 1.2 GB on a 6 GB iPhone. Least-recently-used unreferenced samples are evicted.

## 6. AudioEngine (C++ real-time)

**Rules on the audio thread:** no locks, no allocation, no Swift/ObjC calls, no file I/O. All buffers come from preallocated pools.

| Component | Responsibility |
|---|---|
| **Transport / Clock** | One sample-counter timeline at 960 PPQN. Tempo map per sequence, swing. Generates 24-PPQN MIDI clock. External clock follow via a PLL. Count-in, punch, loop range |
| **SequencerPlayer** | Walks the active `SequenceSnapshot` and dispatches events with sample-accurate offsets to the target instrument (Sampler program, Synth, MIDI out). Handles Next-Sequence queuing, song-step advance, mutes/solos, automation lanes |
| **SamplerInstrument** | Voice pool of 64 stereo voices. Each voice: sample reader (cubic, or a windowed-sinc HQ option), pitch/tune, start/end/loop/reverse, warp (real-time stretch for warped pads/clips), amp + filter envelopes, multi-mode filter (TPT SVF + ladder), LFO. Mute groups and choke (fast 2 ms fade). Simult, layer selection, note repeat (engine-side, so it's tight), clip launching with quantize |
| **SynthInstrument** | The synth panel's engine from rev 1: performers (play/strum/lead/drone/arp/repeat/seq/drums/beat), a 32-voice oscillator pool (analog/FM/sample/noise/hybrid), the synth FX chain in its fixed order, the synth looper (6 tracks × 2 min), and the vocoder. Also usable as a sequencer track (Synth program) |
| **Recorder** | Sources: mic/interface input, master, any submix, the synth bus, any track. Threshold arm, pre-roll ring, monitor. Writes to a lock-free ring that a writer thread drains to a CAF file. Also records **audio tracks**, and keeps the **retrospective** event buffer (last 30 s) |
| **Mixer** | Channel strips (level/pan/mute/solo/4 inserts/4 sends/routing). 8 submixes, 4 returns, master with inserts. Peak/RMS meters into telemetry. Sidechain taps for the compressor |
| **FX library** | Shared C++ effect classes used by both the synth chain and the mixer inserts: reverb (FDN + spring), delay, chorus/flanger/phaser, compressor/limiter/gate/transient shaper, EQ, filter, drive/tape/bit-crusher. Uniform `Effect` interface: prepare/process/param ids, so the XY FX and Q-Links can address any of them |
| **MIDI out** | Events from the synth and the sequencer, plus clock, timestamped in samples → MIDIBridge |

**Hosting**

- One `AUAudioUnit` of type `aumf`. The input bus carries the mic/interface audio for sampling, the vocoder and the tuner.
- AVAudioSession runs as `.playAndRecord` with the 64-frame IO buffer preferred.
- The mic is activated only while recording, tuning or vocoding.

**CPU budget**

- Target under 50% of one performance core on an A15, at the worst case: 32 synth voices + 64 sampler voices + full inserts + 6 loops.
- The engine can split the Synth and Sampler render onto **two worker threads** via `os_workgroup` joined to the audio device's workgroup if one core isn't enough.

## 7. DSPKit (offline / worker thread)

| Job | Approach |
|---|---|
| Time-stretch & pitch-shift | Our own **WSOLA** stretch; pitch shift = stretch + resample. Signalsmith Stretch (MIT) stays an option for dense mixes and the real-time warp |
| Onset detection (Chop threshold) | Spectral-flux onset detector with an adaptive threshold; sensitivity maps to the threshold |
| Smart slice snap (Chop smart) | In the user's window, score each 128-frame boundary by its loudness step (dB, ~30 ms each side) plus the new share of its spectrum; take the best, then walk a peak-hold envelope back to where the sound leaves the quiet before it (measured 30–60 ms earlier), and back up to a zero crossing. Nothing above the threshold = no snap |
| BPM detection | Onset-envelope autocorrelation, constrained to 60–200, snapped to the loop length when it's close to whole bars |
| Pitch detection | YIN, for auto-map, mic sample, tuner |
| Processes | Normalize, fades, reverse, gain, DC removal, crop/insert/silence, bit-crush and resample, mono/stereo |
| Sample-rate conversion | Imported files are converted to 48 kHz float on import (high-quality polyphase) |
| Waveform peaks | Multi-resolution min/max pyramid, cached next to the sample, drawn by a Metal `WaveformView` so zoom stays smooth |
| Bounce / export | Offline render of the engine faster than real time (same code path, no audio device) → WAV and stems |

## 8. UI structure (landscape)

- **Top bar** (always visible):
  - a `Synth | Sampler` segmented switch;
  - play/stop/record/overdub;
  - BPM + tap;
  - sequence name;
  - CPU meter.
- Switching panels **never stops audio**; both instruments keep running.
- **Synth panel:**
  - Left: the joystick.
  - Center: the status screen (chord name, key/scale, stick mode, mode, looper tracks) with touch menus.
  - Right: the 7 chord pads and the K/S/M keys.
  - The wheel is a vertical drag strip on the far edge.
- **Sampler panel:**
  - Left sidebar: mode switcher (Main, Grid, List, Step, Sample Edit, Program Edit, Sampler, Song, Mixer, Browser).
  - Center: the active mode view.
  - Right: the 4×4 pad grid, with bank and function keys (Full Level, 16 Levels, Note Repeat, Erase, Shift, Undo).
  - A collapsible Q-Link strip of 4 knobs sits along the bottom.
- **Pad-heavy modes** (finger drumming) offer a "pads only" full-width layout.
- **iPad (later):** both panels side by side.

## 9. Testing strategy

**Swift (`swift test`, works now with Swift 6.3)**

- ChordTheory/SynthCore: a golden table of 7 pads × 8 directions × 5 stick modes; voicer tests; scripted gesture tests.
- SamplerCore:
  - command apply/revert round-trips, compared via Codable;
  - TimingCorrect tables (swing, strength, window);
  - Convert-to-program/sequence results;
  - the compiler's snapshot equality.
- ProjectStore: save → load round-trip and migration tests.

**C++ render harness (XCTest)**

- Script commands, render offline, then assert:
  - pitch (FFT peak);
  - onset timing (±1 sample) for arp, strum, sequencer and note repeat;
  - choke/mute-group cutoffs;
  - loop wrap alignment;
  - MIDI timestamps.

**DSPKit**

- Onset detection vs. labeled drum loops (precision/recall).
- Smart slice snap on synthetic audio with known starts: a voice after silence or over noise, a slow fade-in, a hit inside a held note, a same-level note change, two hits in one window, and windows with nothing in them.
- BPM detection on a reference set.
- Stretch length and pitch accuracy.

**Device**

- Latency loopback measurement.
- CPU stress project.
- XCUITests for the touch combos.

## 10. Build phases

| Phase | Synth track | Sampler track |
|---|---|---|
| **0 Skeleton** | Xcode project, packages, AudioHost, one AU, top bar + panel switch, a saw chord on pad 1 | — |
| **1 Harmony** | ChordTheory + SynthCore complete (scales, stick modes, voicing, locks, menus), golden tests | — |
| **2 Sound** | Synth engines, ADSR, FX library v1, sound list | Drum program playback: 16 pads × 8 banks, sample import, Trim edit, mixer v1 |
| **3 Time** | Clock, synth modes (strum…beat), metronome | Sequencer v1: record overdub/replace, Timing Correct, Grid editor, Note Repeat, Full Level/16 Levels, undo |
| **4 Capture** | Synth looper, presets, randomize | Sampler mode (record/resample/threshold), **Chop** (all 4 methods) + Convert, processes, DSPKit stretch/BPM |
| **5 Arrange & MIDI** | MIDI in/out/clock | Keygroup + auto-map, Synth & MIDI programs, List/Step editors, automation, Q-Links, Song mode, submixes/returns/XY FX, export (WAV/stems/MIDI) |
| **6 Extras** | Mic sample, tuner, vocoder, editors, ear trainer, rhythm game | Clip program, auto-sampler, retrospective record, audio tracks, Pad Perform, arpeggiator, stem separation (optional), iPad layout, AUv3 |

### Progress

- **Phases 0–1:** done.
- **Phase 2:** done. Notes:
  - Sample-based synth sounds (piano, strings, guitars…) are **synthesized stand-ins** in `SoundPatches.swift` until we record or license multisamples.
  - The engine is hosted with an `AVAudioSourceNode`. The `AUAudioUnit` wrapper arrives with mic input (phase 4).
  - Persistence is a single project (`Documents/PocketSynth/project.json` + `Samples/`). Named `.psproj` projects come with ProjectStore in phase 5.
  - The sampler's mixer is v1: synth, sampler and master faders plus per-pad level. Inserts, sends and submixes come in phase 5.
- **Phase 3:** done. Notes:
  - The engine renders in 32-frame sub-blocks and fires everything due inside each one (grid steps, sequence events, scheduled note-offs), so events land within 0.67 ms of their exact time.
  - One free-running beat clock drives arp, repeat, the chord sequencer, drum rolls, the beat player and note repeat. Starting the transport moves the clock to the start position (minus the count-in), so they all line up with the sequence. With the transport stopped, performers start on the first touch instead of waiting for the grid.
  - Chord-slot reference counting moved from Swift into the engine's performer, so every mode shares it.
  - Undo stores project snapshots (the project is a small value type) instead of apply/revert command pairs. Slider drags coalesce into one step. Undo never touches the sample pool, and deleting a sample clears the history because its file is gone.
  - Recording: the engine stamps live hits (and note-repeat hits) in ticks; SamplerCore applies Timing Correct and overdub/replace rules. Each take is one undo step. Sequence events within half a TC step of a live hit on the same pad are skipped, so a just-recorded note doesn't double.
  - Sequencer v1 records and edits track 1 of each sequence; the model already holds more tracks (phase 5 adds the track list).
  - Drum and beat sounds are synthesized (our own 7 kits), not samples.
  - The grid editor reads touches through a UIKit view, because SwiftUI drag gestures dropped quick successive taps.
- **Phase 5:** built and unit-tested (250 tests); simulator checks so far: new sidebar, Program › Keygroups, auto-map. Notes:
  - MIDI: the engine timestamps every outgoing event in host time (render host time + offset + output latency); a dedicated thread sends them through CoreMIDI (virtual "PocketSynth" source/destination + all devices). Incoming notes/sustain/panic go to a lock-serialized MIDI-in queue; clock, transport and the CC127-gated control CCs go to the main actor.
  - Song mode uses an engine-side queued sequence that swaps at the end of the current one (or the next bar) and restarts the playhead there.
  - Automation is played from the 30 Hz telemetry loop (fine for mixer-style moves; not sample-accurate).
  - Submix inserts are one effect each (filter, drive, crush), not four; returns are fixed effect types.
- **Phase 6:** done for v1 (what's left is listed at the end of this entry). Notes:
  - **Tuner:** the input tap also fills a small Swift ring (`InputMonitor`); the main thread runs YIN on the newest 4096 samples ~10×/s, gated at -50 dB, and `TunerSmoother` steadies the needle (a new note needs two readings in a row). Pads are silent in Tuner.
  - **Mic:** hold pad 1 to record (max 3 s, through the shared recorder). The take keeps 1 s from the first sound above -40 dB, YIN finds its pitch, and it is saved as `mic-sample.wav` and played by a new **sample engine** (`PS_ENGINE_SAMPLE`: one pitched one-shot per voice) as the hidden "Mic Sample" sound, in Lead mode. The root is the detected (fractional) pitch, so every note plays in tune; no pitch found = it plays as C. Presets keep the newest take.
  - **Trainer:** six levels in the current key. Questions play on chord slot 0, so pads 1–7 stay free for answering. Answers are compared by sound (root + pitch classes), so two stick moves that make the same chord both count. Modified-chord levels judge on pad release, with the last stick direction of the hold. Playback is timed from the 30 Hz tick (±30 ms), which is fine for listening.
  - **Game:** 10 of our own charts in 5 tiers, practice speed 50–100 %. Notes fall down each pad's column to a hit line at the bottom of the screen. The beat player gives the backing (it starts at once when the transport is stopped), and the chart's beat 0 is offset by the output latency. Windows: perfect ±50 ms, good ±120 ms. Best accuracy per song (full speed only) is saved with the session.
  - **Vocoder:** 12 band-pass bands, 160 Hz–6.4 kHz, Q 5, 4 ms / 35 ms envelope followers, plus a little of the modulator's top end for consonants. It sits after the tremolo. MIC uses a mono FIFO filled from the input ring (capped at 85 ms of backlog); LOOP uses the loops' previous 32-frame block. Turning it on switches chorus, flanger and delay off.
  - The mic is on while anything needs it (Sample view with the mic source, Tuner, Mic, MIC vocoder) and off otherwise.
  - **Sampler extras (done, tested; Retro and the Clips editor checked in the simulator):**
    - *Track arpeggiator:* engine-side, one per destination (target + program), fed by both live and sequenced notes, so a recorded track stores the input notes and the arp regenerates the pattern on playback. Up/down/up-down (incl/excl)/random/as played, 1–4 octaves, rate, gate, latch.
    - *Retrospective record:* the engine reports every live hit/note (pads, note repeat, live notes, the synth panel, MIDI in) on the free-running beat clock; Swift keeps 30 s. Capture makes a new sequence of the latest phrase (after the last silence of 2+ bars), one track per destination, optionally quantized.
    - *Audio tracks:* a track holds one clip (sample + start tick) played on hidden engine pads, cut at the sequence end; up to 16 per sequence. Audio comes from a pool sample, a synth loop ("Send loop to an audio track"), or recording the Sample view's source into the track (count-in and mic round-trip latency trimmed). No warp yet: audio plays at its own speed.
    - *Clip program:* 16 clips, loop / one-shot / gate, launched on a bar, beat or immediately; one clip per column. "Warp" is varispeed (pitch follows tempo). Clip tracks record launches as notes (start → stop).
    - *Auto-sampler:* plays notes × velocity layers on the synth (or MIDI out → audio in), records each, trims silence and builds a keygroup (zones split halfway, velocity layers).
  - **Response time:** sound first, then visuals.
    - The session asks for a 64-frame IO buffer (1.3 ms), also after the mic switches the category. `AudioHost` logs the buffer it actually got. Bluetooth outputs ignore this.
    - `CADisableMinimumFrameDurationOnPhone` lets ProMotion iPhones run at 120 Hz, so touches arrive every 8 ms instead of every 16 ms.
    - Fewer main-thread redraws, so touches don't wait behind drawing. The playhead moved out of `TransportState` into `SamplerController.playhead`, plus a once-a-beat `playheadBeat` for the bar.beat readout and grid page-follow. Playhead lines are their own small views. The synth panel and the pad grid are split into layers and cells, and their containers read only geometry. As a result the touch layers aren't rebuilt on every press, and a stick move redraws only the joystick.
    - A `CADisplayLink` (`FrameDriver`, up to 120 Hz) drives the playheads, clip and chord-step lights, and **pad lights**. The engine counts every pad that sounds (`ps_sampler_pad_hits`), so pads also light during sequence playback and note repeat. Telemetry and housekeeping still run at ~30 Hz.
  - Still to do in phase 6 (not needed for v1): synth editors, iPad layout, AUv3, (optional) stem separation, real-time warp for audio tracks and clips.
- **Phase 4:** done. Notes:
  - The looper and the recorder write into the same 2-channel `PSSample` buffers the sampler plays. The main thread allocates them; the audio thread hands them back through the garbage queue. Looper commands carry a generation number, which telemetry echoes, so the controller ignores reports older than its last command.
  - Mic input doesn't need the `AUAudioUnit` wrapper after all: an input-node tap pushes audio into a lock-free ring that the engine drains into the recorder. The session switches to play-and-record only while the Sample view uses the mic. Mic takes keep the input's own sample rate.
  - DSPKit is our own code (Accelerate only): spectral-flux onsets, onset-autocorrelation tempo with a loop-length snap, and **WSOLA** time stretch, with pitch shift = stretch + resample. It's good on drums, loops and voice; Signalsmith Stretch remains an option if we want higher quality on dense mixes.
  - Destructive processes create a new sample file and point the pads at it. The old one stays in the pool (archived, hidden) so undo works; "Discard unused audio" deletes archived versions nothing uses.
  - A process on a slice pad (a trim of a sample other pads share, as after "Slices → pads") acts on that slice only. It copies the slice to a new sample, processes it, and points just that pad at it. The shared sample and the other pads stay as they were. It is one undo step.
  - Chop converts onto the first empty bank, so existing pads aren't overwritten. "Pads + sequence" is one undo step.
  - Not done in phase 4: the looper's per-track MIDI events (phase 5, with MIDI), keygroup "patched phrase" conversion (phase 5, with keygroups), Seq-mode auto-bounce to the looper, and per-pad warp.
- **After v1:**
  - **Smart chop** (a fifth Chop method): the user drags a window over the rough spot and the slice snaps to where the sound starts (see §5.3 and §7). Unit-tested, and checked in the simulator on a test file with known starts (it found 2.300 s exactly, and 4.603 s for a voice starting at 4.600 s over noise).

## 11. IP notes

- Both panels stay free of the HiChord and MPC/Akai names, logos, skins and factory or expansion content, so a public release needs no rewrite.
- **Third-party code:** permissive licenses only (Signalsmith Stretch is MIT). GPL code (e.g. Rubber Band) would block an App Store release, so it is avoided.
