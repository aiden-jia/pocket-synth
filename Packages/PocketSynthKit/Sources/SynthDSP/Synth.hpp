// Synth instrument: 32 voices, each a main (left) + detuned partner (right) generator.
// Engines: analog (2 oscillators), 2-op FM, noise, hybrid (analog + noise), sample (one
// pitched one-shot sample, e.g. a Mic-mode take).
#pragma once

#include "DSPCommon.hpp"
#include "Sampler.hpp"
#include "include/SynthDSP.h"

namespace ps {

inline double polyBlep(double t, double dt) {
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0;
    }
    if (t > 1.0 - dt) {
        t = (t - 1.0) / dt;
        return t * t + t + t + 1.0;
    }
    return 0.0;
}

inline double oscillator(int wave, double phase, double dt) {
    switch (wave) {
    case PS_WAVE_SQUARE: {
        double v = phase < 0.5 ? 1.0 : -1.0;
        v += polyBlep(phase, dt);
        v -= polyBlep(std::fmod(phase + 0.5, 1.0), dt);
        return v;
    }
    case PS_WAVE_TRIANGLE:
        return 1.0 - 4.0 * std::fabs(phase - 0.5);
    case PS_WAVE_SINE:
        return std::sin(kTwoPi * phase);
    case PS_WAVE_SAW:
    default:
        return 2.0 * phase - 1.0 - polyBlep(phase, dt);
    }
}

inline PSPatch defaultPatch(int wave = PS_WAVE_SAW) {
    PSPatch p{};
    p.engine = PS_ENGINE_ANALOG;
    p.wave1 = wave;
    p.wave2 = wave;
    p.noiseQ = 4;
    p.gain = 1;
    return p;
}

/// The sample engine's source: a sample and the pitch it has at its own speed.
struct SampleSource {
    const PSSample *sample = nullptr;
    double rootHz = 261.63;
};

/// Per-channel generator state (the voice has one for L and one for R).
struct Generator {
    double p1 = 0, p2 = 0, pm = 0; // osc1, osc2, FM modulator phases
    double fb = 0;                 // FM feedback memory
    double sp = 0;                 // sample read position (frames)
    bool done = false;             // the sample engine reached the end
    int channel = 0;               // which sample channel this side reads
    std::array<double, 6> metal{}; // metallic-noise square phases
    SVF tone, noiseFilter;
    Noise noise;

    void reset(double offset, uint32_t seed) {
        p1 = offset;
        p2 = std::fmod(offset + 0.37, 1.0);
        pm = 0;
        fb = 0;
        sp = 0;
        done = false;
        metal.fill(offset);
        tone.reset();
        noiseFilter.reset();
        noise = Noise(seed);
    }

    double noiseSample(const PSPatch &p, double hz, double sr) {
        switch (p.noiseKind) {
        case PS_NOISE_PINK:
            return noise.pink();
        case PS_NOISE_RESONANT: {
            const double fc = p.noiseCutoffHz > 0 ? p.noiseCutoffHz : hz;
            noiseFilter.process(noise.white(), SVF::gFor(fc, sr), 1.0 / std::max(0.5f, p.noiseQ));
            return noiseFilter.bp * 2.0;
        }
        case PS_NOISE_METALLIC: {
            static constexpr double ratios[6] = {1.0, 1.342, 1.2312, 1.6532, 1.9523, 2.1523};
            double s = 0;
            for (int i = 0; i < 6; ++i) {
                metal[i] += hz * 2.0 * ratios[i] / sr;
                metal[i] -= std::floor(metal[i]);
                s += metal[i] < 0.5 ? 1.0 : -1.0;
            }
            return s / 6.0;
        }
        case PS_NOISE_WHITE:
        default:
            return noise.white();
        }
    }

