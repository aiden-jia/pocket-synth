// Sampler mixer routing (SAMPLER_SPEC §8): 8 submixes with one insert each, 4 returns
// (fully wet effects fed by per-pad sends), and the XY performance effect on the master.
#pragma once

#include "DSPCommon.hpp"
#include "Effects.hpp"
#include "include/SynthDSP.h"

namespace ps {

constexpr int kSubmixes = PS_SUBMIXES;
constexpr int kReturns = PS_RETURNS;

/// Resonant low-pass / high-pass with a smoothed cutoff.
struct FilterFX {
    double sr = 48000, cutoff = 20000, target = 20000, q = 0.707;
    bool highpass = false;
    SVF l, r;

    void process(float *L, float *R, int n) {
        const double smooth = 1.0 - std::exp(-1.0 / (0.01 * sr));
        const double k = 1.0 / std::max(0.5, q);
        for (int i = 0; i < n; ++i) {
            cutoff += (target - cutoff) * smooth;
            const double g = SVF::gFor(cutoff, sr);
            l.process(L[i], g, k);
            r.process(R[i], g, k);
            L[i] = static_cast<float>(highpass ? l.hp : l.lp);
            R[i] = static_cast<float>(highpass ? r.hp : r.lp);
        }
    }
};

/// Bit depth reduction + sample-and-hold.
struct Crusher {
    double bits = 16, downsample = 1, phase = 0;
    float heldL = 0, heldR = 0;

    void process(float *L, float *R, int n) {
        const double levels = std::pow(2.0, std::clamp(bits, 1.0, 16.0) - 1);
        for (int i = 0; i < n; ++i) {
            phase += 1;
            if (phase >= downsample) {
                phase -= downsample;
                heldL = static_cast<float>(std::round(L[i] * levels) / levels);
                heldR = static_cast<float>(std::round(R[i] * levels) / levels);
            }
            L[i] = heldL;
            R[i] = heldR;
        }
    }
};

/// One submix bus: insert → pan / level / mute, summed into the sampler bus.
class Submix {
public:
    explicit Submix(double sr) : drive_(sr) { filter_.sr = sr; }

    void set(float level, float pan, bool mute, int insert, float amount) {
        levelT_ = mute ? 0 : std::clamp(level, 0.0f, 1.5f);
        pan_ = std::clamp(pan, -1.0f, 1.0f);
        insert_ = insert;
        amount_ = std::clamp(amount, 0.0f, 1.0f);
        switch (insert) {
        case PS_INSERT_LOWPASS:
        case PS_INSERT_HIGHPASS:
            filter_.highpass = insert == PS_INSERT_HIGHPASS;
            filter_.target = 20.0 * std::pow(1000.0, amount_);
            filter_.q = 0.9;
            break;
        case PS_INSERT_DRIVE: drive_.setType(1 + static_cast<int>(amount_ * 3.99f)); break;
        case PS_INSERT_CRUSH:
            crush_.bits = 16 - amount_ * 12;
            crush_.downsample = 1 + amount_ * 7;
            break;
        default: break;
        }
    }

    void process(float *L, float *R, float *outL, float *outR, int n, double smoothK) {
        switch (insert_) {
        case PS_INSERT_LOWPASS:
        case PS_INSERT_HIGHPASS: filter_.process(L, R, n); break;
        case PS_INSERT_DRIVE: drive_.process(L, R, n); break;
        case PS_INSERT_CRUSH: crush_.process(L, R, n); break;
        default: break;
        }
        const double angle = (pan_ + 1.0) * 0.25 * kPi;
        const double pl = std::cos(angle) * 1.41421356, pr = std::sin(angle) * 1.41421356;
        for (int i = 0; i < n; ++i) {
            level_ += (levelT_ - level_) * smoothK;
            outL[i] += static_cast<float>(L[i] * level_ * pl);
            outR[i] += static_cast<float>(R[i] * level_ * pr);
        }
    }

private:
    double level_ = 1, levelT_ = 1;
    float pan_ = 0, amount_ = 0.5f;
    int insert_ = PS_INSERT_NONE;
    FilterFX filter_;
    Drive drive_;
    Crusher crush_;
};

/// A return: a fully wet effect fed by pad sends.
class Return {
public:
    explicit Return(double sr) : reverb_(sr), delay_(sr), chorus_(sr, kChorusTypes, 4) {}

    void set(int type, float level) {
        type_ = type;
        levelT_ = std::clamp(level, 0.0f, 1.5f);
        switch (type) {
        case PS_RETURN_ROOM: reverb_.setType(1); break;
        case PS_RETURN_HALL: reverb_.setType(2); break;
        case PS_RETURN_PLATE: reverb_.setType(3); break;
        case PS_RETURN_DELAY_8: delay_.setType(2); break;
        case PS_RETURN_DELAY_4: delay_.setType(1); break;
        case PS_RETURN_CHORUS: chorus_.setType(3); break;
        default: break;
        }
    }

    void setTempo(double bpm) { delay_.setTempo(bpm); }

