// Timing building blocks: the beat grid, a frame-time scheduler, sequences and the
// metronome click. All of it is allocation-free on the audio thread.
#pragma once

#include "DSPCommon.hpp"
#include "include/SynthDSP.h"

struct PSSequence {
    std::vector<PSNoteEvent> events; // sorted by tick
    int lengthTicks = 4 * 4 * PS_PPQN;
    bool loop = true;
};

namespace ps {

constexpr double kPPQ = PS_PPQN;

/// Steps at origin + k·rate. Odd steps are pushed late by swing (0.5 = straight,
/// 0.66 ≈ triplet feel). Stateless, so clock jumps (transport start) are harmless.
struct Grid {
    double rate = 0.5;
    double swing = 0.5;
    double origin = 0;

    double time(int64_t k) const {
        return origin + static_cast<double>(k) * rate + ((k & 1) ? (swing - 0.5) * 2.0 * rate : 0.0);
    }

    /// Calls fire(k, beatTime) for every step in [b0, b1).
    template <typename F>
    void each(double b0, double b1, F &&fire) const {
        if (rate <= 0) return;
        int64_t k = static_cast<int64_t>(std::floor((b0 - origin) / rate)) - 1;
        for (;; ++k) {
            const double t = time(k);
            if (t >= b1) break;
            if (t >= b0) fire(k, t);
        }
    }

    /// The latest step at or before b.
    int64_t last(double b) const {
        int64_t k = static_cast<int64_t>(std::floor((b - origin) / rate)) + 1;
        while (time(k) > b) --k;
        return k;
    }
};

/// Events due at a sample-clock frame: note-offs, strummed note-ons, pad releases.
struct Pending {
    enum Kind : uint8_t { SynthOn, SynthOff, PadRelease, DrumOff } kind = SynthOff;
    uint8_t slot = 0;       // strum: which chord slot scheduled it
    bool bass = false;
    int16_t a = 0;          // note / pad
    float velocity = 0;
    uint64_t at = 0;        // engine frame
};

template <size_t N>
class Scheduler {
public:
    void add(const Pending &p) {
        if (count_ < N) items_[count_++] = p;
    }
    /// Removes and handles every event with at < until.
    template <typename F>
    void due(uint64_t until, F &&f) {
        for (size_t i = 0; i < count_;) {
            if (items_[i].at < until) {
                const Pending p = items_[i];
                items_[i] = items_[--count_];
                f(p);
            } else {
                ++i;
            }
        }
    }
    template <typename P>
    void removeIf(P &&pred) {
        for (size_t i = 0; i < count_;) {
            if (pred(items_[i])) items_[i] = items_[--count_];
            else ++i;
        }
    }
    void clear() { count_ = 0; }
    size_t size() const { return count_; }

private:
    std::array<Pending, N> items_{};
    size_t count_ = 0;
};

/// Short sine blip; accented on the downbeat.
struct Click {
    double phase = 0, inc = 0, env = 0, coef = 0;
    void trigger(bool accent, double sr) {
        inc = (accent ? 2000.0 : 1300.0) / sr;
        env = accent ? 1.0 : 0.7;
        coef = expCoef(30, sr);
        phase = 0;
    }
    float next() {
        if (env < 1e-4) return 0;
        const double s = std::sin(kTwoPi * phase) * env;
        phase += inc;
        env *= coef;
        return static_cast<float>(s);
    }
};

} // namespace ps
