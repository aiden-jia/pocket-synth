// Synthesized drum machine for the synth panel's Drums and Beat modes.
// Eight voices (kick, snare, closed hat, tom, open hat, cowbell, clap, shaker) and seven
// kits of our own design; a kit only changes tuning, decays and character.
#pragma once

#include "DSPCommon.hpp"
#include "include/SynthDSP.h"

namespace ps {

enum DrumType : int { Kick = 0, Snare, ClosedHat, Tom, OpenHat, Cowbell, Clap, Shaker };

struct DrumKit {
    float kickHz, kickSweep, kickDecay, kickClick;
    float snareHz, snareNoise, snareDecay;
    float hatHz, hatDecay, openDecay;
    float tomHz, tomDecay;
    float bellHz, clapDecay, shakerDecay;
    float drive;      // 0 = clean
    float level;
};

// Kits 1–7: Classic, Tight, Boom, Lo-Fi, Metal, Soft, Big Room (our own designs).
inline const DrumKit kDrumKits[PS_DRUM_KITS] = {
    {52, 3.5f, 380, 0.5f, 185, 0.65f, 170, 1.00f, 45, 360, 140, 260, 560, 190, 70, 0.0f, 1.0f},
    {60, 2.5f, 220, 0.8f, 210, 0.55f, 110, 1.15f, 30, 230, 170, 180, 600, 140, 50, 0.2f, 1.0f},
    {44, 4.5f, 900, 0.3f, 170, 0.70f, 230, 0.90f, 55, 480, 110, 420, 520, 230, 80, 0.4f, 0.95f},
    {56, 3.0f, 300, 0.4f, 190, 0.80f, 150, 0.80f, 40, 300, 130, 220, 540, 170, 60, 1.2f, 0.9f},
    {58, 3.0f, 260, 0.9f, 230, 0.60f, 140, 1.40f, 60, 520, 180, 200, 720, 160, 90, 0.8f, 0.9f},
    {50, 2.0f, 320, 0.2f, 175, 0.45f, 160, 0.85f, 35, 280, 120, 280, 500, 210, 60, 0.0f, 0.9f},
    {48, 5.0f, 600, 0.6f, 200, 0.75f, 260, 1.05f, 50, 420, 120, 360, 580, 300, 80, 0.6f, 1.0f},
};

struct DrumVoice {
    bool active = false;
    float velocity = 0;
    double t = 0;                       // seconds since the hit
    double ph1 = 0, ph2 = 0;            // tone phases
    double env1 = 0, env2 = 0;          // tone / noise envelopes
    double c1 = 0, c2 = 0;              // decay coefficients
    double pitchEnv = 0, pitchCoef = 0;
    std::array<double, 6> mph{};        // metallic oscillator phases
    SVF filter;
    Noise noise;
};

class Drums {
public:
    explicit Drums(double sr) : sr_(sr) {
        for (int i = 0; i < PS_DRUM_VOICES; ++i) voices_[i].noise = Noise(0x1234567u * (i + 3));
    }

    void setKit(int kit) { kit_ = std::clamp(kit, 0, PS_DRUM_KITS - 1); }
    int kit() const { return kit_; }

    void trigger(int type, int velocity) {
        if (type < 0 || type >= PS_DRUM_VOICES) return;
        if (type == ClosedHat) voices_[OpenHat].c2 = expCoef(4, sr_); // closed hat chokes the open hat
        const DrumKit &k = kDrumKits[kit_];
        DrumVoice &v = voices_[type];
        v.active = true;
        v.velocity = std::clamp(velocity, 1, 127) / 127.0f;
        v.t = 0;
        v.ph1 = v.ph2 = 0;
        v.filter.reset();
        switch (type) {
        case Kick:
            v.env1 = 1; v.c1 = expCoef(k.kickDecay, sr_);
            v.env2 = k.kickClick; v.c2 = expCoef(6, sr_);
            v.pitchEnv = 1; v.pitchCoef = expCoef(45, sr_);
            break;
        case Snare:
            v.env1 = 1 - k.snareNoise * 0.5; v.c1 = expCoef(k.snareDecay * 0.6, sr_);
            v.env2 = k.snareNoise; v.c2 = expCoef(k.snareDecay, sr_);
            v.pitchEnv = 1; v.pitchCoef = expCoef(20, sr_);
            break;
        case ClosedHat:
            v.env2 = 1; v.c2 = expCoef(k.hatDecay, sr_);
            break;
        case OpenHat:
            v.env2 = 1; v.c2 = expCoef(k.openDecay, sr_);
            break;
        case Tom:
            v.env1 = 1; v.c1 = expCoef(k.tomDecay, sr_);
            v.env2 = 0.15; v.c2 = expCoef(30, sr_);
            v.pitchEnv = 1; v.pitchCoef = expCoef(120, sr_);
            break;
        case Cowbell:
            v.env1 = 1; v.c1 = expCoef(260, sr_);
            break;
        case Clap:
            v.env2 = 1; v.c2 = expCoef(k.clapDecay, sr_);
            break;
        case Shaker:
            v.env2 = 0; v.c2 = expCoef(k.shakerDecay, sr_);
            break;
        default: break;
        }
    }

