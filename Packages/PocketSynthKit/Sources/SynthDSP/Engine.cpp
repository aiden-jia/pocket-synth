// PocketSynth engine: one beat clock, the synth (performers → voices → FX chain), the
// drum machine, the sampler with its sequencer and note repeat, and a small mixer.
// Driven through a single ordered lock-free command FIFO. Render is real-time safe.
//
// Timing: audio is rendered in sub-blocks of up to kSub frames. Before each sub-block the
// engine fires everything due inside it (scheduled note-offs, grid steps, sequence
// events), so events land within kSub frames (0.67 ms at 48 kHz) of their exact time.

#include "include/SynthDSP.h"

#include "DSPCommon.hpp"
#include "Drums.hpp"
#include "Effects.hpp"
#include "Looper.hpp"
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
        Performer, Rhythm, Slot, SeqStep, Seq, DrumHit, DrumKit, DrumRepeat, Beat,
        LoopFirst, LoopStopFirst, LoopArm, LoopClear, LoopClearAll, LoopPause, LoopGain,
        RecArm, RecStop, RecRelease, MeterSource, Preview,
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
    Click click;
    Looper looper;
    Recorder recorder;
    InputRing input;

    // Clock & transport.
    double bpm = 120;
    double beat = 0;
    uint64_t frame = 0;
    bool playing = false;
    bool recording = false;
    double guardTicks = 0;
    PSSequence *sequence = nullptr;
    std::array<double, PS_SAMPLER_PADS> lastLiveTick{};
    bool metronome = false;
    double metronomeLevel = 0.5;
    int beatsPerBar = 4;

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
    std::atomic<int> playingOut{0}, seqPosOut{-1}, beatPosOut{-1};
    std::array<std::atomic<int>, PS_LOOPER_TRACKS> loopTrackOut{};
    std::atomic<int> loopLengthOut{0}, loopRecordedOut{0};
    std::atomic<double> loopPosOut{0};
    std::atomic<int> recStateOut{0}, recFramesOut{0};
    std::atomic<float> recPeakOut{0};

    // Scratch buses, preallocated.
    std::array<float, kSub> chordL{}, chordR{}, bassL{}, bassR{}, smpL{}, smpR{}, drumL{}, drumR{};
    std::array<float, kSub> synthL{}, synthR{}, loopL{}, loopR{}, mixL{}, mixR{};
    std::array<float, 512> inL{}, inR{};

    explicit PSEngine(double sr)
        : sampleRate(sr), synth(sr), sampler(sr), drums(sr), performer(sr, synth, drums, scheduler),
          delay(sr), filter(sr), tremolo(sr),
          chorus(sr, kChorusTypes, 4), flanger(sr, kFlangerTypes, 4), drive(sr), tape(sr), reverb(sr),
          looper(sr, Looper::Release{this, [](void *ctx, PSSample *s) {
              static_cast<PSEngine *>(ctx)->garbage.push(Garbage{s, nullptr});
          }}),
          recorder(sr), input(static_cast<size_t>(4 * sr)) {
        lastLiveTick.fill(-1e12);
    }

    ~PSEngine() { delete sequence; }

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
        default: break;
        }
    }

    // MARK: Transport ----------------------------------------------------------

    double ticks() const { return beat * kPPQ; }

    /// Position inside the sequence for display (wrapped when looping).
    double position() const {
        const double t = ticks();
        if (!playing || t < 0 || !sequence) return playing ? t : 0;
        const double len = sequence->lengthTicks;
        return sequence->loop ? std::fmod(t, len) : std::min(t, len);
    }

    /// Queues a live hit for recording. `absTick` is the unwrapped transport position.
    void stamp(int pad, int velocity, float tune, double absTick) {
        if (!recording || !playing) return;
        PSRecordedEvent e;
        e.tick = static_cast<int>(std::lround(recordTick(absTick)));
        e.pad = pad;
        e.velocity = velocity;
        e.tune = tune;
        recorded.push(e);
        if (velocity > 0 && pad >= 0 && pad < PS_SAMPLER_PADS) lastLiveTick[pad] = absTick;
    }

    /// Recorded positions wrap with the loop, so a take over several passes lands in place.
    double recordTick(double absTick) const {
        if (!sequence || !sequence->loop || absTick < 0) return absTick;
        return std::fmod(absTick, static_cast<double>(sequence->lengthTicks));
    }

    void liveTrigger(int pad, int velocity, float tune) {
        sampler.trigger(pad, velocity, tune);
        stamp(pad, velocity, tune, ticks());
    }

    void releaseAllScheduledPads() {
        scheduler.due(UINT64_MAX, [&](const Pending &p) {
            if (p.kind == Pending::PadRelease) sampler.release(p.a);
            else performer.pending(p);
        });
    }

    void playSequenceRange(double t0, double t1) {
        if (!sequence || t1 <= 0) return;
        t0 = std::max(t0, 0.0);
        const double len = sequence->lengthTicks;
        if (!sequence->loop) {
            if (t0 >= len) { playing = false; releaseAllScheduledPads(); return; }
            fireEvents(t0, std::min(t1, len), 0);
            return;
        }
        const double base = std::floor(t0 / len) * len;
        const double p0 = t0 - base, p1 = t1 - base;
        if (p1 <= len) {
            fireEvents(p0, p1, base);
        } else {
            fireEvents(p0, len, base);
            fireEvents(0, p1 - len, base + len);
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
            if (recording && std::fabs(abs - lastLiveTick[it->pad]) < guardTicks) continue;
            sampler.trigger(it->pad, it->velocity, it->tune);
            Pending p;
            p.kind = Pending::PadRelease;
            p.a = static_cast<int16_t>(it->pad);
            p.at = frame + static_cast<uint64_t>(std::max(1.0, it->length * framesPerTick));
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
                looper.forget(c.sample);
                recorder.forget(c.sample);
                if (!garbage.push(Garbage{c.sample, nullptr})) { /* full: leak rather than free here */ }
                break;
            case Command::Play:
                beat = c.a / kPPQ - c.c;
                playing = true;
                lastLiveTick.fill(-1e12);
                break;
            case Command::Stop:
                playing = false;
                releaseAllScheduledPads();
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

        scheduler.due(frame + static_cast<uint64_t>(n), [&](const Pending &p) {
            if (p.kind == Pending::PadRelease) sampler.release(p.a);
            else performer.pending(p);
        });

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
        processNoteRepeat(b0, b1);
        performer.process(b0, b1);

        renderAudio(L, R, n);
        beat = b1;
        frame += static_cast<uint64_t>(n);
    }

    void renderAudio(float *L, float *R, int n) {
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
        chorus.process(cl, cr, n);
        flanger.process(cl, cr, n);
        drive.process(cl, cr, n);
        tape.process(cl, cr, n);
        for (int i = 0; i < n; ++i) { cl[i] += drumL[i]; cr[i] += drumR[i]; }
        reverb.process(cl, cr, n);

        sampler.render(smpL.data(), smpR.data(), n);

        // Synth panel output (what the looper records), then the loops on top of it.
        const double k = 1.0 - std::exp(-1.0 / (0.01 * sampleRate));
        for (int i = 0; i < n; ++i) {
            synthVolume += (synthVolumeT - synthVolume) * k;
            synthL[i] = static_cast<float>(cl[i] * synthVolume);
            synthR[i] = static_cast<float>(cr[i] * synthVolume);
            loopL[i] = loopR[i] = 0;
        }
        looper.process(synthL.data(), synthR.data(), loopL.data(), loopR.data(), n, beat, 1.0 / framesPerBeat());
        for (int i = 0; i < n; ++i) { synthL[i] += loopL[i]; synthR[i] += loopR[i]; }

        for (int i = 0; i < n; ++i) {
            synthLevel += (synthLevelT - synthLevel) * k;
            samplerLevel += (samplerLevelT - samplerLevel) * k;
            master += (masterT - master) * k;
            mixL[i] = static_cast<float>((synthL[i] * synthLevel + smpL[i] * samplerLevel) * master);
            mixR[i] = static_cast<float>((synthR[i] * synthLevel + smpR[i] * samplerLevel) * master);
        }
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
        performer.setContext(beat, playing, frame, framesPerBeat());
        drain();
        // Mic / interface input goes straight to the recorder (it arrives in bursts).
        for (int got; (got = input.pop(inL.data(), inR.data(), static_cast<int>(inL.size()))) > 0;)
            recorder.feed(PS_SOURCE_INPUT, inL.data(), inR.data(), got);
        for (int off = 0; off < frames; off += kSub)
            renderSub(L + off, R + off, std::min(kSub, frames - off));
        synthActive.store(synth.activeVoices() + drums.activeVoices(), std::memory_order_relaxed);
        samplerActive.store(sampler.activeVoices(), std::memory_order_relaxed);
        beatOut.store(beat, std::memory_order_relaxed);
        ticksOut.store(position(), std::memory_order_relaxed);
        playingOut.store(playing ? 1 : 0, std::memory_order_relaxed);
        seqPosOut.store(performer.seqPosition(), std::memory_order_relaxed);
        beatPosOut.store(performer.beatPosition(), std::memory_order_relaxed);
        for (int t = 0; t < PS_LOOPER_TRACKS; ++t) loopTrackOut[t].store(looper.packed(t), std::memory_order_relaxed);
        loopLengthOut.store(looper.length(), std::memory_order_relaxed);
        loopPosOut.store(looper.position(), std::memory_order_relaxed);
        loopRecordedOut.store(looper.recorded(), std::memory_order_relaxed);
        recStateOut.store(recorder.state(), std::memory_order_relaxed);
        recFramesOut.store(recorder.frames(), std::memory_order_relaxed);
        recPeakOut.store(recorder.peak(), std::memory_order_relaxed);
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

void ps_sampler_preview(PSEngine *engine, PSSample *sample, int start, int end, int velocity) {
    Command c = make(Command::Preview, start, 0, end);
    c.sample = sample;
    c.e = std::clamp(velocity, 1, 127);
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

} // extern "C"