    /// Adds the wet signal of `L/R` into out (L/R are used as scratch).
    void process(float *L, float *R, float *outL, float *outR, int n, double smoothK) {
        if (type_ == PS_RETURN_OFF) return;
        std::array<float, 64> dryL{}, dryR{};
        const int m = std::min(n, 64);
        std::copy_n(L, m, dryL.begin());
        std::copy_n(R, m, dryR.begin());
        double makeup = 1;
        switch (type_) {
        case PS_RETURN_ROOM:
        case PS_RETURN_HALL:
        case PS_RETURN_PLATE: reverb_.process(L, R, m); makeup = 2.5; break;
        case PS_RETURN_DELAY_8:
        case PS_RETURN_DELAY_4: delay_.process(L, R, m); makeup = 1 / 0.35; break;
        case PS_RETURN_CHORUS: chorus_.process(L, R, m); makeup = 1.5; break;
        default: break;
        }
        for (int i = 0; i < m; ++i) {
            level_ += (levelT_ - level_) * smoothK;
            outL[i] += static_cast<float>((L[i] - dryL[i]) * makeup * level_);
            outR[i] += static_cast<float>((R[i] - dryR[i]) * makeup * level_);
        }
    }

private:
    int type_ = PS_RETURN_OFF;
    double level_ = 1, levelT_ = 1;
    Reverb reverb_;
    Delay delay_;
    ModDelay chorus_;
};

/// XY performance effect on the master (SAMPLER_SPEC §8). x/y in 0…1.
class XYEffect {
public:
    explicit XYEffect(double sr) : sr_(sr) {
        filter_.sr = sr;
        echoL_.allocate(static_cast<size_t>(2.1 * sr));
        echoR_.allocate(static_cast<size_t>(2.1 * sr));
    }

    void set(int type, float x, float y, bool active) {
        if (type != type_) { echoL_.clear(); echoR_.clear(); }
        type_ = type;
        x_ = std::clamp(x, 0.0f, 1.0f);
        y_ = std::clamp(y, 0.0f, 1.0f);
        activeT_ = active ? 1.0 : 0.0;
    }

    void setTempo(double bpm) { bpm_ = bpm; }

    void process(float *L, float *R, int n) {
        if (type_ == PS_XY_OFF || (activeT_ == 0 && mix_ < 1e-4)) { mix_ = activeT_; return; }
        std::array<float, 64> dryL{}, dryR{};
        const int m = std::min(n, 64);
        std::copy_n(L, m, dryL.begin());
        std::copy_n(R, m, dryR.begin());
        switch (type_) {
        case PS_XY_FILTER: {
            // x: left half sweeps a low-pass down, right half a high-pass up. y: resonance.
            filter_.highpass = x_ > 0.5f;
            const double t = filter_.highpass ? (x_ - 0.5) * 2 : x_ * 2;
            filter_.target = filter_.highpass ? 20.0 * std::pow(250.0, t) : 200.0 * std::pow(100.0, t);
            filter_.q = 0.7 + y_ * 8;
            filter_.process(L, R, m);
            break;
        }
        case PS_XY_ECHO: {
            // x: echo time (1/16 … 1/2 note), y: feedback. Wet is added on top.
            static constexpr double divisions[5] = {0.25, 1.0 / 3, 0.5, 1, 2};
            const double beats = divisions[std::min(4, static_cast<int>(x_ * 5))];
            const double target = std::min(beats * 60 / bpm_ * sr_, 2.0 * sr_);
            for (int i = 0; i < m; ++i) {
                time_ += (target - time_) * 0.001;
                const float dl = echoL_.read(time_), dr = echoR_.read(time_);
                echoL_.push(static_cast<float>(L[i] * activeT_ + dl * (0.3 + 0.65 * y_)));
                echoR_.push(static_cast<float>(R[i] * activeT_ + dr * (0.3 + 0.65 * y_)));
                L[i] += dl;
                R[i] += dr;
            }
            break;
        }
        case PS_XY_CRUSH:
            crush_.bits = 16 - x_ * 13;
            crush_.downsample = 1 + y_ * 15;
            crush_.process(L, R, m);
            break;
        default: break;
        }
        // Crossfade with the dry signal as the touch starts and ends (no clicks).
        const double k = 1.0 - std::exp(-1.0 / (0.02 * sr_));
        for (int i = 0; i < m; ++i) {
            mix_ += (activeT_ - mix_) * k;
            if (type_ == PS_XY_ECHO) continue; // echo tails ring out on their own
            L[i] = static_cast<float>(dryL[i] + (L[i] - dryL[i]) * mix_);
            R[i] = static_cast<float>(dryR[i] + (R[i] - dryR[i]) * mix_);
        }
    }

private:
    double sr_, bpm_ = 120, time_ = 12000, mix_ = 0, activeT_ = 0;
    int type_ = PS_XY_OFF;
    float x_ = 0.5f, y_ = 0.5f;
    FilterFX filter_;
    Crusher crush_;
    DelayLine echoL_, echoR_;
};

} // namespace ps
