// PocketSynth real-time engine — C API over the C++ core.
//
// One engine renders both panels: the synth (voices → FX chain) and the sampler
// (pad voices), summed through a small mixer (synth level, sampler level, master).
//
// Threading: every control call (note_on, set_param, set_patch, sampler_set_pad,
// sample_release, …) must come from ONE producer thread (the main thread). They travel
// through a single lock-free FIFO, so their order is preserved. ps_engine_render runs
// only on the audio thread and never blocks or allocates.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PSEngine PSEngine;

// MARK: - Parameters

typedef enum {
    PS_PARAM_VOLUME = 0,      // synth panel volume (the wheel), 0...1
    PS_PARAM_ATTACK_MS,       // 0.1...5000
    PS_PARAM_DECAY_MS,
    PS_PARAM_SUSTAIN,         // 0...1
    PS_PARAM_RELEASE_MS,
    PS_PARAM_WAVEFORM,        // PSWaveform; shortcut that sets a plain analog patch
    PS_PARAM_FILTER_ENABLED,  // 0 / 1
    PS_PARAM_CUTOFF_HZ,       // 20...20000
    PS_PARAM_STEREO,          // 0 = mono, 1 = detuned L/R pairs
    PS_PARAM_TEMPO_BPM,       // 40...300, drives synced FX
    PS_PARAM_GLIDE_MS,        // 0 = off
    PS_PARAM_VIBRATO_CENTS,   // 0 = off (chord voices only, never bass)
    PS_PARAM_FX_DELAY,        // option index, 0 = off: 1/4 1/8 1/16 1/16T 1/32
    PS_PARAM_FX_CHORUS,       // LIGHT WARM WIDE LUSH
    PS_PARAM_FX_FLANGER,      // SLOW JET DEEP METAL
    PS_PARAM_FX_DRIVE,        // TUBE DRIVE DIST FUZZ
    PS_PARAM_FX_TAPE,         // LOFI VINYL TAPE
    PS_PARAM_FX_TREMOLO,      // 1/4 1/8 1/16 1/16T 1/32
    PS_PARAM_FX_REVERB,       // ROOM HALL PLATE SPRING AMBIENT LEGACY
    PS_PARAM_SYNTH_LEVEL,     // mixer, 0...1.5
    PS_PARAM_SAMPLER_LEVEL,   // mixer, 0...1.5
    PS_PARAM_MASTER_LEVEL,    // mixer, 0...1.5
    PS_PARAM_METRONOME,       // 0 / 1: click while the transport plays (count-in always clicks)
    PS_PARAM_METRONOME_LEVEL, // 0...1
    PS_PARAM_BEATS_PER_BAR,   // 1...16, for the metronome accent (default 4)
    PS_PARAM_MIDI_OUT,        // 0 / 1: send notes (live, drums, MIDI tracks, loops)
    PS_PARAM_MIDI_CLOCK_OUT,  // 0 / 1: 24 PPQN clock + start/stop
    PS_PARAM_MIDI_CHANNEL,    // 0...15: channel for live synth playing
    PS_PARAM_COUNT
} PSParam;

typedef enum {
    PS_WAVE_SAW = 0,
    PS_WAVE_SQUARE,
    PS_WAVE_TRIANGLE,
    PS_WAVE_SINE,
} PSWaveform;

// MARK: - Synth patches

typedef enum {
    PS_ENGINE_ANALOG = 0,  // osc1 (+ osc2)
    PS_ENGINE_FM,          // 2-operator FM
    PS_ENGINE_NOISE,       // noise only (pitched via a resonant filter)
    PS_ENGINE_HYBRID,      // analog oscillators + noise layer
} PSEngineKind;

typedef enum {
    PS_NOISE_WHITE = 0,
    PS_NOISE_PINK,
    PS_NOISE_RESONANT,     // band-passed; cutoff 0 = tracks the note
    PS_NOISE_METALLIC,     // inharmonic square cluster
} PSNoiseKind;

typedef struct {
    int engine;            // PSEngineKind
    int wave1, wave2;      // PSWaveform
    float mix2;            // 0 = osc1 only, 1 = osc2 only
    float detune2;         // osc2 offset in semitones (e.g. 0.08, 12, -12)
    float octave;          // whole-sound transpose in octaves
    float fmRatio;         // modulator : carrier frequency ratio
    float fmIndex;         // peak modulation index
    float fmIndexDecayMs;  // index envelope decay (0 = static)
    float fmIndexSustain;  // index floor as a fraction of the peak
    float fmFeedback;      // modulator self-feedback, 0...1
    int noiseKind;         // PSNoiseKind
    float noiseLevel;      // 0...1
    float noiseCutoffHz;   // resonant noise centre; 0 = note frequency
    float noiseQ;          // resonance for the resonant noise, 0.5...20
    float toneCutoffHz;    // per-voice low-pass, 0 = open
    float gain;            // output trim (1 = nominal)
} PSPatch;