    void stopAll() { for (auto &v : voices_) v.active = false; }

    int activeVoices() const {
        int n = 0;
        for (auto &v : voices_) n += v.active;
        return n;
    }

    /// Adds the drums (mono, centred) into L/R.
    void render(float *L, float *R, int frames) {
        const DrumKit &k = kDrumKits[kit_];
        const double dt = 1.0 / sr_;
        for (int type = 0; type < PS_DRUM_VOICES; ++type) {
            DrumVoice &v = voices_[type];
            if (!v.active) continue;
            for (int i = 0; i < frames; ++i) {
                const double s = sample(type, v, k) * v.velocity * k.level;
                const double out = k.drive > 0 ? std::tanh(s * (1 + 2 * k.drive)) / (1 + 0.5 * k.drive) : s;
                L[i] += static_cast<float>(out * 0.5);
                R[i] += static_cast<float>(out * 0.5);
                v.t += dt;
            }
            if (v.env1 < 1e-4 && v.env2 < 1e-4 && v.t > 0.02) v.active = false;
        }
    }

private:
    double sample(int type, DrumVoice &v, const DrumKit &k) {
        switch (type) {
        case Kick: {
            const double hz = k.kickHz * (1.0 + k.kickSweep * v.pitchEnv);
            v.ph1 += hz / sr_;
            const double body = std::sin(kTwoPi * v.ph1) * v.env1;
            const double click = v.noise.white() * v.env2;
            v.env1 *= v.c1; v.env2 *= v.c2; v.pitchEnv *= v.pitchCoef;
            return 1.1 * body + 0.4 * click;
        }
        case Snare: {
            const double hz = k.snareHz * (1.0 + 0.4 * v.pitchEnv);
            v.ph1 += hz / sr_;
            v.ph2 += hz * 1.78 / sr_;
            const double tone = (std::sin(kTwoPi * v.ph1) + 0.5 * std::sin(kTwoPi * v.ph2)) * v.env1;
            v.filter.process(v.noise.white(), SVF::gFor(4200, sr_), 0.9);
            const double n = (v.filter.hp + v.filter.bp) * v.env2;
            v.env1 *= v.c1; v.env2 *= v.c2; v.pitchEnv *= v.pitchCoef;
            return 0.6 * tone + 0.7 * n;
        }
        case ClosedHat:
        case OpenHat: {
            const double m = metallic(v, 40.0 * k.hatHz);
            v.filter.process(m, SVF::gFor(7500, sr_), 0.8);
            const double out = v.filter.hp * v.env2;
            v.env2 *= v.c2;
            return 0.55 * out;
        }
        case Tom: {
            const double hz = k.tomHz * (1.0 + 0.6 * v.pitchEnv);
            v.ph1 += hz / sr_;
            const double out = std::sin(kTwoPi * v.ph1) * v.env1 + v.noise.white() * v.env2;
            v.env1 *= v.c1; v.env2 *= v.c2; v.pitchEnv *= v.pitchCoef;
            return 0.9 * out;
        }
        case Cowbell: {
            v.ph1 += k.bellHz / sr_;
            v.ph2 += k.bellHz * 1.48 / sr_;
            const double sq = (v.ph1 - std::floor(v.ph1) < 0.5 ? 1 : -1) + (v.ph2 - std::floor(v.ph2) < 0.5 ? 1 : -1);
            v.filter.process(sq, SVF::gFor(2600, sr_), 0.6);
            const double fast = std::exp(-v.t / 0.012);
            const double out = v.filter.bp * (0.6 * fast + 0.4 * v.env1);
            v.env1 *= v.c1;
            return 0.5 * out;
        }
        case Clap: {
            // Three quick bursts, then the tail.
            const double burst = v.t < 0.03 ? std::exp(-std::fmod(v.t, 0.01) / 0.0025) : 0.0;
            v.filter.process(v.noise.white(), SVF::gFor(1150, sr_), 0.7);
            const double env = std::max(burst, v.t >= 0.02 ? v.env2 : 0.0);
            if (v.t >= 0.02) v.env2 *= v.c2;
            return 1.2 * v.filter.bp * env;
        }
        case Shaker: {
            const double attack = std::min(1.0, v.t / 0.006);
            if (v.t < 0.006) v.env2 = attack; else v.env2 *= v.c2;
            v.filter.process(v.noise.white(), SVF::gFor(6500, sr_), 1.0);
            return 0.35 * v.filter.hp * v.env2;
        }
        default:
            return 0;
        }
    }

    /// Six detuned square waves at inharmonic ratios (classic hat cluster).
    double metallic(DrumVoice &v, double base) {
        static constexpr double ratios[6] = {2.0, 3.0, 4.16, 5.43, 6.79, 8.21};
        double sum = 0;
        for (int i = 0; i < 6; ++i) {
            v.mph[i] += base * ratios[i] / sr_;
            v.mph[i] -= std::floor(v.mph[i]);
            sum += v.mph[i] < 0.5 ? 1.0 : -1.0;
        }
        return sum / 6.0;
    }

    double sr_;
    int kit_ = 0;
    std::array<DrumVoice, PS_DRUM_VOICES> voices_{};
};

} // namespace ps
