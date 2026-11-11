// PocketSynth engine: one beat clock, the synth (performers → voices → FX chain), the
// drum machine, the sampler with its sequencer and note repeat, and a small mixer.
// Driven through a single ordered lock-free command FIFO. Render is real-time safe.
//
// Timing: audio is rendered in sub-blocks of up to kSub frames. Before each sub-block the
// engine fires everything due inside it (scheduled note-offs, grid steps, sequence
// events), so events land within kSub frames (0.67 ms at 48 kHz) of their exact time.

#include "include/SynthDSP.h"

#include "Arp.hpp"
#include "Clips.hpp"
#include "DSPCommon.hpp"
#include "Drums.hpp"
#include "Effects.hpp"
#include "Looper.hpp"
#include "Mixer.hpp"
#include "Recorder.hpp"
#include "Performer.hpp"
#include "Sampler.hpp"
#include "Synth.hpp"
#include "Transport.hpp"

using namespace ps;

namespace {

struct Command {
    enum Type : uint8_t {
        NoteOn, NoteOff, AllOff, SetParam, SetPatch,
        SetPad, Trigger, Release, StopAll, ReleaseSample,
        Play, Stop, SetRecording, SetSequence, NoteRepeatSet, NoteRepeatPad,
        Performer, Rhythm, Slot, SeqStep, Seq, DrumHit, DrumKit, DrumRepeat, Beat, QueueSequence,
        LoopFirst, LoopStopFirst, LoopArm, LoopClear, LoopClearAll, LoopPause, LoopGain,
        RecArm, RecStop, RecRelease, MeterSource, Preview,
        KeygroupProgram, KeygroupZone, LiveNote, MixSubmix, MixReturn, MixXY, SynthSample,
        ArpSet, ClipSet, ClipQuantize, ClipPad, ClipStopAll,
    } type;
    int32_t a = 0;  // note / param / pad / slot / voice
    float b = 0;    // velocity / value / tune
    int32_t c = 0;  // flags / count / bass
    int32_t e = 0;  // extra int
    int32_t f = 0;  // generation
    double d = 0;   // rates in beats
    PSSample *sample = nullptr;
    PSSequence *sequence = nullptr;
    union {
        PSPatch patch;
        PSPadParams pad;
        PSRhythm rhythm;
        PSBeatPattern beat;
        PSKeygroupZone zone;
        PSArp arp;
        PSClipParams clip;
        int notes[PS_MAX_SLOT_NOTES];
    } u;
    Command() : type(AllOff), u{} {}
};

struct Garbage {
    PSSample *sample = nullptr;
    PSSequence *sequence = nullptr;
};

constexpr int kSub = 32;

struct RepeatPad {
    int pad = -1;
    int velocity = 0;
    float tune = 0;
    int64_t lastStep = INT64_MIN;
};

} // namespace

struct PSEngine {
    double sampleRate;
    SPSCQueue<Command, 1024> commands;
    SPSCQueue<Garbage, 256> garbage;
    SPSCQueue<PSRecordedEvent, 2048> recorded;
    SPSCQueue<PSMidiEvent, 4096> midiOutQueue;
    SPSCQueue<uint32_t, 1024> midiInQueue;
    SPSCQueue<PSRetroEvent, 4096> retro;

    Synth synth;
    Sampler sampler;
    Drums drums;
    EngineScheduler scheduler;
    Performer performer;
    Delay delay;
    LowPass filter;
    Tremolo tremolo;
    ModDelay chorus, flanger;
    Drive drive;
    Tape tape;
    Reverb reverb;
    Vocoder vocoder;
    Click click;
    Looper looper;
    Recorder recorder;
    std::vector<Submix> submixes;
    std::vector<Return> returns;
    XYEffect xy;
    InputRing input;
    std::array<TrackArp, PS_ARPS> arps{};
    ClipPlayer clips;

    // Clock & transport.
    double bpm = 120;
    double beat = 0;
    uint64_t frame = 0;
    bool playing = false;
    bool recording = false;
    double guardTicks = 0;
    PSSequence *sequence = nullptr;
    PSSequence *queued = nullptr;
    bool queueAtBar = false;
    double seqOrigin = 0;               // absolute tick where the current sequence began
    int seqGeneration = 0;
    std::array<double, PS_SAMPLER_PADS> lastLiveTick{};
    bool metronome = false;
    double metronomeLevel = 0.5;
    int beatsPerBar = 4;

    // MIDI.
    bool midiOutOn = true, midiClockOn = true;
    int liveChannel = 0;
    bool suppressMidi = false;          // notes that must not echo out (MIDI in, synth tracks)
    double hostTicksPerSecond = 0, latencyTicks = 0;
    uint64_t hostAnchor = 0, frameAnchor = 0;
    int subOffset = 0;                  // frame offset of the current sub-block in its render call
    bool sustain = false;
    std::array<bool, 128> sustained{};

    // Note repeat.
    Grid repeatGrid{0, 0.5, 0};
    std::array<RepeatPad, 16> repeatPads{};

    // Mixer (smoothed).
    double synthVolume = 0.8, synthVolumeT = 0.8;
    double synthLevel = 1, synthLevelT = 1;
    double samplerLevel = 1, samplerLevelT = 1;
    double master = 1, masterT = 1;

    std::atomic<int> synthActive{0}, samplerActive{0};
    std::atomic<double> beatOut{0}, ticksOut{0};
    std::atomic<int> playingOut{0}, seqPosOut{-1}, beatPosOut{-1}, seqGenOut{0};
    std::array<std::atomic<int>, PS_LOOPER_TRACKS> loopTrackOut{};
    std::atomic<int> loopLengthOut{0}, loopRecordedOut{0};
    std::atomic<double> loopPosOut{0};
    std::atomic<int> recStateOut{0}, recFramesOut{0};
    std::atomic<float> recPeakOut{0};
    std::array<std::atomic<int>, PS_CLIPS> clipOut{};

    // Scratch buses, preallocated.
    std::array<float, kSub> chordL{}, chordR{}, bassL{}, bassR{}, smpL{}, smpR{}, drumL{}, drumR{};
    std::array<float, kSub> synthL{}, synthR{}, loopL{}, loopR{}, mixL{}, mixR{};
    std::array<std::array<float, kSub>, PS_SUBMIXES> subL{}, subR{};
    std::array<std::array<float, kSub>, PS_RETURNS> retL{}, retR{};
    std::array<float, 512> inL{}, inR{};
    // Vocoder modulator: mic audio (mono) waiting to be used, and the last block of loops.
    std::vector<float> micFifo = std::vector<float>(8192, 0.0f);
    size_t micRead = 0, micCount = 0;
    std::array<float, kSub> modBuf{}, lastLoop{};

