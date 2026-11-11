// Sampler instrument: 128 pads (8 banks × 16), up to 4 velocity layers per pad,
// one-shot / note-on triggering, mono / poly, mute-group choke, AHDSR, trim, reverse.
#pragma once

#include "DSPCommon.hpp"
#include "include/SynthDSP.h"

struct PSSample {
    std::vector<float> channel[2];
    int frames = 0;
    int channels = 1;
    double sampleRate = 48000;
};

namespace ps {

struct SamplerVoice {
    enum Stage : uint8_t { Off, Attack, Hold, Decay, Sustain, Release } stage = Off;
    int pad = -1;
    int kg = -1;             // keygroup program, or -1 for a pad voice
    int note = -1;           // keygroup note
    PSLayer layer{};
    bool oneShot = true;
    int muteGroup = 0;
    double pos = 0;          // frames played from the layer start
    double rate = 1;         // source frames per output frame
    double env = 0;
    double holdLeft = 0;
    double fade = 1;         // choke fade-out multiplier
    bool choking = false;
    float gainL = 0, gainR = 0;
    uint64_t startedAt = 0;
};

class Sampler {
public:
    static constexpr int kVoices = 64;
    static constexpr int kPreviewPad = PS_SAMPLER_PADS;
    /// Audio-track regions play on hidden pads after the preview pad.
    static constexpr int kAudioBase = PS_SAMPLER_PADS + 1;
    static constexpr int kPadSlots = kAudioBase + PS_AUDIO_SLOTS;

    explicit Sampler(double sr) : sr_(sr) {
        for (auto &p : pads_) p = PSPadParams{};
        chokeStep_ = 1.0 / (0.002 * sr); // 2 ms choke
    }

    void setPad(int pad, const PSPadParams &p) {
        if (pad >= 0 && pad < kPadSlots) pads_[pad] = p;
    }

    void trigger(int pad, int velocity, float tune = 0) {
        if (pad < 0 || pad >= kPadSlots) return;
        const PSPadParams &p = pads_[pad];
        velocity = std::clamp(velocity, 1, 127);

        // Choke: same mute group on other pads; mono: this pad's own voices.
        for (auto &v : voices_) {
            if (v.stage == SamplerVoice::Off) continue;
            const bool group = p.muteGroup > 0 && v.muteGroup == p.muteGroup && v.pad != pad;
            const bool mono = p.mono && v.pad == pad;
            if (group || mono) v.choking = true;
        }

        const int count = std::clamp(p.layerCount, 0, PS_MAX_LAYERS);
        for (int i = 0; i < count; ++i) {
            const PSLayer &L = p.layers[i];
            if (!L.sample || velocity < L.velocityLow || velocity > L.velocityHigh) continue;
            const int start = std::clamp(L.start, 0, L.sample->frames);
            const int end = std::clamp(L.end <= 0 ? L.sample->frames : L.end, start, L.sample->frames);
            if (end - start < 2) continue;

            SamplerVoice &v = allocate();
            v = SamplerVoice{};
            v.stage = SamplerVoice::Attack;
            v.pad = pad;
            v.layer = L;
            v.layer.start = start;
            v.layer.end = end;
            v.oneShot = p.oneShot != 0;
            v.muteGroup = p.muteGroup;
            v.rate = L.sample->sampleRate / sr_ * std::pow(2.0, (L.tuneSemitones + tune) / 12.0);
            v.holdLeft = p.holdMs * 0.001 * sr_;
            v.startedAt = clock_;
            const double vel = velocity / 127.0;
            const double gain = vel * L.level * p.level;
            const double pan = std::clamp(static_cast<double>(L.pan + p.pan), -1.0, 1.0);
            const double angle = (pan + 1.0) * 0.25 * kPi; // equal-power
            v.gainL = static_cast<float>(gain * std::cos(angle) * 1.41421356);
            v.gainR = static_cast<float>(gain * std::sin(angle) * 1.41421356);
            if (p.attackMs <= 0.05f) { v.env = 1; v.stage = SamplerVoice::Hold; }
        }
    }

    void release(int pad) {
        for (auto &v : voices_)
            if (v.kg < 0 && v.pad == pad && !v.oneShot && v.stage != SamplerVoice::Off) v.stage = SamplerVoice::Release;
    }

    // Keygroups ----------------------------------------------------------------------

    struct KeygroupProgram {
        std::array<PSKeygroupZone, PS_KEYGROUP_ZONES> zones{};
        int count = 0;
        PSPadParams common{};
    };

