// FX library v1. Each effect: allocate in the constructor (main thread), then
// setType()/process() on the audio thread. Type 0 = off (bypass). The option lists
// match SynthCore.FXKind.options.
#pragma once

#include "DSPCommon.hpp"

namespace ps {

/// Tempo-synced note lengths in beats for the "1/4 1/8 1/16 1/16T 1/32" option lists.
inline double syncedBeats(int type) {
    static constexpr double beats[6] = {0, 1.0, 0.5, 0.25, 1.0 / 6.0, 0.125};
    return beats[std::clamp(type, 0, 5)];
}

// MARK: - Delay (tempo-synced echo)

class Delay {
public:
    explicit Delay(double sr) : sr_(sr) {
        l_.allocate(static_cast<size_t>(2.6 * sr));
        r_.allocate(static_cast<size_t>(2.6 * sr));
        damp_[0].setHz(5000, sr);
        damp_[1].setHz(5000, sr);
    }
    void setType(int t) {
        if (t != 0 && type_ == 0) { l_.clear(); r_.clear(); }
        type_ = t;
    }
    void setTempo(double bpm) { bpm_ = bpm; }
    int type() const { return type_; }

    void process(float *L, float *R, int n) {
        if (type_ == 0) return;
        const double target = std::min(syncedBeats(type_) * 60.0 / bpm_ * sr_, 2.5 * sr_);
        const double slew = 1.0 - std::exp(-1.0 / (0.05 * sr_));
        for (int i = 0; i < n; ++i) {
            time_ += (target - time_) * slew;
            const float dl = l_.read(time_), dr = r_.read(time_);
            l_.push(static_cast<float>(L[i] + damp_[0].lowpass(dl) * feedback_));
            r_.push(static_cast<float>(R[i] + damp_[1].lowpass(dr) * feedback_));
            L[i] += dl * mix_;
            R[i] += dr * mix_;
        }
    }

private:
    double sr_, bpm_ = 120, time_ = 0.5 * 48000;
    int type_ = 0;
    float feedback_ = 0.38f, mix_ = 0.35f;
    DelayLine l_, r_;
    OnePole damp_[2];
};

// MARK: - Modulated delay (chorus / flanger)

class ModDelay {
public:
    struct Settings { double baseMs, depthMs, rateHz, feedback, mix; };

    ModDelay(double sr, const Settings *table, int count) : sr_(sr), table_(table), count_(count) {
        l_.allocate(static_cast<size_t>(0.06 * sr));
        r_.allocate(static_cast<size_t>(0.06 * sr));
    }
    void setType(int t) {
        if (t != 0 && type_ == 0) { l_.clear(); r_.clear(); }
        type_ = std::clamp(t, 0, count_);
    }
    int type() const { return type_; }

    void process(float *L, float *R, int n) {
        if (type_ == 0) return;
        const Settings &s = table_[type_ - 1];
        const double inc = s.rateHz / sr_;
        const double ms = 0.001 * sr_;
        for (int i = 0; i < n; ++i) {
            phase_ += inc;
            phase_ -= std::floor(phase_);
            const double mL = 0.5 + 0.5 * std::sin(kTwoPi * phase_);
            const double mR = 0.5 + 0.5 * std::sin(kTwoPi * (phase_ + 0.25)); // quadrature L/R
            const float wl = l_.read((s.baseMs + s.depthMs * mL) * ms);
            const float wr = r_.read((s.baseMs + s.depthMs * mR) * ms);
            l_.push(static_cast<float>(L[i] + wl * s.feedback));
            r_.push(static_cast<float>(R[i] + wr * s.feedback));
            L[i] = static_cast<float>(L[i] * (1 - 0.5 * s.mix) + wl * s.mix);
            R[i] = static_cast<float>(R[i] * (1 - 0.5 * s.mix) + wr * s.mix);
        }
    }

private:
    double sr_, phase_ = 0;
    const Settings *table_;
    int count_, type_ = 0;
    DelayLine l_, r_;
};

inline const ModDelay::Settings kChorusTypes[4] = {
    {12, 2.0, 0.35, 0.0, 0.35},  // LIGHT
    {18, 3.5, 0.25, 0.1, 0.45},  // WARM
    {22, 5.0, 0.45, 0.0, 0.55},  // WIDE
    {25, 7.0, 0.18, 0.2, 0.60},  // LUSH
};

inline const ModDelay::Settings kFlangerTypes[4] = {
    {1.5, 2.5, 0.08, 0.55, 0.5},   // SLOW
    {1.0, 4.0, 0.30, 0.75, 0.5},   // JET
    {2.0, 5.0, 0.12, 0.85, 0.55},  // DEEP
    {0.6, 1.5, 0.90, 0.88, 0.5},   // METAL
};

// MARK: - Tremolo (tempo-synced amplitude LFO)

class Tremolo {
public:
    explicit Tremolo(double sr) : sr_(sr) {}
    void setType(int t) { type_ = t; }
    void setTempo(double bpm) { bpm_ = bpm; }
    int type() const { return type_; }