    explicit PSEngine(double sr)
        : sampleRate(sr), synth(sr), sampler(sr), drums(sr), performer(sr, synth, drums, scheduler),
          delay(sr), filter(sr), tremolo(sr),
          chorus(sr, kChorusTypes, 4), flanger(sr, kFlangerTypes, 4), drive(sr), tape(sr), reverb(sr), vocoder(sr),
          looper(sr, Looper::Release{this, [](void *ctx, PSSample *s) {
              static_cast<PSEngine *>(ctx)->garbage.push(Garbage{s, nullptr});
          }}),
          recorder(sr), input(static_cast<size_t>(4 * sr)), xy(sr), clips(sr) {
        for (int i = 0; i < PS_SUBMIXES; ++i) submixes.emplace_back(sr);
        for (int i = 0; i < PS_RETURNS; ++i) returns.emplace_back(sr);
        lastLiveTick.fill(-1e12);
        hostTicksPerSecond = sr;
        synth.setNoteHook({this, [](void *ctx, int note, float vel, bool on) {
            static_cast<PSEngine *>(ctx)->synthNote(note, vel, on);
        }});
        drums.setHitHook({this, [](void *ctx, int voice, int vel) { static_cast<PSEngine *>(ctx)->drumHit(voice, vel); }});
        looper.setMidiEmit({this, [](void *ctx, int off, int ch, int note, int vel) {
            auto *e = static_cast<PSEngine *>(ctx);
            if (e->midiOutOn) e->sendMidi(off, static_cast<uint8_t>((vel > 0 ? 0x90 : 0x80) | (ch & 15)),
                                         static_cast<uint8_t>(note), static_cast<uint8_t>(vel > 0 ? vel : 64));
        }});
    }

    ~PSEngine() { delete sequence; delete queued; }

    // MARK: MIDI ---------------------------------------------------------------------------

    /// Queues an event `offset` frames into the current sub-block.
    void sendMidi(int offset, uint8_t status, uint8_t d1, uint8_t d2) {
        const double frames = static_cast<double>(frame + static_cast<uint64_t>(offset) - frameAnchor);
        PSMidiEvent e;
        e.hostTime = hostAnchor + static_cast<uint64_t>(std::max(0.0, frames / sampleRate * hostTicksPerSecond + latencyTicks));
        e.status = status;
        e.data1 = d1;
        e.data2 = d2;
        midiOutQueue.push(e);
    }

    /// Every synth note (live chords, strum, arp, repeat, chord sequencer) goes out on the
    /// live channel and into any recording loop track.
    void synthNote(int note, float vel, bool on) {
        if (suppressMidi) return;
        const int v = on ? std::clamp(static_cast<int>(std::lround(vel * 127)), 1, 127) : 0;
        if (note >= 0) retroPush(PS_TARGET_SYNTH, 0, note, v, 0);
        looper.recordMidi(note, v);
        if (!midiOutOn) return;
        const uint8_t ch = static_cast<uint8_t>(liveChannel & 15);
        if (note < 0) { sendMidi(0, 0xB0 | ch, 123, 0); return; }
        sendMidi(0, static_cast<uint8_t>((on ? 0x90 : 0x80) | ch), static_cast<uint8_t>(note), static_cast<uint8_t>(on ? v : 64));
    }

    static constexpr uint8_t kGMDrum[PS_DRUM_VOICES] = {36, 38, 42, 45, 46, 56, 39, 70};

    /// Drum hits go out on channel 10 with GM notes (SYNTH_SPEC §9).
    void drumHit(int voice, int vel) {
        if (suppressMidi || !midiOutOn) return;
        const uint8_t n = kGMDrum[voice];
        sendMidi(0, 0x99, n, static_cast<uint8_t>(std::clamp(vel, 1, 127)));
        Pending p;
        p.kind = Pending::MidiOff;
        p.slot = 9;
        p.a = n;
        p.at = frame + static_cast<uint64_t>(0.03 * sampleRate);
        scheduler.add(p);
    }

    static int drumVoiceForGM(int note) {
        switch (note) {
        case 35: case 36: return Kick;
        case 37: case 38: case 40: return Snare;
        case 42: case 44: return ClosedHat;
        case 41: case 43: case 45: case 47: case 48: case 50: return Tom;
        case 46: return OpenHat;
        case 56: return Cowbell;
        case 39: return Clap;
        case 69: case 70: case 82: return Shaker;
        default: return -1;
        }
    }

    void midiIn(uint32_t packed) {
        const int status = packed & 0xff, d1 = (packed >> 8) & 0x7f, d2 = (packed >> 16) & 0x7f;
        const int type = status & 0xf0;
        suppressMidi = true; // never echo incoming notes back out (MIDI loops)
        const bool drumsMode = performer.mode() == PS_PERF_DRUMS || performer.mode() == PS_PERF_BEAT;
        if (type == 0x90 && d2 > 0) {
            if (drumsMode) { if (const int v = drumVoiceForGM(d1); v >= 0) drums.trigger(v, d2); }
            else { sustained[d1] = false; synth.noteOn(d1, d2 / 127.0f, false); retroPush(PS_TARGET_SYNTH, 0, d1, d2, 0); }
        } else if (type == 0x80 || (type == 0x90 && d2 == 0)) {
            if (!drumsMode) {
                retroPush(PS_TARGET_SYNTH, 0, d1, 0, 0);
                if (sustain) sustained[d1] = true;
                else if (performer.heldCount(d1) == 0) synth.noteOff(d1);
            }
        } else if (type == 0xB0) {
            if (d1 == 64) {
                sustain = d2 >= 64;
                if (!sustain)
                    for (int n = 0; n < 128; ++n)
                        if (sustained[n]) { sustained[n] = false; if (performer.heldCount(n) == 0) synth.noteOff(n); }
            } else if (d1 == 120 || d1 == 123) {
                performer.allOff();
                drums.stopAll();
                sampler.stopAll();
                sustained.fill(false);
            }
        }
        suppressMidi = false;
    }

    void clockOut(double b0, double b1) {
        if (!midiClockOn) return;
        const double step = 1.0 / 24;
        const double fpb = framesPerBeat();
        for (double t = std::ceil(b0 / step) * step; t < b1; t += step)
            sendMidi(static_cast<int>((t - b0) * fpb), 0xF8, 0, 0);
    }

    double framesPerBeat() const { return 60.0 / bpm * sampleRate; }

    void setParam(int id, float value) {
        switch (id) {
        case PS_PARAM_VOLUME: synthVolumeT = std::clamp<double>(value, 0, 1); break;
        case PS_PARAM_ATTACK_MS: synth.setAttack(std::clamp<double>(value, 0.1, 5000)); break;
        case PS_PARAM_DECAY_MS: synth.setDecay(std::clamp<double>(value, 0.1, 5000)); break;
        case PS_PARAM_SUSTAIN: synth.setSustain(std::clamp<double>(value, 0, 1)); break;
        case PS_PARAM_RELEASE_MS: {
            const double r = std::clamp<double>(value, 0.1, 5000);
            synth.setRelease(r);
            performer.setReleaseMs(r);
            break;
        }
        case PS_PARAM_WAVEFORM: synth.setWaveform(static_cast<int>(value)); break;
        case PS_PARAM_FILTER_ENABLED: filter.setEnabled(value > 0.5f); break;
        case PS_PARAM_CUTOFF_HZ: filter.setCutoff(value); break;
        case PS_PARAM_STEREO: synth.setStereo(value > 0.5f); break;
        case PS_PARAM_TEMPO_BPM: {
            bpm = std::clamp<double>(value, 40, 300);
            delay.setTempo(bpm);
            tremolo.setTempo(bpm);
            for (auto &r : returns) r.setTempo(bpm);
            xy.setTempo(bpm);
            break;
        }
        case PS_PARAM_GLIDE_MS: synth.setGlideMs(std::max(0.0f, value)); break;
        case PS_PARAM_VIBRATO_CENTS: synth.setVibratoCents(std::max(0.0f, value)); break;
        case PS_PARAM_FX_DELAY: delay.setType(static_cast<int>(value)); break;
        case PS_PARAM_FX_CHORUS: chorus.setType(static_cast<int>(value)); break;
        case PS_PARAM_FX_FLANGER: flanger.setType(static_cast<int>(value)); break;
        case PS_PARAM_FX_DRIVE: drive.setType(static_cast<int>(value)); break;
        case PS_PARAM_FX_TAPE: tape.setType(static_cast<int>(value)); break;
        case PS_PARAM_FX_TREMOLO: tremolo.setType(static_cast<int>(value)); break;
        case PS_PARAM_FX_REVERB: reverb.setType(static_cast<int>(value)); break;
        case PS_PARAM_SYNTH_LEVEL: synthLevelT = std::clamp<double>(value, 0, 1.5); break;
        case PS_PARAM_SAMPLER_LEVEL: samplerLevelT = std::clamp<double>(value, 0, 1.5); break;
        case PS_PARAM_MASTER_LEVEL: masterT = std::clamp<double>(value, 0, 1.5); break;
        case PS_PARAM_METRONOME: metronome = value > 0.5f; break;
        case PS_PARAM_METRONOME_LEVEL: metronomeLevel = std::clamp<double>(value, 0, 1); break;
        case PS_PARAM_BEATS_PER_BAR: beatsPerBar = std::clamp(static_cast<int>(value), 1, 16); break;
        case PS_PARAM_MIDI_OUT: midiOutOn = value > 0.5f; break;
        case PS_PARAM_MIDI_CLOCK_OUT: midiClockOn = value > 0.5f; break;
        case PS_PARAM_MIDI_CHANNEL: liveChannel = std::clamp(static_cast<int>(value), 0, 15); break;
        case PS_PARAM_FX_VOCODER: vocoder.setType(static_cast<int>(value)); micCount = 0; break;
        default: break;
        }
    }