// MARK: - Sampler

typedef struct PSSample PSSample;

typedef struct {
    PSSample *sample;      // NULL = empty layer
    int start, end;        // frames, end exclusive
    float tuneSemitones;   // coarse + fine combined
    float level;           // linear gain
    float pan;             // -1...1
    int velocityLow, velocityHigh; // 0...127 inclusive
    int reverse;           // 0 / 1
} PSLayer;

#define PS_MAX_LAYERS 4
#define PS_SAMPLER_PADS 128
#define PS_SUBMIXES 8
#define PS_RETURNS 4

typedef struct {
    PSLayer layers[PS_MAX_LAYERS];
    int layerCount;
    int oneShot;           // 1 = plays to the end; 0 = gated by the pad (note-on)
    int mono;              // 1 = a retrigger cuts this pad's previous voice
    int muteGroup;         // 0 = none; pads in the same group choke each other
    float attackMs, holdMs, decayMs, sustain, releaseMs;
    float level;           // linear pad gain
    float pan;             // -1...1
    int output;            // 0 = sampler main, 1...8 = submix
    float sends[PS_RETURNS]; // send levels to the returns
} PSPadParams;

// MARK: - Mixer routing (SAMPLER_SPEC §8)

typedef enum { PS_INSERT_NONE = 0, PS_INSERT_LOWPASS, PS_INSERT_HIGHPASS, PS_INSERT_DRIVE, PS_INSERT_CRUSH } PSInsert;
typedef enum { PS_RETURN_OFF = 0, PS_RETURN_ROOM, PS_RETURN_HALL, PS_RETURN_PLATE, PS_RETURN_DELAY_8, PS_RETURN_DELAY_4, PS_RETURN_CHORUS } PSReturnType;
typedef enum { PS_XY_OFF = 0, PS_XY_FILTER, PS_XY_ECHO, PS_XY_CRUSH } PSXYType;

// MARK: - Lifecycle

PSEngine *ps_engine_create(double sample_rate);
void ps_engine_destroy(PSEngine *engine);

// MARK: - Synth control

void ps_engine_note_on(PSEngine *engine, int note, float velocity);
/// `bass` routes the note to the bass bus (after delay, no vibrato) — SYNTH_SPEC §3.1.
void ps_engine_note_on_ex(PSEngine *engine, int note, float velocity, int bass);
void ps_engine_note_off(PSEngine *engine, int note);
void ps_engine_all_notes_off(PSEngine *engine);
void ps_engine_set_param(PSEngine *engine, PSParam param, float value);
void ps_engine_set_patch(PSEngine *engine, const PSPatch *patch);

// MARK: - Sampler control

/// Allocates a sample buffer on the calling (main) thread. Fill the channels, then use
/// it in pad params. Mono samples have one channel.
PSSample *ps_sample_create(int frames, int channels, double sample_rate);
float *ps_sample_channel(PSSample *sample, int channel);
int ps_sample_frames(const PSSample *sample);
/// Frees a sample that was never given to an engine (or after the engine is destroyed).
void ps_sample_destroy(PSSample *sample);
/// Hands a sample back: the audio thread drops every reference to it, then
/// ps_engine_collect_garbage frees it. Do not use the pointer afterwards.
void ps_engine_release_sample(PSEngine *engine, PSSample *sample);
/// Frees released samples. Call regularly from the main thread.
int ps_engine_collect_garbage(PSEngine *engine);

void ps_sampler_set_pad(PSEngine *engine, int pad, const PSPadParams *params);
/// velocity 1...127
void ps_sampler_trigger(PSEngine *engine, int pad, int velocity);
void ps_sampler_release(PSEngine *engine, int pad);
void ps_sampler_stop_all(PSEngine *engine);

// MARK: - Clock & transport
//
// One beat clock runs all the time at PS_PARAM_TEMPO_BPM. Arp, repeat, drum repeat, the
// beat player and note repeat all lock to it. When the transport starts, the clock jumps to
// the start position (minus the count-in), so every performer lines up with the sequence.
// Positions are in ticks at PS_PPQN.

#define PS_PPQN 960