    double next(const PSPatch &p, double hz, double sr, double fmIndexScale, const SampleSource &src) {
        const double dt = hz / sr;
        double s = 0;
        switch (p.engine) {
        case PS_ENGINE_SAMPLE: {
            const PSSample *smp = src.sample;
            if (!smp || done || smp->frames < 2) { done = true; return 0; }
            const int i0 = static_cast<int>(sp);
            if (i0 >= smp->frames - 1) { done = true; return 0; }
            const float *x = smp->channel[std::min(channel, smp->channels - 1)].data();
            const double f = sp - i0;
            s = x[i0] + (x[i0 + 1] - x[i0]) * f;
            sp += hz / src.rootHz * smp->sampleRate / sr;
            break;
        }
        case PS_ENGINE_FM: {
            const double mod = std::sin(kTwoPi * pm + p.fmFeedback * 2.0 * fb);
            fb = mod;
            pm += dt * p.fmRatio;
            pm -= std::floor(pm);
            s = std::sin(kTwoPi * p1 + p.fmIndex * fmIndexScale * mod);
            p1 += dt;
            p1 -= std::floor(p1);
            break;
        }
        case PS_ENGINE_NOISE:
            s = noiseSample(p, hz, sr);
            break;
        case PS_ENGINE_ANALOG:
        case PS_ENGINE_HYBRID:
        default: {
            const double o1 = oscillator(p.wave1, p1, dt);
            p1 += dt;
            p1 -= std::floor(p1);
            s = o1;
            if (p.mix2 > 0) {
                const double dt2 = dt * std::pow(2.0, p.detune2 / 12.0);
                const double o2 = oscillator(p.wave2, p2, dt2);
                p2 += dt2;
                p2 -= std::floor(p2);
                s = o1 * (1.0 - p.mix2) + o2 * p.mix2;
            }
            if (p.engine == PS_ENGINE_HYBRID && p.noiseLevel > 0)
                s += p.noiseLevel * noiseSample(p, hz, sr);
            break;
        }
        }
        if (p.toneCutoffHz > 0) {
            tone.process(s, SVF::gFor(p.toneCutoffHz, sr), 1.0 / 0.707);
            s = tone.lp;
        }
        return s;
    }
};

struct SynthVoice {
    enum Stage : uint8_t { Off, Attack, Decay, Sustain, Release } stage = Off;
    int note = -1;
    bool bass = false;
    float velocity = 0;
    double env = 0;
    double pitch = 0;        // current (gliding) pitch in semitones
    double fmEnv = 1;        // FM index envelope
    uint64_t startedAt = 0;
    uint64_t endedAt = 0;
    Generator gen[2];
};

class Synth {
public:
    static constexpr int kVoices = 32;

    explicit Synth(double sr) : sr_(sr) {
        patch_ = defaultPatch();
        updateEnvelope();
    }

    // Parameters ---------------------------------------------------------------
    void setPatch(const PSPatch &p) { patch_ = p; updateFMDecay(); }
    void setWaveform(int w) { setPatch(defaultPatch(w)); }
    void setEnvelope(double a, double d, double s, double r) {
        attackMs_ = a; decayMs_ = d; sustain_ = s; releaseMs_ = r;
        updateEnvelope();
    }
    void setAttack(double v) { attackMs_ = v; updateEnvelope(); }
    void setDecay(double v) { decayMs_ = v; updateEnvelope(); }
    void setSustain(double v) { sustain_ = v; }
    void setRelease(double v) { releaseMs_ = v; updateEnvelope(); }
    void setStereo(bool on) { stereo_ = on; }
    void setGlideMs(double ms) { glideMs_ = ms; }
    void setVibratoCents(double c) { vibratoCents_ = c; }
    /// The sample engine's sample (nullptr = silent). Voices reading the old one stop.
    void setSample(const PSSample *s, double rootNote) {
        if (s != source_.sample)
            for (auto &v : voices_)
                if (patch_.engine == PS_ENGINE_SAMPLE) { v.stage = SynthVoice::Off; v.note = -1; }
        source_.sample = s;
        source_.rootHz = noteToHz(rootNote);
    }
    /// Drops a sample that is about to be freed.
    void forget(const PSSample *s) { if (source_.sample == s) setSample(nullptr, 60); }