    // MARK: Transport ----------------------------------------------------------

    double ticks() const { return beat * kPPQ; }

    /// Position inside the sequence for display (wrapped when looping).
    double position() const {
        const double t = ticks() - seqOrigin;
        if (!playing || t < 0 || !sequence) return playing ? t : 0;
        const double len = sequence->lengthTicks;
        return sequence->loop ? std::fmod(t, len) : std::min(t, len);
    }

    /// Queues a live hit for recording. `absTick` is the unwrapped transport position.
    void stamp(int pad, int velocity, float tune, double absTick, int target = PS_TARGET_DRUM, int program = 0) {
        retroPush(target, program, pad, velocity, tune, absTick / kPPQ);
        if (!recording || !playing) return;
        PSRecordedEvent e;
        e.tick = static_cast<int>(std::lround(recordTick(absTick)));
        e.pad = pad;
        e.velocity = velocity;
        e.tune = tune;
        e.target = target;
        recorded.push(e);
        if (velocity > 0 && pad >= 0 && pad < PS_SAMPLER_PADS) lastLiveTick[pad] = absTick;
    }

    void retroPush(int target, int program, int note, int velocity, float tune, double atBeat = -1e18) {
        PSRetroEvent e;
        e.beat = atBeat > -1e17 ? atBeat : beat;
        e.target = target;
        e.program = program;
        e.note = note;
        e.velocity = velocity;
        e.tune = tune;
        retro.push(e);
    }

    TrackArp *arpFor(int target, int program) {
        for (auto &a : arps) if (a.active && a.target == target && a.program == program) return &a;
        return nullptr;
    }

    /// Plays a note on a note target (keygroup / synth / MIDI); velocity 0 = off. Notes for
    /// a destination with an arpeggiator go to the arp instead (unless it's the arp playing).
    void noteToTarget(int target, int program, int note, int velocity, bool viaArp = true) {
        note = std::clamp(note, 0, 127);
        if (viaArp) {
            if (TrackArp *a = arpFor(target, program)) { a->input(note, velocity, beat, playing); return; }
        }
        switch (target) {
        case PS_TARGET_KEYGROUP:
            if (velocity > 0) sampler.noteOn(program, note, velocity);
            else sampler.noteOff(program, note);
            break;
        case PS_TARGET_SYNTH:
            suppressMidi = true; // a synth track is not live playing
            if (velocity > 0) synth.noteOn(note, velocity / 127.0f, false);
            else if (performer.heldCount(note) == 0) synth.noteOff(note);
            suppressMidi = false;
            break;
        case PS_TARGET_MIDI:
            midiOut(program, note, velocity);
            break;
        default: break;
        }
    }

    /// Arp steps due in [b0, b1): each plays its note now and releases it after the gate.
    void processArps(double b0, double b1) {
        const double fpb = framesPerBeat();
        for (auto &a : arps) {
            if (!a.active) continue;
            a.process(b0, b1, [&](int note, int vel, double gateBeats) {
                noteToTarget(a.target, a.program, note, vel, false);
                Pending p;
                p.kind = Pending::ArpOff;
                p.target = static_cast<uint8_t>(a.target);
                p.slot = static_cast<uint8_t>(std::clamp(a.program, 0, 255));
                p.a = static_cast<int16_t>(note);
                p.at = frame + static_cast<uint64_t>(std::max(1.0, gateBeats * fpb));
                scheduler.add(p);
            });
        }
    }

    /// A MIDI-track note (velocity 0 = off).
    void midiOut(int channel, int note, int velocity) {
        if (!midiOutOn) return;
        sendMidi(0, static_cast<uint8_t>((velocity > 0 ? 0x90 : 0x80) | (channel & 15)),
                 static_cast<uint8_t>(note & 127), static_cast<uint8_t>(velocity > 0 ? velocity : 64));
    }

    /// Recorded positions wrap with the loop, so a take over several passes lands in place.
    double recordTick(double absTick) const {
        const double rel = absTick - seqOrigin;
        if (!sequence || !sequence->loop || rel < 0) return rel;
        return std::fmod(rel, static_cast<double>(sequence->lengthTicks));
    }

    void liveTrigger(int pad, int velocity, float tune) {
        sampler.trigger(pad, velocity, tune);
        stamp(pad, velocity, tune, ticks());
    }

    void handlePending(const Pending &p) {
        switch (p.kind) {
        case Pending::PadRelease: sampler.release(p.a); break;
        case Pending::KeygroupOff: sampler.noteOff(p.slot, p.a); break;
        case Pending::MidiOff: midiOut(p.slot, p.a, 0); break;
        case Pending::TargetOff: noteToTarget(p.target, p.slot, p.a, 0); break;
        case Pending::ArpOff: noteToTarget(p.target, p.slot, p.a, 0, false); break;
        case Pending::ClipOff: clips.sequenced(p.a, false, beat); break;
        default: performer.pending(p); break;
        }
    }

    void releaseAllScheduledPads() {
        scheduler.due(UINT64_MAX, [&](const Pending &p) { handlePending(p); });
    }

    /// Plays [t0, t1) (absolute ticks), swapping in a queued sequence at its boundary.
    void playSequenceRange(double t0, double t1) {
        if (t1 <= 0) return;
        t0 = std::max(t0, 0.0);
        if (queued) {
            double boundary = t0;
            if (sequence) {
                const double rel = t0 - seqOrigin;
                const double unit = queueAtBar ? beatsPerBar * kPPQ : sequence->lengthTicks;
                boundary = seqOrigin + std::ceil(rel / unit - 1e-9) * unit;
            }
            if (boundary < t1) {
                if (sequence && boundary > t0) playRange(t0, boundary);
                if (sequence) garbage.push(Garbage{nullptr, sequence});
                sequence = queued;
                queued = nullptr;
                seqOrigin = boundary;
                ++seqGeneration;
                playRange(boundary, t1);
                return;
            }
        }
        playRange(t0, t1);
    }

