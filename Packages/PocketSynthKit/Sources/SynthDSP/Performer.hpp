// Synth performers (SYNTH_SPEC §4): turn "chord slot N holds these notes" into notes over
// time. Play holds notes (reference-counted, so shared notes keep ringing); Strum rolls
// them; Arp, Repeat, the chord sequencer, drum repeat and the beat player step on the
// engine's beat grid.
#pragma once

#include "Drums.hpp"
#include "Synth.hpp"
#include "Transport.hpp"

namespace ps {

struct Slot {
    std::array<int, PS_MAX_SLOT_NOTES> notes{};
    int count = 0;
    int bass = -1;
    bool active() const { return count > 0 || bass >= 0; }
    bool contains(int n) const {
        if (n == bass) return true;
        for (int i = 0; i < count; ++i) if (notes[i] == n) return true;
        return false;
    }
};

using EngineScheduler = Scheduler<512>;

class Performer {
public:
    static constexpr float kVelocity = 100.0f / 127.0f;
    // 32-step stutter gate (1 = sound).
    static constexpr uint32_t kStutter = 0b10110110'11101010'10111011'01101101u;

    Performer(double sr, Synth &synth, Drums &drums, EngineScheduler &sched)
        : sr_(sr), synth_(synth), drums_(drums), sched_(sched) {}

    // Clock context, set by the engine before each batch of commands / each block.
    void setContext(double beat, bool transportPlaying, uint64_t frame, double framesPerBeat) {
        beat_ = beat; transport_ = transportPlaying; frame_ = frame; framesPerBeat_ = framesPerBeat;
    }

    void setMode(int perf) {
        allOff();
        mode_ = std::clamp(perf, 0, static_cast<int>(PS_PERF_BEAT));
    }
    int mode() const { return mode_; }

    void setRhythm(const PSRhythm &r) { rhythm_ = r; }
    void setReleaseMs(double ms) { releaseMs_ = ms; }

    void allOff() {
        for (auto &s : slots_) s = Slot{};
        ref_.fill(0);
        sched_.removeIf([](const Pending &p) { return p.kind == Pending::SynthOn || p.kind == Pending::SynthOff; });
        synth_.allOff();
        seqPlaying_ = false;
        seqPos_ = -1;
        heldSeq_ = Slot{};
        beatPlaying_ = false;
        beatPos_ = -1;
        for (auto &d : drumRepeat_) d.rate = 0;
        poolWasEmpty_ = true;
    }

    // MARK: Chord slots ---------------------------------------------------------

    void setSlot(int slot, const int *notes, int count, int bass) {
        if (slot < 0 || slot >= PS_SYNTH_SLOTS) return;
        Slot next;
        next.count = std::clamp(count, 0, PS_MAX_SLOT_NOTES);
        for (int i = 0; i < next.count; ++i) next.notes[i] = std::clamp(notes[i], 0, 127);
        next.bass = bass >= 0 ? std::clamp(bass, 0, 127) : -1;
        std::sort(next.notes.begin(), next.notes.begin() + next.count);
        const Slot prev = slots_[slot];
        slots_[slot] = next;

        switch (mode_) {
        case PS_PERF_PLAY:
        case PS_PERF_SEQ: // live pads preview over the chord sequencer
            transition(prev, next, 0, slot, kVelocity);
            break;
        case PS_PERF_STRUM:
            if (!next.active()) sched_.removeIf([&](const Pending &p) { return p.kind == Pending::SynthOn && p.slot == slot; });
            transition(prev, next, rhythm_.strumMs * 0.001 * sr_, slot, kVelocity);
            break;
        case PS_PERF_ARP: {
            // The bass (and in CHORD+ARP the chord) is held; the rest is arpeggiated.
            Slot hp = heldPart(prev), hn = heldPart(next);
            transition(hp, hn, 0, slot, rhythm_.arpLayer == 1 ? 0.45f : kVelocity);
            restartIfFirst(arpGrid_, rhythm_.arpRateBeats, rhythm_.arpSwing);
            if (rhythm_.arpLayer == 2) rhythmGrid_ = Grid{1.0, 0.5, arpGrid_.origin};
            break;
        }
        case PS_PERF_REPEAT:
            restartIfFirst(repeatGrid_, rhythm_.repeatStutter ? 0.125 : rhythm_.repeatRateBeats,
                           rhythm_.repeatStutter ? 0.5f : rhythm_.repeatSwing);
            break;
        default:
            break;
        }
    }

