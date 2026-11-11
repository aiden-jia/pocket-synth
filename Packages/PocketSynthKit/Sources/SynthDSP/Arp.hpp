// Track arpeggiator (SAMPLER_SPEC §6): notes sent to one destination (target + program)
// are held here and played back one at a time on the beat grid.
#pragma once

#include "DSPCommon.hpp"
#include "Transport.hpp"
#include "include/SynthDSP.h"

namespace ps {

class TrackArp {
public:
    static constexpr int kMaxNotes = 16;

    bool active = false;
    int target = 0, program = 0;

    void configure(int t, int prog, const PSArp &s) {
        if (!active || t != target || prog != program) reset();
        active = true;
        target = t;
        program = prog;
        settings_ = s;
        settings_.octaves = std::clamp(s.octaves, 1, 4);
        settings_.rateBeats = std::max(1.0 / 32, s.rateBeats);
        settings_.gate = std::clamp(s.gate, 0.05f, 1.0f);
        grid_.rate = settings_.rateBeats;
        if (!settings_.latch && down_ == 0) clear();
    }

    void remove() { active = false; reset(); }

    /// A note arrives (velocity 0 = released). `beat` = now; `aligned` = transport running.
    void input(int note, int velocity, double beat, bool aligned) {
        if (velocity > 0) {
            if (settings_.latch && down_ == 0) clear(); // a new chord replaces the latched one
            ++down_;
            for (int i = 0; i < count_; ++i) if (notes_[i] == note) { vel_[i] = velocity; return; }
            if (count_ >= kMaxNotes) return;
            notes_[count_] = note;
            vel_[count_] = velocity;
            ++count_;
            if (!running_) start(beat, aligned);
        } else {
            down_ = std::max(0, down_ - 1);
            if (settings_.latch) return;
            for (int i = 0; i < count_; ++i)
                if (notes_[i] == note) {
                    for (int j = i; j + 1 < count_; ++j) { notes_[j] = notes_[j + 1]; vel_[j] = vel_[j + 1]; }
                    --count_;
                    break;
                }
            if (count_ == 0) running_ = false;
        }
    }

    /// Calls play(note, velocity, gateBeats) for every step in [b0, b1).
    template <typename F>
    void process(double b0, double b1, F &&play) {
        if (!active || !running_ || count_ == 0) return;
        grid_.each(b0, b1, [&](int64_t k, double) {
            if (k == lastStep_) return;
            lastStep_ = k;
            int note = 0, vel = 0;
            pick(step_++, note, vel);
            play(note, vel, settings_.gate * settings_.rateBeats);
        });
    }

    /// For tests: the pattern position (notes played so far).
    int64_t steps() const { return step_; }

private:
    void reset() {
        clear();
        down_ = 0;
    }

    void clear() {
        count_ = 0;
        running_ = false;
    }

    void start(double beat, bool aligned) {
        running_ = true;
        step_ = 0;
        if (aligned) {
            grid_.origin = 0;
            // Just after a step counts as that step (played a touch late); otherwise wait.
            const int64_t k = grid_.last(beat);
            lastStep_ = beat - grid_.time(k) < 0.3 * grid_.rate ? k - 1 : k;
        } else {
            grid_.origin = beat; // stopped: start on the first note
            lastStep_ = INT64_MIN;
        }
    }

    /// The `n`th note of the pattern.
    void pick(int64_t n, int &note, int &vel) {
        std::array<int, kMaxNotes> order{};
        for (int i = 0; i < count_; ++i) order[i] = i;
        if (settings_.mode != PS_ARP_ORDER)
            std::sort(order.begin(), order.begin() + count_, [&](int a, int b) { return notes_[a] < notes_[b]; });
        const int len = count_ * settings_.octaves;
        int idx = 0;
        switch (settings_.mode) {
        case PS_ARP_DOWN: idx = len - 1 - static_cast<int>(n % len); break;
        case PS_ARP_UPDOWN: {
            const int period = len > 1 ? 2 * len - 2 : 1;
            const int p = static_cast<int>(n % period);
            idx = p < len ? p : period - p;
            break;
        }
        case PS_ARP_UPDOWN_INCL: {
            const int period = 2 * len;
            const int p = static_cast<int>(n % period);
            idx = p < len ? p : period - 1 - p;
            break;
        }
        case PS_ARP_RANDOM: idx = static_cast<int>(rng_.white() * 0.5f * len + 0.5f * len) % len; break;
        default: idx = static_cast<int>(n % len); break; // up, order
        }
        const int i = order[idx % count_];
        note = std::clamp(notes_[i] + 12 * (idx / count_), 0, 127);
        vel = vel_[i];
    }

    PSArp settings_{};
    Grid grid_{0.25, 0.5, 0};
    std::array<int, kMaxNotes> notes_{}, vel_{};
    int count_ = 0, down_ = 0;
    bool running_ = false;
    int64_t step_ = 0, lastStep_ = INT64_MIN;
    Noise rng_{0xA12F};
};

} // namespace ps
