# PocketSynth — Sampler Panel Spec (behavioral target)

This is the second main panel. It is an MPC-style pad sampler, sequencer and arranger. The behavioral target is the standalone **Akai MPC 2.x–3.x** feature set (MPC One/Live/X class). This spec comes from general knowledge of that workflow, not from a single manual, so treat the exact values (counts, ranges) as targets to tune.

As with the synth, we reproduce **functionality**, not trade dress: no MPC/Akai name or logo, no product layout or skins, and no factory or expansion content.

Shared with the synth panel: transport/BPM/clock, sample pool, mixer, FX library, MIDI, and project file. See §11 for how the two panels connect.

---

## 1. Data model

```
Project
├─ Sample pool          (all audio in the project, de-duplicated)
├─ Programs             (instruments: Drum · Keygroup · Clip · Synth · MIDI)
├─ Sequences 1…128      (each: tempo, time sig, length 1–999 bars, loop range)
│   └─ Tracks 1…128     (MIDI-type → a Program  |  Audio-type → recorded audio)
├─ Song                 (ordered list of sequence steps × repeats)
└─ Mixer state          (channels, 8 submixes, 4 returns, master, FX)
```

## 2. Pads

- **16 pads in a 4×4 grid, 8 banks A–H** (128 pads per program).
  - Bank buttons sit beside the grid. Shift + bank goes to banks E–H.
- **Velocity on a touch screen** (setting):
  - **Position:** the vertical touch position inside the pad, top = loud. This is the default.
  - **Touch size:** `UITouch.majorRadius`.
  - **Fixed:** 100.
- **Pressure:** finger drift and radius change after the initial touch send aftertouch, if enabled.
- **Full Level:** every hit plays at velocity 127.
- **16 Levels:** the last-hit pad is spread across all 16 pads, and one parameter steps across them. Parameter choices: velocity, tune, filter cutoff, layer, attack, decay.
- **Note Repeat:**
  - Hold the NR button, or latch it, and held pads retrigger at 1/4, 1/4T, 1/8, 1/8T, 1/16, 1/16T, 1/32, 1/32T.
  - Follows sequence swing.
  - Pressure or position controls the velocity of the repeats.
- **Pad Perform** (on Keygroup/Synth/MIDI tracks) turns the pads into:
  - **Notes:** scale-locked, with a selectable root and scale.
  - **Chords:** chord sets and progressions, built on the synth's ChordCore.
  - **Chromatic.**
- **Pad Mute / Pad Solo**, **Track Mute / Solo**, and mute groups. "Next Sequence" mode queues a sequence switch for the next bar.
- **Erase:** hold Erase + pad during playback to delete that pad's events as the playhead passes. Hold Erase + tap to clear the whole track.
- **Copy, paste and swap pads.** Swapping keeps the sequence events.

## 3. Programs

### 3.1 Drum program (per pad)

| Group | Parameters |
|---|---|
| Layers | Up to **4 layers per pad**. Each layer has sample, slice, level, pan, coarse/fine tune, start/end offsets, direction (fwd/rev), and velocity range. Layer play mode: velocity / cycle / random |
| Trigger | One-shot / note-on (gated). Poly / mono. Mute group 0–32 (choke). **Simult**: link up to 4 pads that fire together |
| Amp env | AHDS (one-shot) or ADSR (note-on). Velocity → level, attack, start |
| Filter | Off, LP 2/4/8-pole, HP 2/4, BP, band-stop, plus 2–3 "vintage" characters. Cutoff, resonance, env amount, velocity → cutoff, key-track |
| Filter env | ADSR |
| LFO | Sine/tri/saw/square/S&H, synced or free. Targets: pitch, cutoff, level, pan |
| Warp | Time-stretch the sample to project BPM, while keeping pitch |
| Mixer | Level, pan, output (master/submix 1–8), 4 send levels, **4 insert FX per pad** |

### 3.2 Keygroup program

- Up to **128 keygroups**. Each has a key range, root note, 4 velocity layers, and the same envelope/filter/LFO/FX block as a drum pad.
- Played chromatically from pads (Pad Perform), a MIDI keyboard, or the on-screen keyboard.
- **Auto-map:** detects each sample's root pitch (YIN), then spreads samples across the keyboard.
- **Auto-sampler:** records the synth panel, or external MIDI gear, at every N semitones × velocity levels, then builds a keygroup from the takes.
- Polyphony up to 32. Mono and legato modes with glide.

### 3.3 Clip program