/// Starts the transport at `start_tick`, after `count_in_beats` metronome beats.
void ps_transport_play(PSEngine *engine, int start_tick, int count_in_beats);
void ps_transport_stop(PSEngine *engine);
/// While recording, live pad hits (and note-repeat hits) are stamped and queued for
/// ps_engine_poll_recorded. Sequence events on a pad within `guard_ticks` of a live hit
/// on that pad are skipped, so a just-recorded note doesn't double.
void ps_transport_set_recording(PSEngine *engine, int recording, int guard_ticks);
int ps_transport_playing(const PSEngine *engine);
/// Position inside the current sequence (wrapped when looping); negative during count-in.
double ps_transport_ticks(const PSEngine *engine);
/// Free-running beat clock.
double ps_engine_beat(const PSEngine *engine);

// MARK: - Sampler sequences

/// What a sequence event (or a live note) plays.
typedef enum {
    PS_TARGET_DRUM = 0,    // a drum-program pad (`pad` = pad index)
    PS_TARGET_KEYGROUP,    // a keygroup program (`pad` = MIDI note, `program` = keygroup)
    PS_TARGET_SYNTH,       // the synth panel's sound (`pad` = MIDI note)
    PS_TARGET_MIDI,        // MIDI out (`pad` = note, `program` = channel 0…15)
} PSTarget;

typedef struct {
    int tick;              // 0 ... lengthTicks-1
    int length;            // ticks; releases gated sounds
    int pad;               // pad index, or MIDI note for note targets
    int velocity;          // 1 ... 127
    float tune;            // semitones added to the pad's tune
    int target;            // PSTarget
    int program;           // keygroup index or MIDI channel
} PSNoteEvent;

typedef struct PSSequence PSSequence;

/// Copies the events (any order) into a new playable sequence (main thread).
PSSequence *ps_sequence_create(const PSNoteEvent *events, int count, int length_ticks, int loop);
/// Frees a sequence that was never handed to an engine.
void ps_sequence_destroy(PSSequence *sequence);
/// The engine takes ownership; the previous sequence goes to the garbage queue.
/// NULL clears it. The swap happens at the next block: playback never stops.
void ps_engine_set_sequence(PSEngine *engine, PSSequence *sequence);

/// Song mode / Next Sequence: `sequence` takes over at the end of the current one
/// (`at_bar` 0) or at the next bar line (1), and the playhead restarts at its tick 0.
/// A newer queue replaces an older one. Stopping the transport drops the queue.
void ps_engine_queue_sequence(PSEngine *engine, PSSequence *sequence, int at_bar);
/// Counts queued swaps (so the caller knows when one happened).
int ps_transport_sequence_generation(const PSEngine *engine);

typedef struct {
    int tick;              // transport position (unwrapped if not looping; may be < 0)
    int pad;               // pad, or note for note targets
    int velocity;          // 0 = released
    float tune;
    int target;            // PSTarget it was played on
} PSRecordedEvent;

/// Moves up to `max` recorded events into `out`. Returns how many.
int ps_engine_poll_recorded(PSEngine *engine, PSRecordedEvent *out, int max);

/// Like ps_sampler_trigger, with an extra tune offset (16 Levels).
void ps_sampler_trigger_ex(PSEngine *engine, int pad, int velocity, float tune);

/// Note repeat: `rate_beats` 0 = off. Held pads retrigger on the clock grid.
void ps_note_repeat_set(PSEngine *engine, double rate_beats, float swing);
/// Pad down (velocity > 0), pressure change (same pad again) or up (velocity 0) while
/// note repeat is on. Use instead of trigger/release.
void ps_note_repeat_pad(PSEngine *engine, int pad, int velocity, float tune);

// MARK: - Keygroup programs (SAMPLER_SPEC §3.2)

#define PS_KEYGROUP_PROGRAMS 8
#define PS_KEYGROUP_ZONES 32

typedef struct {
    int lowNote, highNote; // inclusive key range
    int rootNote;          // the note that plays the sample at its own pitch
    PSLayer layers[PS_MAX_LAYERS];
    int layerCount;
} PSKeygroupZone;

/// `common` carries the envelope, level, pan and mono flag (layers are ignored).
void ps_keygroup_set_program(PSEngine *engine, int program, int zone_count, const PSPadParams *common);
void ps_keygroup_set_zone(PSEngine *engine, int program, int zone, const PSKeygroupZone *z);

/// A live note on a target (velocity 0 = off). Recorded like pad hits while recording.
void ps_live_note(PSEngine *engine, int target, int program, int note, int velocity);