    void setKeygroupProgram(int prog, int count, const PSPadParams &common) {
        if (prog < 0 || prog >= PS_KEYGROUP_PROGRAMS) return;
        keygroups_[prog].count = std::clamp(count, 0, PS_KEYGROUP_ZONES);
        keygroups_[prog].common = common;
    }

    void setKeygroupZone(int prog, int zone, const PSKeygroupZone &z) {
        if (prog < 0 || prog >= PS_KEYGROUP_PROGRAMS || zone < 0 || zone >= PS_KEYGROUP_ZONES) return;
        keygroups_[prog].zones[zone] = z;
    }

    /// Plays `note` on a keygroup program: the first zone that covers it, every layer in
    /// the velocity range, pitched from the zone's root. Gated: noteOff releases it.
    void noteOn(int prog, int note, int velocity, float tune = 0) {
        if (prog < 0 || prog >= PS_KEYGROUP_PROGRAMS) return;
        const KeygroupProgram &k = keygroups_[prog];
        velocity = std::clamp(velocity, 1, 127);
        const PSKeygroupZone *zone = nullptr;
        for (int i = 0; i < k.count; ++i)
            if (note >= k.zones[i].lowNote && note <= k.zones[i].highNote) { zone = &k.zones[i]; break; }
        if (!zone) return;
        for (auto &v : voices_) {
            if (v.stage == SamplerVoice::Off || v.kg != prog) continue;
            if (k.common.mono || v.note == note) v.choking = true; // retrigger / mono
        }
        const int count = std::clamp(zone->layerCount, 0, PS_MAX_LAYERS);
        for (int i = 0; i < count; ++i) {
            const PSLayer &L = zone->layers[i];
            if (!L.sample || velocity < L.velocityLow || velocity > L.velocityHigh) continue;
            const int start = std::clamp(L.start, 0, L.sample->frames);
            const int end = std::clamp(L.end <= 0 ? L.sample->frames : L.end, start, L.sample->frames);
            if (end - start < 2) continue;
            SamplerVoice &v = allocate();
            v = SamplerVoice{};
            v.stage = SamplerVoice::Attack;
            v.kg = prog;
            v.note = note;
            v.layer = L;
            v.layer.start = start;
            v.layer.end = end;
            v.oneShot = k.common.oneShot != 0;
            v.rate = L.sample->sampleRate / sr_ * std::pow(2.0, (note - zone->rootNote + L.tuneSemitones + tune) / 12.0);
            v.holdLeft = k.common.holdMs * 0.001 * sr_;
            v.startedAt = clock_;
            const double gain = velocity / 127.0 * L.level * k.common.level;
            const double pan = std::clamp(static_cast<double>(L.pan + k.common.pan), -1.0, 1.0);
            const double angle = (pan + 1.0) * 0.25 * kPi;
            v.gainL = static_cast<float>(gain * std::cos(angle) * 1.41421356);
            v.gainR = static_cast<float>(gain * std::sin(angle) * 1.41421356);
            if (k.common.attackMs <= 0.05f) { v.env = 1; v.stage = SamplerVoice::Hold; }
        }
    }

    void noteOff(int prog, int note) {
        for (auto &v : voices_)
            if (v.kg == prog && v.note == note && !v.oneShot && v.stage != SamplerVoice::Off)
                v.stage = SamplerVoice::Release;
    }

    void stopAll() {
        for (auto &v : voices_)
            if (v.stage != SamplerVoice::Off) v.choking = true;
    }

    /// Drops every reference to `s` (pads and voices) before it is freed.
    void forget(const PSSample *s) {
        for (auto &v : voices_)
            if (v.layer.sample == s) { v.stage = SamplerVoice::Off; v.pad = -1; v.kg = -1; v.layer.sample = nullptr; }
        for (auto &p : pads_)
            for (auto &L : p.layers)
                if (L.sample == s) L.sample = nullptr;
        for (auto &k : keygroups_)
            for (auto &z : k.zones)
                for (auto &L : z.layers)
                    if (L.sample == s) L.sample = nullptr;
    }

    int activeVoices() const {
        int n = 0;
        for (auto &v : voices_) n += v.stage != SamplerVoice::Off;
        return n;
    }