    void process(float *L, float *R, int n) {
        if (type_ == 0) return;
        const double inc = bpm_ / 60.0 / syncedBeats(type_) / sr_;
        for (int i = 0; i < n; ++i) {
            phase_ += inc;
            phase_ -= std::floor(phase_);
            const float g = static_cast<float>(1.0 - depth_ * (0.5 - 0.5 * std::cos(kTwoPi * phase_)));
            L[i] *= g;
            R[i] *= g;
        }
    }

private:
    double sr_, bpm_ = 120, phase_ = 0;
    double depth_ = 0.7;
    int type_ = 0;
};

// MARK: - Drive (waveshapers)

class Drive {
public:
    explicit Drive(double sr) { post_[0].setHz(7000, sr); post_[1].setHz(7000, sr); }
    void setType(int t) { type_ = t; }
    int type() const { return type_; }

    void process(float *L, float *R, int n) {
        if (type_ == 0) return;
        for (int i = 0; i < n; ++i) {
            L[i] = static_cast<float>(post_[0].lowpass(shape(L[i])));
            R[i] = static_cast<float>(post_[1].lowpass(shape(R[i])));
        }
    }

private:
    double shape(double x) const {
        switch (type_) {
        case 1: { // TUBE: warm asymmetric soft clip
            const double y = std::tanh(2.0 * x + 0.15) - std::tanh(0.15);
            return y * 0.8;
        }
        case 2: return std::tanh(5.0 * x) * 0.6;                       // DRIVE
        case 3: return std::clamp(10.0 * x, -1.0, 1.0) * 0.45;          // DIST: hard clip
        case 4: {                                                       // FUZZ
            const double y = std::tanh(30.0 * x);
            return (y * y * y * 0.7 + y * 0.3) * 0.4;
        }
        default: return x;
        }
    }
    int type_ = 0;
    OnePole post_[2];
};

// MARK: - Tape (lo-fi, vinyl, tape)

class Tape {
public:
    explicit Tape(double sr) : sr_(sr) {
        l_.allocate(static_cast<size_t>(0.03 * sr));
        r_.allocate(static_cast<size_t>(0.03 * sr));
    }
    void setType(int t) {
        type_ = t;
        const double hz = t == 1 ? 5000 : t == 2 ? 9000 : 12000;
        lp_[0].setHz(hz, sr_);
        lp_[1].setHz(hz, sr_);
    }
    int type() const { return type_; }

    void process(float *L, float *R, int n) {
        if (type_ == 0) return;
        for (int i = 0; i < n; ++i) {
            double l = L[i], r = R[i];
            if (type_ == 1) { // LOFI: sample-rate hold + 10-bit quantize
                if (holdCount_++ % 4 == 0) { holdL_ = l; holdR_ = r; }
                l = std::round(holdL_ * 512.0) / 512.0;
                r = std::round(holdR_ * 512.0) / 512.0;
            } else {
                // Wow & flutter through a short modulated delay.
                wow_ += 0.6 / sr_; wow_ -= std::floor(wow_);
                flutter_ += 7.0 / sr_; flutter_ -= std::floor(flutter_);
                const double depth = type_ == 3 ? 1.0 : 0.4;
                const double d = (8.0 + depth * (1.2 * std::sin(kTwoPi * wow_) + 0.25 * std::sin(kTwoPi * flutter_))) * 0.001 * sr_;
                l_.push(static_cast<float>(l));
                r_.push(static_cast<float>(r));
                l = std::tanh(1.4 * l_.read(d)) / 1.1;
                r = std::tanh(1.4 * r_.read(d)) / 1.1;
                if (type_ == 2) { // VINYL: crackle + hiss
                    const float w = noise_.white();
                    const double crackle = std::fabs(w) > 0.9995f ? w * 0.4 : 0.0;
                    l += crackle + 0.004 * noise_.pink();
                    r += crackle + 0.004 * noise_.pink();
                }
            }
            L[i] = static_cast<float>(lp_[0].lowpass(l));
            R[i] = static_cast<float>(lp_[1].lowpass(r));
        }
    }

private:
    double sr_, wow_ = 0, flutter_ = 0, holdL_ = 0, holdR_ = 0;
    uint32_t holdCount_ = 0;
    int type_ = 0;
    DelayLine l_, r_;
    OnePole lp_[2];
    Noise noise_{12345};
};

// MARK: - Reverb (8-line feedback delay network)

class Reverb {
public:
    struct Settings { double size, rt60, dampHz, predelayMs, mix, modDepth; bool spring; };