    // MARK: Chord sequencer -----------------------------------------------------

    void setSeqStep(int index, const int *notes, int count, int bass) {
        if (index < 0 || index >= PS_SEQ_STEPS) return;
        Slot &s = seq_[index];
        s = Slot{};
        s.count = std::clamp(count, 0, PS_MAX_SLOT_NOTES);
        for (int i = 0; i < s.count; ++i) s.notes[i] = std::clamp(notes[i], 0, 127);
        s.bass = bass >= 0 ? bass : -1;
    }

    void setSeq(int length, bool playing) {
        seqLength_ = std::clamp(length, 1, PS_SEQ_STEPS);
        if (playing && !seqPlaying_) {
            seqGrid_ = Grid{std::max(0.0625, rhythm_.seqRateBeats), 0.5, transport_ ? 0.0 : beat_};
            seqCounter_ = 0;
        }
        if (!playing && seqPlaying_) {
            transition(heldSeq_, Slot{}, 0, 0, kVelocity);
            heldSeq_ = Slot{};
            seqPos_ = -1;
        }
        seqPlaying_ = playing;
    }
    int seqPosition() const { return seqPos_; }

    // MARK: Drums ----------------------------------------------------------------

    void drumRepeat(int voice, double rate, float swing, int velocity) {
        if (voice < 0 || voice >= PS_DRUM_VOICES) return;
        auto &d = drumRepeat_[voice];
        if (rate > 0 && (d.rate <= 0 || d.grid.rate != rate || d.grid.swing != swing)) {
            d.grid = Grid{rate, swing, transport_ ? 0.0 : beat_};
            // Fire right away when starting off the grid while the transport is stopped.
        }
        d.rate = rate;
        d.velocity = velocity;
    }

    void setBeat(const PSBeatPattern *pattern, bool playing) {
        if (pattern) {
            beat_pattern_ = *pattern;
            beat_pattern_.steps = std::clamp(beat_pattern_.steps, 1, PS_BEAT_MAX_STEPS);
            if (beat_pattern_.stepBeats <= 0) beat_pattern_.stepBeats = 0.25;
        }
        if (playing && !beatPlaying_) {
            // Start on the next bar line when the transport runs; right away otherwise.
            beatGrid_ = Grid{beat_pattern_.stepBeats, beat_pattern_.swing, transport_ ? 0.0 : beat_};
        } else {
            beatGrid_.rate = beat_pattern_.stepBeats;
            beatGrid_.swing = beat_pattern_.swing;
        }
        beatPlaying_ = playing;
        if (!playing) beatPos_ = -1;
    }
    int beatPosition() const { return beatPos_; }

    // MARK: Time ----------------------------------------------------------------

    /// Fires every grid step in [b0, b1).
    void process(double b0, double b1) {
        switch (mode_) {
        case PS_PERF_ARP: processArp(b0, b1); break;
        case PS_PERF_REPEAT: processRepeat(b0, b1); break;
        default: break;
        }
        if (seqPlaying_) {
            seqGrid_.each(b0, b1, [&](int64_t, double) {
                const Slot &step = seq_[seqCounter_ % seqLength_];
                seqPos_ = seqCounter_ % seqLength_;
                ++seqCounter_;
                transition(heldSeq_, Slot{}, 0, 0, kVelocity); // retrigger every step
                transition(Slot{}, step, 0, 0, kVelocity);
                heldSeq_ = step;
            });
        }
        for (int v = 0; v < PS_DRUM_VOICES; ++v) {
            auto &d = drumRepeat_[v];
            if (d.rate > 0) d.grid.each(b0, b1, [&](int64_t, double) { drums_.trigger(v, d.velocity); });
        }
        if (beatPlaying_) {
            beatGrid_.each(b0, b1, [&](int64_t k, double) {
                const int n = beat_pattern_.steps;
                const int step = static_cast<int>(((k % n) + n) % n);
                beatPos_ = step;
                for (int v = 0; v < PS_DRUM_VOICES; ++v)
                    if (const int vel = beat_pattern_.velocity[step][v]) drums_.trigger(v, vel);
            });
        }
    }