    void playRange(double a0, double a1) {
        if (!sequence) return;
        // Positions relative to where this sequence started.
        const double off = seqOrigin;
        double t0 = a0 - off, t1 = a1 - off;
        if (t1 <= 0) return;
        t0 = std::max(t0, 0.0);
        const double len = sequence->lengthTicks;
        if (!sequence->loop) {
            if (t0 >= len) { playing = false; releaseAllScheduledPads(); return; }
            fireEvents(t0, std::min(t1, len), off);
            return;
        }
        const double base = std::floor(t0 / len) * len;
        const double p0 = t0 - base, p1 = t1 - base;
        if (p1 <= len) {
            fireEvents(p0, p1, off + base);
        } else {
            fireEvents(p0, len, off + base);
            fireEvents(0, p1 - len, off + base + len);
        }
    }

    void fireEvents(double p0, double p1, double base) {
        const auto &ev = sequence->events;
        auto it = std::lower_bound(ev.begin(), ev.end(), p0,
                                   [](const PSNoteEvent &e, double t) { return e.tick < t; });
        const double framesPerTick = framesPerBeat() / kPPQ;
        for (; it != ev.end() && it->tick < p1; ++it) {
            if (it->pad < 0 || it->pad >= PS_SAMPLER_PADS) continue;
            const double abs = base + it->tick;
            Pending p;
            p.at = frame + static_cast<uint64_t>(std::max(1.0, it->length * framesPerTick));
            p.a = static_cast<int16_t>(it->pad);
            p.slot = static_cast<uint8_t>(std::clamp(it->program, 0, 255));
            if (it->target == PS_TARGET_AUDIO) {
                if (it->pad >= PS_AUDIO_SLOTS) continue;
                p.a = static_cast<int16_t>(Sampler::kAudioBase + it->pad);
                sampler.trigger(p.a, it->velocity, 0);
                p.kind = Pending::PadRelease;
                scheduler.add(p);
                continue;
            }
            if (it->target == PS_TARGET_CLIP) {
                if (it->pad >= PS_CLIPS) continue;
                clips.sequenced(it->pad, true, beat);
                p.kind = Pending::ClipOff;
                scheduler.add(p);
                continue;
            }
            if (it->target != PS_TARGET_DRUM) {
                noteToTarget(it->target, it->program, it->pad, it->velocity);
                p.kind = Pending::TargetOff;
                p.target = static_cast<uint8_t>(it->target);
                scheduler.add(p);
                continue;
            }
            if (recording && std::fabs(abs - lastLiveTick[it->pad]) < guardTicks) continue;
            sampler.trigger(it->pad, it->velocity, it->tune);
            p.kind = Pending::PadRelease;
            scheduler.add(p);
        }
    }

    // MARK: Note repeat -----------------------------------------------------------

    void noteRepeatPad(int pad, int velocity, float tune) {
        if (pad < 0 || pad >= PS_SAMPLER_PADS) return;
        RepeatPad *slot = nullptr;
        for (auto &r : repeatPads) if (r.pad == pad) slot = &r;
        if (velocity <= 0) {
            if (slot) { sampler.release(pad); stamp(pad, 0, 0, ticks()); *slot = RepeatPad{}; }
            return;
        }
        if (slot) { slot->velocity = velocity; slot->tune = tune; return; } // pressure
        for (auto &r : repeatPads) if (r.pad < 0) { slot = &r; break; }
        if (!slot) return;
        *slot = RepeatPad{pad, velocity, tune, INT64_MIN};
        if (repeatGrid.rate <= 0) return;
        // A hit just after a grid step counts as that step (played late); otherwise wait.
        const int64_t k = repeatGrid.last(beat);
        const double t = repeatGrid.time(k);
        if (beat - t < 0.3 * repeatGrid.rate) {
            slot->lastStep = k;
            sampler.trigger(pad, velocity, tune);
            stamp(pad, velocity, tune, t * kPPQ);
        }
    }

    void processNoteRepeat(double b0, double b1) {
        if (repeatGrid.rate <= 0) return;
        bool any = false;
        for (auto &r : repeatPads) any |= r.pad >= 0;
        if (!any) return;
        repeatGrid.each(b0, b1, [&](int64_t k, double t) {
            for (auto &r : repeatPads) {
                if (r.pad < 0 || r.lastStep == k) continue;
                r.lastStep = k;
                sampler.trigger(r.pad, r.velocity, r.tune);
                stamp(r.pad, r.velocity, r.tune, t * kPPQ);
            }
        });
    }

    // MARK: Commands -------------------------------------------------------------