    // Notes --------------------------------------------------------------------
    /// Called for every note on/off (note -1 = all off), e.g. to send MIDI.
    struct NoteHook {
        void *context = nullptr;
        void (*fn)(void *, int note, float velocity, bool on) = nullptr;
    };
    void setNoteHook(NoteHook h) { hook_ = h; }

    void noteOn(int note, float velocity, bool bass) {
        if (hook_.fn) hook_.fn(hook_.context, note, velocity, true);
        SynthVoice *target = nullptr;
        for (auto &v : voices_)
            if (v.stage != SynthVoice::Off && v.note == note && v.stage != SynthVoice::Release) target = &v;
        if (!target)
            for (auto &v : voices_)
                if (v.stage == SynthVoice::Off) { target = &v; break; }
        if (!target) target = &steal();

        const double fromPitch = glideSource(note);
        SynthVoice &v = *target;
        const bool fresh = v.stage == SynthVoice::Off || v.note != note;
        if (fresh) {
            const uint32_t seed = static_cast<uint32_t>(clock_ * 2654435761u + note);
            v.gen[0].reset(0.0, seed);
            v.gen[1].reset(0.25, seed ^ 0xA5A5A5A5u); // offset partner so the pair isn't phase-locked
            v.gen[1].channel = 1;
            v.env = 0;
        }
        v.note = note;
        v.bass = bass;
        v.velocity = std::clamp(velocity, 0.0f, 1.0f);
        v.stage = SynthVoice::Attack;
        v.startedAt = clock_;
        v.fmEnv = 1.0;
        v.pitch = (glideMs_ > 0 && fromPitch >= 0) ? fromPitch : note;
    }

    void noteOff(int note) {
        if (hook_.fn) hook_.fn(hook_.context, note, 0, false);
        for (auto &v : voices_)
            if (v.note == note && v.stage != SynthVoice::Off && v.stage != SynthVoice::Release) {
                v.stage = SynthVoice::Release;
                v.endedAt = clock_;
            }
    }

    void allOff() {
        if (hook_.fn) hook_.fn(hook_.context, -1, 0, false);
        for (auto &v : voices_)
            if (v.stage != SynthVoice::Off) { v.stage = SynthVoice::Release; v.endedAt = clock_; }
    }

    int activeVoices() const {
        int n = 0;
        for (auto &v : voices_) n += v.stage != SynthVoice::Off;
        return n;
    }