    /// Handles SynthOn / SynthOff events from the scheduler.
    void pending(const Pending &p) {
        if (p.kind == Pending::SynthOn) {
            if (ref_[p.a] > 0) synth_.noteOn(p.a, p.velocity, p.bass);
        } else if (p.kind == Pending::SynthOff) {
            if (ref_[p.a] == 0) synth_.noteOff(p.a); // never cut a note a pad still holds
        }
    }

    int heldCount(int note) const { return ref_[std::clamp(note, 0, 127)]; }

private:
    struct DrumRepeat { Grid grid; double rate = 0; int velocity = 100; };

    /// Moves held notes from `a` to `b`. New notes start after `spread` frames each
    /// (strum: lowest first, bass with the first note).
    void transition(const Slot &a, const Slot &b, double spread, int slot, float velocity) {
        if (a.bass >= 0 && !b.contains(a.bass)) unhold(a.bass);
        for (int i = 0; i < a.count; ++i) if (!b.contains(a.notes[i])) unhold(a.notes[i]);
        if (b.bass >= 0 && !a.contains(b.bass)) hold(b.bass, true, velocity, 0, slot);
        int order = 0;
        for (int i = 0; i < b.count; ++i) {
            if (a.contains(b.notes[i]) || b.notes[i] == b.bass) continue;
            hold(b.notes[i], false, velocity, static_cast<uint64_t>(spread * order), slot);
            ++order;
        }
    }

    void hold(int note, bool bass, float velocity, uint64_t delay, int slot) {
        if (ref_[note]++ > 0) return;
        if (delay == 0) {
            synth_.noteOn(note, velocity, bass);
        } else {
            Pending p;
            p.kind = Pending::SynthOn;
            p.a = static_cast<int16_t>(note);
            p.velocity = velocity;
            p.bass = bass;
            p.slot = static_cast<uint8_t>(slot);
            p.at = frame_ + delay;
            sched_.add(p);
        }
    }

    void unhold(int note) {
        if (ref_[note] <= 0) return;
        if (--ref_[note] == 0) synth_.noteOff(note);
    }

    void scheduleOff(int note, double beats) {
        Pending p;
        p.kind = Pending::SynthOff;
        p.a = static_cast<int16_t>(note);
        p.at = frame_ + static_cast<uint64_t>(std::max(1.0, beats * framesPerBeat_));
        sched_.add(p);
    }

    Slot heldPart(const Slot &s) const {
        Slot h;
        h.bass = s.bass;
        if (rhythm_.arpLayer == 1) { h.count = s.count; h.notes = s.notes; }
        return h;
    }

    bool anyActive() const {
        for (auto &s : slots_) if (s.active()) return true;
        return false;
    }

    /// When the first chord arrives: restart the pattern and, with the transport stopped,
    /// put step 0 right now so the first note isn't late.
    void restartIfFirst(Grid &g, double rate, float swing) {
        const bool active = anyActive();
        if (active && poolWasEmpty_) {
            g = Grid{std::max(1.0 / 64, rate), std::clamp(swing, 0.5f, 0.75f), transport_ ? 0.0 : beat_};
            counter_ = 0;
        } else {
            g.rate = std::max(1.0 / 64, rate);
            g.swing = std::clamp(swing, 0.5f, 0.75f);
        }
        poolWasEmpty_ = !active;
    }

    int pool(int *out, bool withBass) const {
        int n = 0;
        for (auto &s : slots_) {
            if (withBass && s.bass >= 0) out[n++] = s.bass;
            for (int i = 0; i < s.count; ++i) out[n++] = s.notes[i];
        }
        std::sort(out, out + n);
        return static_cast<int>(std::unique(out, out + n) - out);
    }