    explicit Reverb(double sr) : sr_(sr) {
        for (auto &d : lines_) d.allocate(static_cast<size_t>(0.25 * sr));
        pre_.allocate(static_cast<size_t>(0.1 * sr));
        for (auto &a : springAP_) a.allocate(static_cast<size_t>(0.01 * sr));
        hp_.setHz(120, sr);
    }

    void setType(int t) {
        static const Settings table[6] = {
            {0.45, 0.6, 7000, 5, 0.22, 0.0, false},   // ROOM
            {1.00, 2.6, 6000, 22, 0.30, 0.2, false},  // HALL
            {0.65, 1.8, 10000, 2, 0.28, 0.0, false},  // PLATE
            {0.50, 1.4, 4000, 0, 0.30, 0.0, true},    // SPRING
            {1.30, 6.0, 5000, 35, 0.40, 0.6, false},  // AMBIENT
            {0.80, 1.5, 6500, 10, 0.25, 0.1, false},  // LEGACY
        };
        if (t != 0 && type_ == 0) clear();
        type_ = t;
        if (t == 0) return;
        s_ = table[std::clamp(t, 1, 6) - 1];
        static constexpr double baseMs[8] = {29.7, 37.1, 41.1, 43.7, 47.9, 53.3, 59.9, 67.1};
        for (int i = 0; i < 8; ++i) {
            len_[i] = baseMs[i] * s_.size * 0.001 * sr_;
            gain_[i] = std::pow(10.0, -3.0 * (len_[i] / sr_) / s_.rt60); // per-line RT60 gain
            damp_[i].setHz(s_.dampHz, sr_);
        }
    }
    int type() const { return type_; }

    void process(float *L, float *R, int n) {
        if (type_ == 0) return;
        const double preD = std::max(2.0, s_.predelayMs * 0.001 * sr_);
        for (int i = 0; i < n; ++i) {
            double x = hp_.highpass(0.5 * (L[i] + R[i]));
            pre_.push(static_cast<float>(x));
            x = pre_.read(preD);
            if (s_.spring) x = springDisperse(x);

            mod_ += 0.3 / sr_; mod_ -= std::floor(mod_);
            std::array<double, 8> o{};
            for (int k = 0; k < 8; ++k) {
                const double m = s_.modDepth * 8.0 * std::sin(kTwoPi * (mod_ + k * 0.125));
                o[k] = damp_[k].lowpass(lines_[k].read(len_[k] + m));
            }
            hadamard(o);
            for (int k = 0; k < 8; ++k)
                lines_[k].push(static_cast<float>(x * 0.5 + o[k] * gain_[k]));

            const double wetL = (o[0] + o[2] + o[4] + o[6]) * 0.35;
            const double wetR = (o[1] + o[3] + o[5] + o[7]) * 0.35;
            L[i] = static_cast<float>(L[i] + wetL * s_.mix);
            R[i] = static_cast<float>(R[i] + wetR * s_.mix);
        }
    }

private:
    static void hadamard(std::array<double, 8> &v) {
        for (int len = 1; len < 8; len <<= 1)
            for (int i = 0; i < 8; i += len << 1)
                for (int j = i; j < i + len; ++j) {
                    const double a = v[j], b = v[j + len];
                    v[j] = a + b;
                    v[j + len] = a - b;
                }
        for (auto &x : v) x *= 0.35355339059327373; // 1/sqrt(8)
    }

    /// Chain of short allpasses: the "boing" dispersion of a spring tank.
    double springDisperse(double x) {
        static constexpr double ms[6] = {1.1, 1.7, 2.3, 2.9, 3.7, 4.3};
        const double g = 0.62;
        for (int k = 0; k < 6; ++k) {
            const double d = springAP_[k].read(ms[k] * 0.001 * sr_);
            const double y = -g * x + d;
            springAP_[k].push(static_cast<float>(x + g * y));
            x = y;
        }
        return x;
    }