    void drain() {
        Command c;
        while (commands.pop(c)) {
            switch (c.type) {
            case Command::NoteOn: synth.noteOn(c.a, c.b, c.c != 0); break;
            case Command::NoteOff: synth.noteOff(c.a); break;
            case Command::AllOff: performer.allOff(); break;
            case Command::SetParam: setParam(c.a, c.b); break;
            case Command::SetPatch: synth.setPatch(c.u.patch); break;
            case Command::SetPad: sampler.setPad(c.a, c.u.pad); break;
            case Command::Trigger: liveTrigger(c.a, static_cast<int>(c.c), c.b); break;
            case Command::Release:
                sampler.release(c.a);
                stamp(c.a, 0, 0, ticks());
                break;
            case Command::StopAll: sampler.stopAll(); break;
            case Command::ReleaseSample:
                sampler.forget(c.sample);
                synth.forget(c.sample);
                clips.forget(c.sample);
                looper.forget(c.sample);
                recorder.forget(c.sample);
                if (!garbage.push(Garbage{c.sample, nullptr})) { /* full: leak rather than free here */ }
                break;
            case Command::Play:
                beat = c.a / kPPQ - c.c;
                seqOrigin = 0;
                playing = true;
                lastLiveTick.fill(-1e12);
                if (midiClockOn) sendMidi(0, 0xFA, 0, 0); // Start
                break;
            case Command::Stop:
                playing = false;
                releaseAllScheduledPads();
                clips.stopAll();
                if (queued) { garbage.push(Garbage{nullptr, queued}); queued = nullptr; }
                seqOrigin = 0;
                if (midiClockOn) sendMidi(0, 0xFC, 0, 0); // Stop
                break;
            case Command::SetRecording:
                recording = c.a != 0;
                guardTicks = std::max(0, c.c);
                break;
            case Command::SetSequence:
                if (sequence) garbage.push(Garbage{nullptr, sequence});
                sequence = c.sequence;
                break;
            case Command::NoteRepeatSet:
                repeatGrid = Grid{c.d, std::clamp(c.b, 0.5f, 0.75f), 0};
                if (c.d <= 0)
                    for (auto &r : repeatPads) if (r.pad >= 0) { sampler.release(r.pad); r = RepeatPad{}; }
                break;
            case Command::NoteRepeatPad: noteRepeatPad(c.a, c.c, c.b); break;
            case Command::Performer: performer.setMode(c.a); break;
            case Command::Rhythm: performer.setRhythm(c.u.rhythm); break;
            case Command::Slot: performer.setSlot(c.a, c.u.notes, c.c, c.e); break;
            case Command::SeqStep: performer.setSeqStep(c.a, c.u.notes, c.c, c.e); break;
            case Command::Seq: performer.setSeq(c.a, c.c != 0); break;
            case Command::DrumHit: drums.trigger(c.a, c.c); break;
            case Command::DrumKit: drums.setKit(c.a); break;
            case Command::DrumRepeat: performer.drumRepeat(c.a, c.d, c.b, c.c); break;
            case Command::Beat: performer.setBeat(c.c ? &c.u.beat : nullptr, c.a != 0); break;
            case Command::QueueSequence:
                if (queued) garbage.push(Garbage{nullptr, queued});
                queued = c.sequence;
                queueAtBar = c.a != 0;
                if (!playing && queued) { // not playing: just switch
                    if (sequence) garbage.push(Garbage{nullptr, sequence});
                    sequence = queued;
                    queued = nullptr;
                    ++seqGeneration;
                }
                break;
            case Command::LoopFirst: {
                double start = beat;
                if (!playing && c.e > 0) {
                    beat = -c.e;         // metronome count-in, then record from beat 0
                    start = 0;
                } else if (!playing) {
                    beat = 0;            // free start: line the clock up with the loop
                    start = 0;
                } else if (c.e > 0) {
                    start = std::ceil(beat / beatsPerBar) * beatsPerBar; // next bar
                }
                looper.recordFirst(c.a, c.sample, c.c, start, c.f);
                break;
            }
            case Command::LoopStopFirst: looper.stopFirst(c.f); break;
            case Command::LoopArm: looper.arm(c.a, c.sample, c.f); break;
            case Command::LoopClear: looper.clear(c.a, c.f); break;
            case Command::LoopClearAll: looper.clearAll(); break;
            case Command::LoopPause: looper.pause(c.a != 0); break;
            case Command::LoopGain: looper.setGain(c.a, c.b); break;
            case Command::RecArm:
                if (PSSample *old = recorder.arm(c.sample, c.a, c.b, c.c)) garbage.push(Garbage{old, nullptr});
                break;
            case Command::RecStop: recorder.stop(); break;
            case Command::RecRelease:
                if (PSSample *old = recorder.release()) garbage.push(Garbage{old, nullptr});
                break;
            case Command::MeterSource: recorder.setMeterSource(c.a); break;
            case Command::MixSubmix:
                if (c.a >= 0 && c.a < PS_SUBMIXES) submixes[c.a].set(c.b, static_cast<float>(c.d), c.c != 0, c.e, c.f / 1000.0f);
                break;
            case Command::MixReturn:
                if (c.a >= 0 && c.a < PS_RETURNS) returns[c.a].set(c.c, c.b);
                break;
            case Command::MixXY: xy.set(c.a, c.b, static_cast<float>(c.d), c.c != 0); break;
            case Command::SynthSample: synth.setSample(c.sample, c.b); break;
            case Command::KeygroupProgram: sampler.setKeygroupProgram(c.a, c.c, c.u.pad); break;
            case Command::KeygroupZone: sampler.setKeygroupZone(c.a, c.c, c.u.zone); break;
            case Command::LiveNote:
                noteToTarget(c.e, c.f, c.a, c.c);
                stamp(c.a, c.c, 0, ticks(), c.e, c.f);
                break;
            case Command::ArpSet: {
                TrackArp *a = arpFor(c.a, c.e);
                if (!c.c) { if (a) a->remove(); break; }
                if (!a) for (auto &x : arps) if (!x.active) { a = &x; break; }
                if (a) a->configure(c.a, c.e, c.u.arp);
                break;
            }
            case Command::ClipSet: clips.set(c.a, c.u.clip); break;
            case Command::ClipQuantize: clips.setQuantize(c.d); break;
            case Command::ClipPad: if (c.a >= 0 && c.a < PS_CLIPS) clips.pad(c.a, c.c != 0, beat, playing); break;
            case Command::ClipStopAll: clips.stopAll(); break;
            case Command::Preview: {
                PSPadParams p{};
                p.layerCount = 1;
                p.layers[0].sample = c.sample;
                p.layers[0].start = c.a;
                p.layers[0].end = c.c;
                p.layers[0].level = 1;
                p.layers[0].velocityLow = 0;
                p.layers[0].velocityHigh = 127;
                p.oneShot = 1;
                p.mono = 1;
                p.sustain = 1;
                p.releaseMs = 5;
                p.level = 1;
                sampler.setPad(Sampler::kPreviewPad, p);
                sampler.trigger(Sampler::kPreviewPad, c.e);
                break;
            }
            }
        }
    }

    // MARK: Rendering --------------------------------------------------------------

    void renderSub(float *L, float *R, int n) {
        const double fpb = framesPerBeat();
        const double b0 = beat, b1 = beat + n / fpb;
        performer.setContext(b0, playing, frame, fpb);

        scheduler.due(frame + static_cast<uint64_t>(n), [&](const Pending &p) { handlePending(p); });

        if (playing || looper.running()) {
            // Metronome: always during the count-in, otherwise when switched on.
            for (double k = std::ceil(b0); k < b1; k += 1) {
                if (k < 0 || metronome) {
                    const int bi = static_cast<int>(k);
                    click.trigger(((bi % beatsPerBar) + beatsPerBar) % beatsPerBar == 0, sampleRate);
                }
            }
            if (playing) playSequenceRange(b0 * kPPQ, b1 * kPPQ);
        }
        clockOut(b0, b1);
        processNoteRepeat(b0, b1);
        processArps(b0, b1);
        performer.process(b0, b1);

        renderAudio(L, R, n, b0, b1);
        beat = b1;
        frame += static_cast<uint64_t>(n);
    }

    void renderAudio(float *L, float *R, int n, double b0, double b1) {
        for (auto *buf : {&chordL, &chordR, &bassL, &bassR, &smpL, &smpR, &drumL, &drumR})
            std::fill_n(buf->begin(), n, 0.0f);

        synth.render(chordL.data(), chordR.data(), bassL.data(), bassR.data(), n);
        drums.render(drumL.data(), drumR.data(), n);

        // Synth FX chain in the spec's fixed order (SYNTH_SPEC §3.1). Drums skip
        // drive and tape (a musical choice the spec keeps) and join before the reverb.
        float *cl = chordL.data(), *cr = chordR.data();
        delay.process(cl, cr, n);
        for (int i = 0; i < n; ++i) { cl[i] += bassL[i]; cr[i] += bassR[i]; }
        filter.process(cl, cr, n);
        tremolo.process(cl, cr, n);
        if (vocoder.type() != 0) {
            if (vocoder.type() == 1) popMic(modBuf.data(), n);
            else std::copy_n(lastLoop.begin(), n, modBuf.begin());
            vocoder.process(cl, cr, modBuf.data(), n);
        }
        chorus.process(cl, cr, n);
        flanger.process(cl, cr, n);
        drive.process(cl, cr, n);
        tape.process(cl, cr, n);
        for (int i = 0; i < n; ++i) { cl[i] += drumL[i]; cr[i] += drumR[i]; }
        reverb.process(cl, cr, n);

        // Sampler: voices into the main bus, submixes and sends; then submixes and returns
        // join the main sampler bus.
        float *busL[PS_SUBMIXES + 1] = {smpL.data()}, *busR[PS_SUBMIXES + 1] = {smpR.data()};
        float *rL[PS_RETURNS], *rR[PS_RETURNS];
        for (int k = 0; k < PS_SUBMIXES; ++k) {
            std::fill_n(subL[k].begin(), n, 0.0f);
            std::fill_n(subR[k].begin(), n, 0.0f);
            busL[k + 1] = subL[k].data();
            busR[k + 1] = subR[k].data();
        }
        for (int k = 0; k < PS_RETURNS; ++k) {
            std::fill_n(retL[k].begin(), n, 0.0f);
            std::fill_n(retR[k].begin(), n, 0.0f);
            rL[k] = retL[k].data();
            rR[k] = retR[k].data();
        }
        sampler.render(busL, busR, rL, rR, n);
        clips.process(b0, b1, bpm, smpL.data(), smpR.data(), n, [&](int clip, bool on) {
            stamp(clip, on ? 100 : 0, 0, b0 * kPPQ, PS_TARGET_CLIP);
        });
        const double mk = 1.0 - std::exp(-1.0 / (0.01 * sampleRate));
        for (int k = 0; k < PS_SUBMIXES; ++k) submixes[k].process(subL[k].data(), subR[k].data(), smpL.data(), smpR.data(), n, mk);
        for (int k = 0; k < PS_RETURNS; ++k) returns[k].process(retL[k].data(), retR[k].data(), smpL.data(), smpR.data(), n, mk);

        // Synth panel output (what the looper records), then the loops on top of it.
        const double k = 1.0 - std::exp(-1.0 / (0.01 * sampleRate));
        for (int i = 0; i < n; ++i) {
            synthVolume += (synthVolumeT - synthVolume) * k;
            synthL[i] = static_cast<float>(cl[i] * synthVolume);
            synthR[i] = static_cast<float>(cr[i] * synthVolume);
            loopL[i] = loopR[i] = 0;
        }
        looper.process(synthL.data(), synthR.data(), loopL.data(), loopR.data(), n, beat, 1.0 / framesPerBeat());
        for (int i = 0; i < n; ++i) {
            synthL[i] += loopL[i];
            synthR[i] += loopR[i];
            lastLoop[i] = 0.5f * (loopL[i] + loopR[i]);
        }

        for (int i = 0; i < n; ++i) {
            synthLevel += (synthLevelT - synthLevel) * k;
            samplerLevel += (samplerLevelT - samplerLevel) * k;
            master += (masterT - master) * k;
            mixL[i] = static_cast<float>((synthL[i] * synthLevel + smpL[i] * samplerLevel) * master);
            mixR[i] = static_cast<float>((synthR[i] * synthLevel + smpR[i] * samplerLevel) * master);
        }
        xy.process(mixL.data(), mixR.data(), n);
        recorder.feed(PS_SOURCE_MASTER, mixL.data(), mixR.data(), n);
        recorder.feed(PS_SOURCE_SYNTH, synthL.data(), synthR.data(), n);
        recorder.feed(PS_SOURCE_SAMPLER, smpL.data(), smpR.data(), n);

        for (int i = 0; i < n; ++i) {
            const double tick = click.next() * metronomeLevel * 0.5;
            L[i] = static_cast<float>(std::tanh(mixL[i] + tick));
            R[i] = static_cast<float>(std::tanh(mixR[i] + tick));
        }
    }