    int pick(int n) {
        const int i = static_cast<int>(counter_++ & 0x7fffffff);
        switch (rhythm_.arpPattern) {
        case 1: return n - 1 - i % n;
        case 2:
        case 3: {
            if (n == 1) return 0;
            const int period = 2 * n - 2, j = i % period;
            const int up = j < n ? j : period - j;
            return rhythm_.arpPattern == 2 ? up : n - 1 - up;
        }
        case 4:
            rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;
            return static_cast<int>(rng_ % static_cast<uint32_t>(n));
        default: return i % n;
        }
    }

    double gateBeats(double rate) const {
        // The release time sets the gate (SYNTH_SPEC §4), kept inside the step.
        const double releaseBeats = releaseMs_ * 0.001 * sr_ / std::max(1.0, framesPerBeat_);
        return std::clamp(releaseBeats, 0.1 * rate, 0.95 * rate);
    }

    void processArp(double b0, double b1) {
        int notes[PS_SYNTH_SLOTS * PS_MAX_SLOT_NOTES];
        const int n = pool(notes, false);
        if (n == 0) { poolWasEmpty_ = true; return; }
        const int lift = rhythm_.arpLayer == 0 ? 0 : 12; // stay clear of the held chord
        arpGrid_.each(b0, b1, [&](int64_t, double) {
            const int note = std::min(127, notes[pick(n)] + lift);
            synth_.noteOn(note, 0.85f, false);
            scheduleOff(note, gateBeats(arpGrid_.rate));
        });
        if (rhythm_.arpLayer == 2) {
            rhythmGrid_.each(b0, b1, [&](int64_t, double) {
                for (int i = 0; i < n; ++i) {
                    synth_.noteOn(notes[i], 0.45f, false);
                    scheduleOff(notes[i], 0.45);
                }
            });
        }
    }

    void processRepeat(double b0, double b1) {
        int notes[PS_SYNTH_SLOTS * (PS_MAX_SLOT_NOTES + 1)];
        const int n = pool(notes, true);
        if (n == 0) { poolWasEmpty_ = true; return; }
        repeatGrid_.each(b0, b1, [&](int64_t k, double) {
            if (rhythm_.repeatStutter && !((kStutter >> (static_cast<uint64_t>(k) & 31)) & 1)) return;
            for (int i = 0; i < n; ++i) {
                bool bass = false;
                for (auto &s : slots_) if (s.bass == notes[i]) bass = true;
                synth_.noteOn(notes[i], kVelocity, bass);
                scheduleOff(notes[i], 0.5 * repeatGrid_.rate);
            }
        });
    }

    double sr_;
    Synth &synth_;
    Drums &drums_;
    EngineScheduler &sched_;

    int mode_ = PS_PERF_PLAY;
    PSRhythm rhythm_{80, 0, 0, 0.5, 0.5f, 0.5, 0.5f, 0, 1.0};
    double releaseMs_ = 1000;

    double beat_ = 0, framesPerBeat_ = 24000;
    bool transport_ = false;
    uint64_t frame_ = 0;

    std::array<Slot, PS_SYNTH_SLOTS> slots_{};
    std::array<int, 128> ref_{};

    Grid arpGrid_, rhythmGrid_, repeatGrid_;
    uint64_t counter_ = 0;
    uint32_t rng_ = 0x2545F491u;
    bool poolWasEmpty_ = true;

    std::array<Slot, PS_SEQ_STEPS> seq_{};
    Slot heldSeq_;
    Grid seqGrid_;
    int seqLength_ = 4;
    bool seqPlaying_ = false;
    int64_t seqCounter_ = 0;
    int seqPos_ = -1;

    std::array<DrumRepeat, PS_DRUM_VOICES> drumRepeat_{};
    PSBeatPattern beat_pattern_{};
    Grid beatGrid_{0.25, 0.5, 0};
    bool beatPlaying_ = false;
    int beatPos_ = -1;
};

} // namespace ps