// MARK: - Synth performers (SYNTH_SPEC §4)

typedef enum {
    PS_PERF_PLAY = 0,      // also Lead and Drone (latching is done by the caller)
    PS_PERF_STRUM,
    PS_PERF_ARP,
    PS_PERF_REPEAT,
    PS_PERF_SEQ,
    PS_PERF_DRUMS,
    PS_PERF_BEAT,
} PSPerformer;

#define PS_MAX_SLOT_NOTES 8
#define PS_SYNTH_SLOTS 8   // chord pads 1...7 (slot 0 unused)
#define PS_SEQ_STEPS 16

typedef struct {
    float strumMs;          // between strummed notes
    int arpPattern;         // 0 UP, 1 DOWN, 2 UP/DN, 3 DN/UP, 4 RAND
    int arpLayer;           // 0 ARP, 1 CHORD+ARP, 2 RHYTHM+ARP
    double arpRateBeats;
    float arpSwing;         // 0.5 = straight
    double repeatRateBeats;
    float repeatSwing;
    int repeatStutter;      // 1 = 32-step gate pattern at 1/32
    double seqRateBeats;    // chord sequencer step length
} PSRhythm;

void ps_synth_set_performer(PSEngine *engine, int performer);
void ps_synth_set_rhythm(PSEngine *engine, const PSRhythm *rhythm);
/// The notes a chord pad holds (count 0 = released). `bass` < 0 = none.
void ps_synth_set_slot(PSEngine *engine, int slot, const int *notes, int count, int bass);
/// Chord sequencer step (count 0 = rest).
void ps_synth_set_seq_step(PSEngine *engine, int index, const int *notes, int count, int bass);
void ps_synth_set_seq(PSEngine *engine, int length, int playing);
/// Step the chord sequencer is on, or -1 when stopped.
int ps_synth_seq_position(const PSEngine *engine);

// MARK: - Drum machine (Drums & Beat modes)

#define PS_DRUM_VOICES 8   // kick, snare, closed hat, tom, open hat, cowbell, clap, shaker
#define PS_DRUM_KITS 7
#define PS_BEAT_MAX_STEPS 32

void ps_drum_trigger(PSEngine *engine, int voice, int velocity);
void ps_drum_set_kit(PSEngine *engine, int kit);
/// Auto-repeat a drum voice (`rate_beats` 0 = stop).
void ps_drum_repeat(PSEngine *engine, int voice, double rate_beats, float swing, int velocity);

typedef struct {
    int steps;                                         // 1 ... PS_BEAT_MAX_STEPS
    double stepBeats;                                  // usually 0.25 (16ths)
    float swing;
    unsigned char velocity[PS_BEAT_MAX_STEPS][PS_DRUM_VOICES]; // 0 = no hit
} PSBeatPattern;

/// Sets the pattern (NULL keeps the current one) and starts or stops the beat player.
void ps_beat_set(PSEngine *engine, const PSBeatPattern *pattern, int playing);
/// Current beat step, or -1 when stopped.
int ps_beat_position(const PSEngine *engine);

// MARK: - Synth looper (SYNTH_SPEC §5)
//
// Six tracks record the synth panel's output (post-FX). Buffers are PSSamples (2 channels)
// created on the main thread with ps_sample_create and handed over; the engine returns
// them through the garbage queue when a track is cleared. Every command carries a
// generation number that telemetry echoes back, so the caller knows which command a
// reported state belongs to.

#define PS_LOOPER_TRACKS 6

typedef enum {
    PS_LOOP_OFF = 0,
    PS_LOOP_WAITING,       // count-in, or armed for the next loop point
    PS_LOOP_RECORD,
    PS_LOOP_PLAY,
} PSLoopState;

/// First take: sets the loop length. `length_frames` 0 = free (ends with
/// ps_looper_stop_first). With the transport stopped the clock jumps back by
/// `count_in_beats` (metronome count-in); while it plays, recording waits for the next bar.
void ps_looper_record_first(PSEngine *engine, int track, PSSample *buffer, int length_frames,
                            int count_in_beats, int generation);
/// Ends a free first take; its length becomes the loop length.
void ps_looper_stop_first(PSEngine *engine, int generation);
/// Records one pass on `track`, starting at the next loop point.
void ps_looper_arm(PSEngine *engine, int track, PSSample *buffer, int generation);
/// Cancels a waiting track, or clears a recorded one (its buffer is released).
void ps_looper_clear(PSEngine *engine, int track, int generation);
void ps_looper_clear_all(PSEngine *engine);
/// Pause with a tape-stop slowdown (1), or resume (0).
void ps_looper_pause(PSEngine *engine, int paused);
void ps_looper_set_gain(PSEngine *engine, int track, float gain);