    void render(float *L, float *R, int frames) {
        render(L, R, frames, hostAnchor + static_cast<uint64_t>(static_cast<double>(frame - frameAnchor) / sampleRate * hostTicksPerSecond));
    }

    void render(float *L, float *R, int frames, uint64_t hostTime) {
        hostAnchor = hostTime;
        frameAnchor = frame;
        performer.setContext(beat, playing, frame, framesPerBeat());
        drain(); // main-thread commands first (a mode change decides how MIDI in plays)
        for (uint32_t m; midiInQueue.pop(m);) midiIn(m);
        // Mic / interface input goes straight to the recorder (it arrives in bursts).
        for (int got; (got = input.pop(inL.data(), inR.data(), static_cast<int>(inL.size()))) > 0;) {
            recorder.feed(PS_SOURCE_INPUT, inL.data(), inR.data(), got);
            if (vocoder.type() == 1) pushMic(inL.data(), inR.data(), got);
        }
        for (int off = 0; off < frames; off += kSub)
            renderSub(L + off, R + off, std::min(kSub, frames - off));
        synthActive.store(synth.activeVoices() + drums.activeVoices(), std::memory_order_relaxed);
        samplerActive.store(sampler.activeVoices(), std::memory_order_relaxed);
        beatOut.store(beat, std::memory_order_relaxed);
        ticksOut.store(position(), std::memory_order_relaxed);
        playingOut.store(playing ? 1 : 0, std::memory_order_relaxed);
        seqPosOut.store(performer.seqPosition(), std::memory_order_relaxed);
        beatPosOut.store(performer.beatPosition(), std::memory_order_relaxed);
        seqGenOut.store(seqGeneration, std::memory_order_relaxed);
        for (int t = 0; t < PS_LOOPER_TRACKS; ++t) loopTrackOut[t].store(looper.packed(t), std::memory_order_relaxed);
        loopLengthOut.store(looper.length(), std::memory_order_relaxed);
        loopPosOut.store(looper.position(), std::memory_order_relaxed);
        loopRecordedOut.store(looper.recorded(), std::memory_order_relaxed);
        recStateOut.store(recorder.state(), std::memory_order_relaxed);
        recFramesOut.store(recorder.frames(), std::memory_order_relaxed);
        recPeakOut.store(recorder.peak(), std::memory_order_relaxed);
        for (int i = 0; i < PS_CLIPS; ++i) clipOut[i].store(clips.state(i), std::memory_order_relaxed);
    }

    /// Mic audio for the vocoder. Input arrives in bursts; keep at most ~85 ms queued.
    void pushMic(const float *L, const float *R, int n) {
        const size_t cap = micFifo.size();
        const size_t maxQueued = static_cast<size_t>(0.085 * sampleRate);
        for (int i = 0; i < n; ++i) {
            micFifo[(micRead + micCount) % cap] = 0.5f * (L[i] + R[i]);
            if (micCount < cap) ++micCount; else micRead = (micRead + 1) % cap;
        }
        while (micCount > maxQueued) { micRead = (micRead + 1) % cap; --micCount; }
    }

    void popMic(float *out, int n) {
        const size_t cap = micFifo.size();
        for (int i = 0; i < n; ++i) {
            if (micCount == 0) { out[i] = 0; continue; }
            out[i] = micFifo[micRead];
            micRead = (micRead + 1) % cap;
            --micCount;
        }
    }

    void push(const Command &c) { commands.push(c); }
};

// ---------------------------------------------------------------------------
// C API

namespace {
Command make(Command::Type t, int32_t a = 0, float b = 0, int32_t c = 0) {
    Command cmd;
    cmd.type = t;
    cmd.a = a;
    cmd.b = b;
    cmd.c = c;
    return cmd;
}
} // namespace