    void clear() {
        for (auto &d : lines_) d.clear();
        for (auto &a : springAP_) a.clear();
        pre_.clear();
    }

    double sr_, mod_ = 0;
    int type_ = 0;
    Settings s_{};
    std::array<DelayLine, 8> lines_;
    std::array<double, 8> len_{}, gain_{};
    std::array<OnePole, 8> damp_;
    std::array<DelayLine, 6> springAP_;
    DelayLine pre_;
    OnePole hp_;
};

// MARK: - Vocoder (12-band channel vocoder, SYNTH_SPEC §3.1)
//
// The synth (carrier) goes through 12 band-pass filters; each band's level follows the
// same band of the modulator (the mic, or the loops). A little of the modulator's top end
// is mixed back in so consonants stay intelligible.

class Vocoder {
public:
    static constexpr int kBands = 12;

    explicit Vocoder(double sr) : sr_(sr) {
        const double lo = 160, hi = 6400;
        for (int b = 0; b < kBands; ++b) {
            const double fc = lo * std::pow(hi / lo, b / double(kBands - 1));
            g_[b] = SVF::gFor(fc, sr);
        }
        attack_ = 1.0 - std::exp(-1.0 / (0.004 * sr));
        release_ = 1.0 - std::exp(-1.0 / (0.035 * sr));
        hiss_.setHz(5000, sr);
    }

    /// 0 = off, 1 = mic, 2 = loop (the caller picks the modulator).
    void setType(int t) {
        if (t != type_) reset();
        type_ = std::clamp(t, 0, 2);
    }
    int type() const { return type_; }

    /// Replaces L/R (the carrier) with the vocoded signal. `mod` is mono, n frames.
    void process(float *L, float *R, const float *mod, int n) {
        if (type_ == 0) return;
        constexpr double k = 1.0 / 5.0; // band Q 5
        for (int i = 0; i < n; ++i) {
            const double m = mod[i];
            double outL = 0, outR = 0;
            for (int b = 0; b < kBands; ++b) {
                modF_[b].process(m, g_[b], k);
                const double r = std::fabs(modF_[b].bp);
                env_[b] += (r - env_[b]) * (r > env_[b] ? attack_ : release_);
                carL_[b].process(L[i], g_[b], k);
                carR_[b].process(R[i], g_[b], k);
                outL += carL_[b].bp * env_[b];
                outR += carR_[b].bp * env_[b];
            }
            const double air = hiss_.highpass(m) * 0.25;
            L[i] = static_cast<float>(outL * kGain + air);
            R[i] = static_cast<float>(outR * kGain + air);
        }
    }

private:
    static constexpr double kGain = 8.0;

    void reset() {
        for (int b = 0; b < kBands; ++b) { modF_[b].reset(); carL_[b].reset(); carR_[b].reset(); env_[b] = 0; }
        hiss_.z = 0;
    }

    double sr_, attack_ = 0, release_ = 0;
    int type_ = 0;
    std::array<double, kBands> g_{}, env_{};
    std::array<SVF, kBands> modF_, carL_, carR_;
    OnePole hiss_;
};

// MARK: - Master low-pass (the synth's Filter row + wheel cutoff)

class LowPass {
public:
    explicit LowPass(double sr) : sr_(sr) {}
    void setEnabled(bool on) { enabled_ = on; }
    void setCutoff(double hz) { target_ = std::clamp(hz, 20.0, 20000.0); }

    void process(float *L, float *R, int n) {
        if (!enabled_) { cutoff_ = target_; return; }
        const double smooth = 1.0 - std::exp(-1.0 / (0.01 * sr_));
        for (int i = 0; i < n; ++i) {
            cutoff_ += (target_ - cutoff_) * smooth;
            const double g = SVF::gFor(cutoff_, sr_);
            l_.process(L[i], g, 1.0 / 0.707);
            r_.process(R[i], g, 1.0 / 0.707);
            L[i] = static_cast<float>(l_.lp);
            R[i] = static_cast<float>(r_.lp);
        }
    }

private:
    double sr_, target_ = 20000, cutoff_ = 20000;
    bool enabled_ = false;
    SVF l_, r_;
};

} // namespace ps