    /// Adds chord voices into (chordL, chordR) and bass voices into (bassL, bassR).
    void render(float *chordL, float *chordR, float *bassL, float *bassR, int frames) {
        const double glideCoef = glideMs_ > 0 ? 1.0 - std::exp(-1.0 / (glideMs_ * 0.001 * sr_ / 3.0)) : 1.0;
        const double vibInc = 5.5 / sr_;
        const double octave = 12.0 * patch_.octave;
        const double gainBase = 0.12 * (patch_.gain > 0 ? patch_.gain : 1.0);

        for (int i = 0; i < frames; ++i) {
            vibPhase_ += vibInc;
            vibPhase_ -= std::floor(vibPhase_);
            const double vib = vibratoCents_ > 0 ? vibratoCents_ / 100.0 * std::sin(kTwoPi * vibPhase_) : 0.0;

            for (auto &v : voices_) {
                if (v.stage == SynthVoice::Off) continue;
                if (!advanceEnvelope(v)) continue;

                v.pitch += (v.note - v.pitch) * glideCoef;
                const double pitch = v.pitch + octave + (v.bass ? 0.0 : vib);
                const double hzL = noteToHz(pitch);
                const double hzR = noteToHz(pitch + detuneCents_ / 100.0);
                const double fmScale = patch_.fmIndexSustain + (1.0 - patch_.fmIndexSustain) * v.fmEnv;
                v.fmEnv *= fmDecayCoef_;

                const double a = v.gen[0].next(patch_, hzL, sr_, fmScale, source_);
                const double b = v.gen[1].next(patch_, hzR, sr_, fmScale, source_);
                if (v.gen[0].done && v.gen[1].done) { v.stage = SynthVoice::Off; v.note = -1; continue; }
                const double g = gainBase * v.velocity * v.env;
                float *outL = v.bass ? bassL : chordL;
                float *outR = v.bass ? bassR : chordR;
                if (stereo_) {
                    outL[i] += static_cast<float>(a * g);
                    outR[i] += static_cast<float>(b * g);
                } else {
                    const float m = static_cast<float>(0.5 * (a + b) * g);
                    outL[i] += m;
                    outR[i] += m;
                }
            }
            ++clock_;
        }
    }

private:
    bool advanceEnvelope(SynthVoice &v) {
        switch (v.stage) {
        case SynthVoice::Attack:
            v.env += attackInc_;
            if (v.env >= 1.0) { v.env = 1.0; v.stage = SynthVoice::Decay; }
            break;
        case SynthVoice::Decay:
            v.env = sustain_ + (v.env - sustain_) * decayCoef_;
            if (std::fabs(v.env - sustain_) < 1e-4) { v.env = sustain_; v.stage = SynthVoice::Sustain; }
            break;
        case SynthVoice::Sustain:
            v.env = sustain_;
            if (sustain_ <= 0) { v.stage = SynthVoice::Off; v.note = -1; return false; }
            break;
        case SynthVoice::Release:
            v.env *= releaseCoef_;
            if (v.env < 1e-4) { v.stage = SynthVoice::Off; v.note = -1; return false; }
            break;
        case SynthVoice::Off:
            return false;
        }
        return true;
    }

    SynthVoice &steal() {
        SynthVoice *oldest = nullptr;
        for (auto &v : voices_) {
            const bool rel = v.stage == SynthVoice::Release;
            const bool better = !oldest || (rel && oldest->stage != SynthVoice::Release)
                || (rel == (oldest->stage == SynthVoice::Release) && v.startedAt < oldest->startedAt);
            if (better) oldest = &v;
        }
        return *oldest;
    }

    /// Glide starts from the nearest pitch that is sounding or released in the last 0.5 s.
    double glideSource(int note) const {
        if (glideMs_ <= 0) return -1;
        double best = -1, bestDist = 1e9;
        const uint64_t window = static_cast<uint64_t>(0.5 * sr_);
        for (auto &v : voices_) {
            const bool recent = v.stage != SynthVoice::Off
                && (v.stage != SynthVoice::Release || clock_ - v.endedAt < window);
            if (!recent || v.note == note) continue;
            const double d = std::fabs(v.pitch - note);
            if (d < bestDist) { bestDist = d; best = v.pitch; }
        }
        return best;
    }

    void updateEnvelope() {
        const double ms = 0.001 * sr_;
        attackInc_ = 1.0 / std::max(1.0, attackMs_ * ms);
        decayCoef_ = expCoef(decayMs_, sr_);
        releaseCoef_ = expCoef(releaseMs_, sr_);
    }

    void updateFMDecay() {
        fmDecayCoef_ = patch_.fmIndexDecayMs > 0 ? expCoef(patch_.fmIndexDecayMs, sr_) : 1.0;
    }

    double sr_;
    NoteHook hook_;
    std::array<SynthVoice, kVoices> voices_{};
    PSPatch patch_{};
    SampleSource source_;
    uint64_t clock_ = 0;
    double attackMs_ = 100, decayMs_ = 100, sustain_ = 1.0, releaseMs_ = 1000;
    double attackInc_ = 0, decayCoef_ = 0, releaseCoef_ = 0, fmDecayCoef_ = 1;
    bool stereo_ = true;
    double detuneCents_ = 7.0;
    double glideMs_ = 0, vibratoCents_ = 0, vibPhase_ = 0;
};

} // namespace ps