extern "C" {

PSEngine *ps_engine_create(double sample_rate) { return new PSEngine(sample_rate); }

void ps_engine_destroy(PSEngine *engine) {
    ps_engine_collect_garbage(engine);
    delete engine;
}

void ps_engine_note_on(PSEngine *engine, int note, float velocity) {
    ps_engine_note_on_ex(engine, note, velocity, 0);
}

void ps_engine_note_on_ex(PSEngine *engine, int note, float velocity, int bass) {
    engine->push(make(Command::NoteOn, note, velocity, bass));
}

void ps_engine_note_off(PSEngine *engine, int note) { engine->push(make(Command::NoteOff, note)); }

void ps_engine_all_notes_off(PSEngine *engine) { engine->push(make(Command::AllOff)); }

void ps_engine_set_param(PSEngine *engine, PSParam param, float value) {
    engine->push(make(Command::SetParam, static_cast<int32_t>(param), value));
}

void ps_engine_set_patch(PSEngine *engine, const PSPatch *patch) {
    Command c = make(Command::SetPatch);
    c.u.patch = *patch;
    engine->push(c);
}

PSSample *ps_sample_create(int frames, int channels, double sample_rate) {
    auto *s = new PSSample;
    s->frames = std::max(0, frames);
    s->channels = std::clamp(channels, 1, 2);
    s->sampleRate = sample_rate;
    for (int ch = 0; ch < s->channels; ++ch) s->channel[ch].assign(static_cast<size_t>(s->frames), 0.0f);
    return s;
}

float *ps_sample_channel(PSSample *sample, int channel) {
    return sample->channel[std::clamp(channel, 0, sample->channels - 1)].data();
}

int ps_sample_frames(const PSSample *sample) { return sample->frames; }

void ps_sample_destroy(PSSample *sample) { delete sample; }

void ps_engine_release_sample(PSEngine *engine, PSSample *sample) {
    Command c = make(Command::ReleaseSample);
    c.sample = sample;
    engine->push(c);
}

int ps_engine_collect_garbage(PSEngine *engine) {
    int n = 0;
    Garbage g;
    while (engine->garbage.pop(g)) {
        delete g.sample;
        delete g.sequence;
        ++n;
    }
    return n;
}

void ps_sampler_set_pad(PSEngine *engine, int pad, const PSPadParams *params) {
    Command c = make(Command::SetPad, pad);
    c.u.pad = *params;
    engine->push(c);
}

void ps_sampler_trigger(PSEngine *engine, int pad, int velocity) {
    ps_sampler_trigger_ex(engine, pad, velocity, 0);
}

void ps_sampler_trigger_ex(PSEngine *engine, int pad, int velocity, float tune) {
    engine->push(make(Command::Trigger, pad, tune, velocity));
}

void ps_sampler_release(PSEngine *engine, int pad) { engine->push(make(Command::Release, pad)); }

void ps_sampler_stop_all(PSEngine *engine) { engine->push(make(Command::StopAll)); }

// Transport & sequences

void ps_transport_play(PSEngine *engine, int start_tick, int count_in_beats) {
    engine->push(make(Command::Play, std::max(0, start_tick), 0, std::max(0, count_in_beats)));
}

void ps_transport_stop(PSEngine *engine) { engine->push(make(Command::Stop)); }

void ps_transport_set_recording(PSEngine *engine, int recording, int guard_ticks) {
    engine->push(make(Command::SetRecording, recording, 0, guard_ticks));
}

int ps_transport_playing(const PSEngine *engine) { return engine->playingOut.load(std::memory_order_relaxed); }

double ps_transport_ticks(const PSEngine *engine) { return engine->ticksOut.load(std::memory_order_relaxed); }

double ps_engine_beat(const PSEngine *engine) { return engine->beatOut.load(std::memory_order_relaxed); }

PSSequence *ps_sequence_create(const PSNoteEvent *events, int count, int length_ticks, int loop) {
    auto *s = new PSSequence;
    s->events.assign(events, events + std::max(0, count));
    std::stable_sort(s->events.begin(), s->events.end(),
                     [](const PSNoteEvent &a, const PSNoteEvent &b) { return a.tick < b.tick; });
    s->lengthTicks = std::max(1, length_ticks);
    s->loop = loop != 0;
    return s;
}

void ps_sequence_destroy(PSSequence *sequence) { delete sequence; }

void ps_engine_queue_sequence(PSEngine *engine, PSSequence *sequence, int at_bar) {
    Command c = make(Command::QueueSequence, at_bar);
    c.sequence = sequence;
    engine->push(c);
}

int ps_transport_sequence_generation(const PSEngine *engine) { return engine->seqGenOut.load(std::memory_order_relaxed); }

void ps_engine_set_sequence(PSEngine *engine, PSSequence *sequence) {
    Command c = make(Command::SetSequence);
    c.sequence = sequence;
    engine->push(c);
}

int ps_engine_poll_recorded(PSEngine *engine, PSRecordedEvent *out, int max) {
    int n = 0;
    while (n < max && engine->recorded.pop(out[n])) ++n;
    return n;
}

void ps_note_repeat_set(PSEngine *engine, double rate_beats, float swing) {
    Command c = make(Command::NoteRepeatSet, 0, swing);
    c.d = rate_beats;
    engine->push(c);
}

void ps_note_repeat_pad(PSEngine *engine, int pad, int velocity, float tune) {
    engine->push(make(Command::NoteRepeatPad, pad, tune, velocity));
}

// Synth performers

void ps_synth_set_performer(PSEngine *engine, int performer) {
    engine->push(make(Command::Performer, performer));
}

void ps_synth_set_rhythm(PSEngine *engine, const PSRhythm *rhythm) {
    Command c = make(Command::Rhythm);
    c.u.rhythm = *rhythm;
    engine->push(c);
}

static Command notesCommand(Command::Type t, int index, const int *notes, int count, int bass) {
    Command c = make(t, index, 0, std::clamp(count, 0, PS_MAX_SLOT_NOTES));
    c.e = bass;
    for (int i = 0; i < c.c; ++i) c.u.notes[i] = notes[i];
    return c;
}

void ps_synth_set_slot(PSEngine *engine, int slot, const int *notes, int count, int bass) {
    engine->push(notesCommand(Command::Slot, slot, notes, count, bass));
}

void ps_synth_set_seq_step(PSEngine *engine, int index, const int *notes, int count, int bass) {
    engine->push(notesCommand(Command::SeqStep, index, notes, count, bass));
}

void ps_synth_set_seq(PSEngine *engine, int length, int playing) {
    engine->push(make(Command::Seq, length, 0, playing));
}

int ps_synth_seq_position(const PSEngine *engine) { return engine->seqPosOut.load(std::memory_order_relaxed); }

void ps_drum_trigger(PSEngine *engine, int voice, int velocity) {
    engine->push(make(Command::DrumHit, voice, 0, velocity));
}

void ps_drum_set_kit(PSEngine *engine, int kit) { engine->push(make(Command::DrumKit, kit)); }

void ps_drum_repeat(PSEngine *engine, int voice, double rate_beats, float swing, int velocity) {
    Command c = make(Command::DrumRepeat, voice, swing, velocity);
    c.d = rate_beats;
    engine->push(c);
}

void ps_beat_set(PSEngine *engine, const PSBeatPattern *pattern, int playing) {
    Command c = make(Command::Beat, playing, 0, pattern ? 1 : 0);
    if (pattern) c.u.beat = *pattern;
    engine->push(c);
}

int ps_beat_position(const PSEngine *engine) { return engine->beatPosOut.load(std::memory_order_relaxed); }

// Looper

static Command loopCommand(Command::Type t, int track, PSSample *buf, int generation) {
    Command c = make(t, track);
    c.sample = buf;
    c.f = generation;
    return c;
}

void ps_looper_record_first(PSEngine *engine, int track, PSSample *buffer, int length_frames,
                            int count_in_beats, int generation) {
    Command c = loopCommand(Command::LoopFirst, track, buffer, generation);
    c.c = std::max(0, length_frames);
    c.e = std::max(0, count_in_beats);
    engine->push(c);
}

void ps_looper_stop_first(PSEngine *engine, int generation) {
    engine->push(loopCommand(Command::LoopStopFirst, 0, nullptr, generation));
}

void ps_looper_arm(PSEngine *engine, int track, PSSample *buffer, int generation) {
    engine->push(loopCommand(Command::LoopArm, track, buffer, generation));
}

void ps_looper_clear(PSEngine *engine, int track, int generation) {
    engine->push(loopCommand(Command::LoopClear, track, nullptr, generation));
}

void ps_looper_clear_all(PSEngine *engine) { engine->push(make(Command::LoopClearAll)); }

void ps_looper_pause(PSEngine *engine, int paused) { engine->push(make(Command::LoopPause, paused)); }

void ps_looper_set_gain(PSEngine *engine, int track, float gain) {
    engine->push(make(Command::LoopGain, track, gain));
}

int ps_looper_track(const PSEngine *engine, int track) {
    if (track < 0 || track >= PS_LOOPER_TRACKS) return 0;
    return engine->loopTrackOut[track].load(std::memory_order_relaxed);
}

int ps_looper_length(const PSEngine *engine) { return engine->loopLengthOut.load(std::memory_order_relaxed); }

double ps_looper_position(const PSEngine *engine) { return engine->loopPosOut.load(std::memory_order_relaxed); }

int ps_looper_recorded(const PSEngine *engine) { return engine->loopRecordedOut.load(std::memory_order_relaxed); }

// Sampling

void ps_engine_push_input(PSEngine *engine, const float *left, const float *right, int frames) {
    engine->input.push(left, right, frames);
}

void ps_recorder_arm(PSEngine *engine, PSSample *buffer, int source, float threshold, int pre_roll_frames) {
    Command c = make(Command::RecArm, source, threshold, pre_roll_frames);
    c.sample = buffer;
    engine->push(c);
}

void ps_recorder_stop(PSEngine *engine) { engine->push(make(Command::RecStop)); }

void ps_recorder_release(PSEngine *engine) { engine->push(make(Command::RecRelease)); }

void ps_recorder_set_meter_source(PSEngine *engine, int source) { engine->push(make(Command::MeterSource, source)); }

int ps_recorder_state(const PSEngine *engine) { return engine->recStateOut.load(std::memory_order_relaxed); }

int ps_recorder_frames(const PSEngine *engine) { return engine->recFramesOut.load(std::memory_order_relaxed); }

float ps_recorder_peak(const PSEngine *engine) { return engine->recPeakOut.load(std::memory_order_relaxed); }

// Audio tracks, arps, retro, clips

void ps_audio_set_slot(PSEngine *engine, int slot, PSSample *sample, float level, float pan) {
    if (slot < 0 || slot >= PS_AUDIO_SLOTS) return;
    PSPadParams p{};
    if (sample) {
        p.layerCount = 1;
        p.layers[0].sample = sample;
        p.layers[0].level = 1;
        p.layers[0].velocityLow = 0;
        p.layers[0].velocityHigh = 127;
    }
    p.oneShot = 0;      // the event's length gates it (cut at the sequence end)
    p.mono = 1;
    p.sustain = 1;
    p.releaseMs = 8;
    p.level = std::max(0.0f, level);
    p.pan = std::clamp(pan, -1.0f, 1.0f);
    ps_sampler_set_pad(engine, Sampler::kAudioBase + slot, &p);
}

void ps_arp_set(PSEngine *engine, int target, int program, const PSArp *arp) {
    Command c = make(Command::ArpSet, target, 0, arp ? 1 : 0);
    c.e = program;
    if (arp) c.u.arp = *arp;
    engine->push(c);
}

int ps_engine_poll_retro(PSEngine *engine, PSRetroEvent *out, int max) {
    int n = 0;
    while (n < max && engine->retro.pop(out[n])) ++n;
    return n;
}

void ps_clip_set(PSEngine *engine, int clip, const PSClipParams *params) {
    Command c = make(Command::ClipSet, clip);
    c.u.clip = *params;
    engine->push(c);
}

void ps_clip_set_quantize(PSEngine *engine, double beats) {
    Command c = make(Command::ClipQuantize);
    c.d = beats;
    engine->push(c);
}

void ps_clip_pad(PSEngine *engine, int clip, int down) { engine->push(make(Command::ClipPad, clip, 0, down)); }

void ps_clip_stop_all(PSEngine *engine) { engine->push(make(Command::ClipStopAll)); }

int ps_clip_state(const PSEngine *engine, int clip) {
    if (clip < 0 || clip >= PS_CLIPS) return 0;
    return engine->clipOut[clip].load(std::memory_order_relaxed);
}

void ps_synth_set_sample(PSEngine *engine, PSSample *sample, float root_note) {
    Command c = make(Command::SynthSample, 0, root_note);
    c.sample = sample;
    engine->push(c);
}

void ps_sampler_preview(PSEngine *engine, PSSample *sample, int start, int end, int velocity) {
    Command c = make(Command::Preview, start, 0, end);
    c.sample = sample;
    c.e = std::clamp(velocity, 1, 127);
    engine->push(c);
}

// Keygroups & live notes

void ps_keygroup_set_program(PSEngine *engine, int program, int zone_count, const PSPadParams *common) {
    Command c = make(Command::KeygroupProgram, program, 0, zone_count);
    c.u.pad = *common;
    engine->push(c);
}

void ps_keygroup_set_zone(PSEngine *engine, int program, int zone, const PSKeygroupZone *z) {
    Command c = make(Command::KeygroupZone, program, 0, zone);
    c.u.zone = *z;
    engine->push(c);
}

void ps_live_note(PSEngine *engine, int target, int program, int note, int velocity) {
    Command c = make(Command::LiveNote, note, 0, std::clamp(velocity, 0, 127));
    c.e = target;
    c.f = program;
    engine->push(c);
}

// MIDI

void ps_engine_set_host_clock(PSEngine *engine, double ticks_per_second, double latency_ticks) {
    // Set before rendering starts (not thread-safe while running).
    engine->hostTicksPerSecond = ticks_per_second > 0 ? ticks_per_second : engine->sampleRate;
    engine->latencyTicks = std::max(0.0, latency_ticks);
}

void ps_engine_render_at(PSEngine *engine, float *left, float *right, int frames, unsigned long long host_time) {
    engine->render(left, right, frames, host_time);
}

int ps_engine_poll_midi_out(PSEngine *engine, PSMidiEvent *out, int max) {
    int n = 0;
    while (n < max && engine->midiOutQueue.pop(out[n])) ++n;
    return n;
}

void ps_engine_midi_in(PSEngine *engine, int status, int data1, int data2) {
    engine->midiInQueue.push(static_cast<uint32_t>(status & 0xff) | static_cast<uint32_t>(data1 & 0x7f) << 8
                             | static_cast<uint32_t>(data2 & 0x7f) << 16);
}

// Mixer

void ps_mixer_set_submix(PSEngine *engine, int index, float level, float pan, int mute, int insert, float amount) {
    Command c = make(Command::MixSubmix, index, level, mute);
    c.d = pan;
    c.e = insert;
    c.f = static_cast<int32_t>(std::lround(std::clamp(amount, 0.0f, 1.0f) * 1000));
    engine->push(c);
}

void ps_mixer_set_return(PSEngine *engine, int index, int type, float level) {
    engine->push(make(Command::MixReturn, index, level, type));
}

void ps_mixer_set_xy(PSEngine *engine, int type, float x, float y, int active) {
    Command c = make(Command::MixXY, type, x, active);
    c.d = y;
    engine->push(c);
}

void ps_engine_render(PSEngine *engine, float *left, float *right, int frames) {
    engine->render(left, right, frames);
}

int ps_engine_active_voices(const PSEngine *engine) {
    return engine->synthActive.load(std::memory_order_relaxed);
}

int ps_sampler_active_voices(const PSEngine *engine) {
    return engine->samplerActive.load(std::memory_order_relaxed);
}

void ps_sampler_pad_hits(const PSEngine *engine, unsigned int *counts, unsigned char *velocities, int max) {
    const int n = std::clamp(max, 0, static_cast<int>(PS_SAMPLER_PADS));
    for (int i = 0; i < n; ++i) {
        counts[i] = engine->sampler.hitCount(i);
        velocities[i] = engine->sampler.hitVelocity(i);
    }
}

} // extern "C"