- 16 pads of clips: loops that launch in sync, quantized to 1 bar, 1 beat, or immediate.
- Each pad's mode is loop, one-shot or gate. Clips are warped to BPM.
- One clip per column group plays at a time.

### 3.4 Synth program

The synth panel's engine as a sequencer instrument. A track can play the full chord engine:
- Notes or chords from Pad Perform, or the synth's own 7-pad and joystick surface.
- Any synth sound or preset.

### 3.5 MIDI program

Sends the track to an external MIDI port and channel, with program change on load.

## 4. Sampling (Sampler mode)

- **Source:**
  - mic, or an audio interface input (any channel pair);
  - **Resample:** master bus, a submix, the synth panel only, or one track.
- **Arming:**
  - mono or stereo;
  - threshold arm (shown as a dB line on the meter);
  - pre-roll capture of 0–500 ms;
  - maximum length up to available memory;
  - monitor on/off; input gain.
- **After recording:**
  - auto-trim leading silence;
  - name the sample;
  - auto-assign it to the selected pad or a new program;
  - choose whether to open Sample Edit.
- **Retrospective record:** the app always captures the last ~30 s of played pad, MIDI and synth events. One button turns them into a sequence, quantized if you want.

## 5. Sample Edit

### 5.1 Trim mode

- Start, end and loop markers, plus loop crossfade.
- Waveform with pinch zoom and a scrubbing playhead.
- Snap to zero crossings on or off.
- Audition from the start or from the playhead.

### 5.2 Chop mode (slicing)

| Method | Detail |
|---|---|
| **Threshold** ("Hits" in the app) | Transient detection by spectral flux. A sensitivity slider gives a live slice count. A minimum slice length prevents double hits |
| **Regions** | Divides the sample into N equal slices (2–128) |
| **BPM / Beat grid** | Uses the detected or entered BPM. Slices every 1/4, 1/8 or 1/16 beat, or per bar |
| **Smart** | Tap near where a sound starts. A search window appears there: 300 ms (a tenth of the sample if that is shorter, at least 20 ms), with a handle just outside each edge. Drag inside the window to move it, drag a handle to resize it, or tap elsewhere to move it there at the same width. As it moves, the detector marks where the strongest new sound in it starts (a vocal coming in, a hit, a note change) with a dashed line and the time. The mark sits on the first audible sample, backed up to a zero crossing, and can be up to ~50 ms before the window when the sound began just before it. *Add slice* places a marker there and plays the slice; it greys out when a slice already starts there. Tap inside the window to hear from the mark first. "Nothing starts here" means the window holds no clear start. Existing markers stay, and you can drag them as in Manual |
| **Manual** | Tap the waveform to add a slice. Drag markers to move them; split or merge the selected slice; delete |

- Slices map to pads automatically: slice 1 is on pad A01.
- Pads play their slice live while you edit.
- Each slice can be set to non-destructive (start/end references) and to one-shot or note-on.
- Processes on a slice pad change that slice only (§5.3), so each slice can be pitch-shifted or stretched on its own.
- **Convert** a chop into one of:
  - a new **Drum program** with non-destructive slice references;
  - **Extract as new samples**, one file per slice;
  - a **Patched phrase**: a keygroup that plays the whole loop and stretches with BPM;
  - a **Sequence**: generates a MIDI track that replays the slices in their original order and timing. This gives the classic "chop, then re-sequence" workflow.

### 5.3 Processes (destructive and undoable)

Normalize, Reverse, Gain ±, Fade in/out (curve), Silence, Insert silence, Crop, Delete, Copy/Paste/Mix-paste, DC removal, Pitch shift (±24 st, keep length), Time stretch (to BPM or %, keep pitch), BPM detect, Bit-crush/Resample (lo-fi), Convert to mono/stereo, Discard unused audio.

Every destructive process writes a new file version, so undo is possible.

A process on a slice pad acts on that slice only. When a pad plays part of a sample that other pads also use, the slice is copied into a new sample and processed there. Only that pad moves to the result, from start to end. The other pads keep their sample and trims. The trim-based processes (crop, delete, silence, fades) treat the whole slice as the trim. Pads that play the whole sample, or are its only user, still change the sample for everything that uses it.

## 6. Sequencer