    /// Adds every voice into its output bus (0 = main, 1…8 = submixes) and its sends.
    void render(float *const *busL, float *const *busR, float *const *retL, float *const *retR, int frames) {
        for (auto &v : voices_) {
            if (v.stage == SamplerVoice::Off) continue;
            const PSPadParams &p = v.kg >= 0 ? keygroups_[v.kg].common : pads_[v.pad];
            const double attackInc = 1.0 / std::max(1.0, p.attackMs * 0.001 * sr_);
            const double decayCoef = expCoef(std::max(0.1f, p.decayMs), sr_);
            const double releaseCoef = expCoef(std::max(0.1f, p.releaseMs), sr_);
            const double sustain = p.decayMs <= 0 ? 1.0 : std::clamp<double>(p.sustain, 0, 1);
            const PSSample &s = *v.layer.sample;
            const int len = v.layer.end - v.layer.start;
            const float *c0 = s.channel[0].data();
            const float *c1 = s.channels > 1 ? s.channel[1].data() : c0;
            const int out = std::clamp(p.output, 0, PS_SUBMIXES);
            float *L = busL[out], *R = busR[out];
            bool anySend = false;
            for (float sl : p.sends) anySend |= sl > 0;

            for (int i = 0; i < frames; ++i) {
                if (!envelope(v, attackInc, decayCoef, releaseCoef, sustain)) break;
                if (v.pos >= len - 1) { v.stage = SamplerVoice::Off; break; }
                double a, b;
                read(c0, c1, v, len, a, b);
                const double g = v.env * v.fade;
                const float sL = static_cast<float>(a * g * v.gainL), sR = static_cast<float>(b * g * v.gainR);
                L[i] += sL;
                R[i] += sR;
                if (anySend)
                    for (int k = 0; k < PS_RETURNS; ++k)
                        if (p.sends[k] > 0) { retL[k][i] += sL * p.sends[k]; retR[k][i] += sR * p.sends[k]; }
                v.pos += v.rate;
            }
            if (v.stage == SamplerVoice::Off) { v.pad = -1; v.kg = -1; }
        }
        clock_ += frames;
    }

private:
    bool envelope(SamplerVoice &v, double attackInc, double decayCoef, double releaseCoef, double sustain) {
        if (v.choking) {
            v.fade -= chokeStep_;
            if (v.fade <= 0) { v.stage = SamplerVoice::Off; return false; }
        }
        switch (v.stage) {
        case SamplerVoice::Attack:
            v.env += attackInc;
            if (v.env >= 1) { v.env = 1; v.stage = SamplerVoice::Hold; }
            break;
        case SamplerVoice::Hold:
            if (--v.holdLeft <= 0) v.stage = SamplerVoice::Decay;
            break;
        case SamplerVoice::Decay:
            v.env = sustain + (v.env - sustain) * decayCoef;
            if (std::fabs(v.env - sustain) < 1e-4) {
                v.env = sustain;
                v.stage = SamplerVoice::Sustain;
            }
            break;
        case SamplerVoice::Sustain:
            if (v.env <= 1e-4) { v.stage = SamplerVoice::Off; return false; }
            break;
        case SamplerVoice::Release:
            v.env *= releaseCoef;
            if (v.env < 1e-4) { v.stage = SamplerVoice::Off; return false; }
            break;
        case SamplerVoice::Off:
            return false;
        }
        return true;
    }

    /// Cubic Hermite read at the voice's position (handles reverse).
    static void read(const float *c0, const float *c1, const SamplerVoice &v, int len, double &a, double &b) {
        const int base = static_cast<int>(v.pos);
        const double f = v.pos - base;
        auto idx = [&](int k) {
            const int i = std::clamp(base + k, 0, len - 1);
            return v.layer.reverse ? v.layer.end - 1 - i : v.layer.start + i;
        };
        auto herm = [&](const float *c) {
            const double xm1 = c[idx(-1)], x0 = c[idx(0)], x1 = c[idx(1)], x2 = c[idx(2)];
            const double c1 = 0.5 * (x1 - xm1);
            const double c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
            const double c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
            return ((c3 * f + c2) * f + c1) * f + x0;
        };
        a = herm(c0);
        b = c1 == c0 ? a : herm(c1);
    }

    SamplerVoice &allocate() {
        SamplerVoice *oldest = nullptr;
        for (auto &v : voices_) {
            if (v.stage == SamplerVoice::Off) return v;
            if (!oldest || v.startedAt < oldest->startedAt) oldest = &v;
        }
        return *oldest;
    }

    double sr_;
    double chokeStep_;
    uint64_t clock_ = 0;
    std::array<PSPadParams, kPadSlots> pads_{}; // + the hidden preview and audio-track pads
    std::array<KeygroupProgram, PS_KEYGROUP_PROGRAMS> keygroups_{};
    std::array<SamplerVoice, kVoices> voices_{};
};

} // namespace ps