/// Telemetry: state in the low 3 bits, generation above them.
int ps_looper_track(const PSEngine *engine, int track);
/// Loop length in frames (0 = no loop yet).
int ps_looper_length(const PSEngine *engine);
/// Playhead 0…1 inside the loop.
double ps_looper_position(const PSEngine *engine);
/// Frames recorded so far in the first take.
int ps_looper_recorded(const PSEngine *engine);

// MARK: - Sampling (SAMPLER_SPEC §4)

typedef enum {
    PS_SOURCE_INPUT = 0,   // mic / interface, fed by ps_engine_push_input
    PS_SOURCE_MASTER,      // everything you hear (metronome excluded)
    PS_SOURCE_SYNTH,       // the synth panel only (incl. loops)
    PS_SOURCE_SAMPLER,     // the sampler only
} PSSource;

typedef enum {
    PS_REC_IDLE = 0,
    PS_REC_ARMED,          // waiting for the threshold
    PS_REC_RECORDING,
    PS_REC_DONE,           // stopped, or the buffer is full
} PSRecorderState;

/// Feeds input audio (any thread, but only one). Frames beyond the 4 s ring are dropped.
void ps_engine_push_input(PSEngine *engine, const float *left, const float *right, int frames);
/// Records `source` into `buffer` (2 channels). `threshold` (linear) 0 = start right away.
/// `pre_roll_frames` (≤ 0.5 s) of audio from before the trigger are kept.
void ps_recorder_arm(PSEngine *engine, PSSample *buffer, int source, float threshold, int pre_roll_frames);
void ps_recorder_stop(PSEngine *engine);
/// Gives the buffer back (it goes through the garbage queue). Call after DONE.
void ps_recorder_release(PSEngine *engine);
/// Meter source (also while idle): which source the meter follows.
void ps_recorder_set_meter_source(PSEngine *engine, int source);
int ps_recorder_state(const PSEngine *engine);
int ps_recorder_frames(const PSEngine *engine);
/// Peak level of the metered source (linear, decaying).
float ps_recorder_peak(const PSEngine *engine);

/// Plays part of a sample once on a hidden preview pad (slice and chop auditions).
void ps_sampler_preview(PSEngine *engine, PSSample *sample, int start, int end, int velocity);

// MARK: - MIDI (SYNTH_SPEC §9)
//
// The engine stamps every outgoing MIDI event with a host time: the render call's host
// time plus the event's offset in the buffer plus `latency_ticks` (so MIDI lines up with
// what you hear). One consumer thread drains them. Without ps_engine_set_host_clock the
// host time is simply the engine's frame counter.

typedef struct {
    unsigned long long hostTime;
    unsigned char status, data1, data2;
} PSMidiEvent;

void ps_engine_set_host_clock(PSEngine *engine, double ticks_per_second, double latency_ticks);
/// ps_engine_render with the host time of the buffer's first frame.
void ps_engine_render_at(PSEngine *engine, float *left, float *right, int frames, unsigned long long host_time);
int ps_engine_poll_midi_out(PSEngine *engine, PSMidiEvent *out, int max);

/// Incoming MIDI (any one thread): notes play the synth (Drums/Beat modes: GM drums),
/// CC 64 sustains, CC 120/123 silence everything. Clock and control CCs are handled
/// by the caller.
void ps_engine_midi_in(PSEngine *engine, int status, int data1, int data2);

// MARK: - Mixer

/// Submix 0…7: level, pan, mute, one insert (PSInsert) with an amount 0…1.
void ps_mixer_set_submix(PSEngine *engine, int index, float level, float pan, int mute, int insert, float amount);
/// Return 0…3: effect (PSReturnType) and level.
void ps_mixer_set_return(PSEngine *engine, int index, int type, float level);
/// XY effect on the master: type, x / y 0…1, active (touching or latched).
void ps_mixer_set_xy(PSEngine *engine, int type, float x, float y, int active);

// MARK: - Rendering & telemetry

/// Renders `frames` samples into two non-interleaved float buffers (any block size).
void ps_engine_render(PSEngine *engine, float *left, float *right, int frames);

/// Synth voices currently producing sound.
int ps_engine_active_voices(const PSEngine *engine);
/// Sampler voices currently producing sound.
int ps_sampler_active_voices(const PSEngine *engine);

#ifdef __cplusplus
}
#endif