| Feature | Detail |
|---|---|
| Sequences | Up to 128. Length 1–999 bars, time signature, per-sequence tempo or the master tempo, loop on/off with a loop range |
| Tracks | Up to 128 per sequence. MIDI-type (bound to a program) or Audio-type (recorded/imported audio, warpable) |
| Recording | **Overdub** or **Replace**, with a count-in (off/1/2 bars) and metronome options. **Auto-punch** in/out. **Step record**. **Live erase** |
| **Timing Correct** | Note value 1/8–1/32 with triplets, swing 50–75%, strength 0–100%, window, shift timing. Applied at record time ("TC on input") or after the fact to a selection |
| Grid editor | Drum lanes per pad, or a piano roll. Draw / select / move / length / velocity tools. Velocity and parameter lanes. Nudge. Quantize the selection. Duplicate. Humanize |
| List editor | Event list: time / type / pad or note / velocity / length. Shows note, CC, aftertouch, program change and pitch bend |
| Step sequencer | 16 steps per page (1/16 by default; the step resolution can be changed). Pads act as step toggles for the selected pad's lane |
| Automation | Per-track parameter automation (mixer, FX, program params, Q-Links). Read / Write / Latch per track, with a global R/W toggle |
| Editing | Insert/delete bars, copy/paste bars, double the sequence length, transpose, velocity scale, split and merge tracks |
| Undo | A history list with 100+ steps. Every edit is a command |
| Arpeggiator | Per track, for keygroup and synth tracks. Up/down/incl/excl/random/order, octave range, gate, rate, latch |

## 7. Song mode

- An ordered list of sequence steps, each with a repeat count, edited by drag-reorder.
- Plays straight through or loops.
- **Convert song to sequence** flattens the arrangement into one sequence.
- **Next Sequence** live mode queues the next sequence for the end of the bar or the end of the sequence.

## 8. Mixer & FX

- **Channels:** pads (per program), tracks/programs, audio tracks, synth panel, **8 submixes**, **4 returns**, master.
- **Each channel:** level, pan, mute, solo, 4 sends, output routing, and **4 insert FX**.
- **FX library** (shared with the synth panel's chain, plus extras):
  - space: reverb (room/hall/plate/spring/ambient), delay (sync, ping-pong, tape);
  - modulation: chorus, flanger, phaser;
  - dynamics: compressor (incl. a sidechain from any channel), limiter, transient shaper, gate;
  - tone: 4-band EQ, filter (all program filter types), distortion family, tape, bit-crusher.
- **XY performance FX:** an XY pad that maps 2 parameters of a chosen effect, with latch and an optional sync to beat.

## 9. Q-Links (assignable knobs)

- 4 on-screen knobs per page, 4 pages (16 knobs). Each can be assigned to any parameter.
- Modes: Project (user-assigned), Program, Pad (the selected pad's params), Track (mixer), Screen (the parameters on the current view).
- Knob movements are recorded as automation when Write is on.
- A MIDI CC can be learned to any Q-Link.

## 10. Files & I/O

- **Import:** WAV, AIFF, CAF, MP3, M4A/AAC and FLAC (via AVAudioFile) from the Files app, AirDrop, or the share sheet. Folder import, with a browser that previews samples and auto-plays them at project BPM.
- **Export:**
  - mixdown of a sequence or song (WAV 16/24/32f, 44.1/48 kHz);
  - stems (one file per track or submix);
  - a MIDI file (SMF type 1);
  - a sample, or a whole program as WAV files + JSON.
- **Projects:** a package folder (`.psproj`: project.json + Samples/) shown in the Files app. Auto-save, plus versioned "Save As".
- **Stem separation** (later, optional): split an imported song into drums, bass, vocals and other with an on-device Core ML model, then chop the stems.

## 11. How the panels connect

| From → To | Behavior |
|---|---|
| Synth → Sampler | **Resample** the synth live into a pad. **Send loop**: any synth looper track becomes a sample, or a time-aligned audio track. **Auto-sampler** builds a keygroup from any synth sound |
| Synth as instrument | A sequencer track can be a **Synth program**. Playing the synth panel while that track is armed records its notes plus chord/joystick metadata into the sequence |
| Sampler → Synth | Any pool sample can become a synth "User Samp" sound, or the vocoder's LOOP carrier |
| Shared | One transport: Play/Stop/BPM/swing are global. The synth's looper and arp sync to the sequencer's bar grid. One mixer: the synth panel is a mixer channel. One MIDI clock out |

## 12. Not carried over / adapted

- **Hardware controls:**
  - jog wheel → touch scrubbing and knob drags;
  - physical buttons → on-screen buttons;
  - the touchscreen menu grid → a sidebar mode switcher.
- **Not supported:** expansion stores, CV/gate, DIN MIDI (USB and Bluetooth MIDI cover it), and running third-party plugins inside the sampler. Hosting AUv3 instruments and effects as programs is possible in a later phase.
- **Pad velocity** comes from touch position or size, not pressure-sensing pads (§2).
