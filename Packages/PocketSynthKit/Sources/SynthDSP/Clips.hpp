// Clip program (SAMPLER_SPEC §3.3): 16 clips that start and stop on a quantize grid.
// Loops are played over their length in beats, so they stay in time when the tempo
// changes (varispeed: the pitch follows the tempo).
#pragma once

#include "DSPCommon.hpp"
#include "Sampler.hpp"
#include "include/SynthDSP.h"

namespace ps {

class ClipPlayer {
public:
    explicit ClipPlayer(double sr) : sr_(sr) {
        fadeIn_ = 1.0 / (0.002 * sr);
        fadeOut_ = 1.0 / (0.006 * sr);
    }

    void set(int i, const PSClipParams &p) {
        if (i < 0 || i >= PS_CLIPS) return;
        Slot &s = slots_[i];
        if (s.p.sample != p.sample && s.state != PS_CLIP_STOPPED) halt(s);
        s.p = p;
        s.p.level = std::max(0.0f, p.level);
    }

    void setQuantize(double beats) { quantize_ = std::max(0.0, beats); }

    /// Starts (recorded = from a live pad) at the next grid point. Returns the beat.
    double launch(int i, double beat, bool transport, bool live) {
        Slot &s = slots_[i];
        if (!s.p.sample) return beat;
        const double at = launchBeat(beat, transport);
        s.startAt = at;
        s.stopAt = -1;
        s.liveStart = live;
        if (s.state == PS_CLIP_STOPPED) s.state = PS_CLIP_QUEUED;
        for (int j = 0; j < PS_CLIPS; ++j) {
            Slot &o = slots_[j];
            if (j == i || o.p.group != s.p.group) continue;
            if (o.state == PS_CLIP_PLAYING || o.state == PS_CLIP_STOPPING) { o.stopAt = at; o.state = PS_CLIP_STOPPING; o.liveStop = live; }
            else if (o.state == PS_CLIP_QUEUED) { o.state = PS_CLIP_STOPPED; o.startAt = -1; }
        }
        return at;
    }

    void stop(int i, double beat, bool transport, bool live, bool now) {
        Slot &s = slots_[i];
        if (s.state == PS_CLIP_QUEUED) { s.state = PS_CLIP_STOPPED; s.startAt = -1; return; }
        if (s.state != PS_CLIP_PLAYING && s.state != PS_CLIP_STOPPING) return;
        s.stopAt = now ? beat : launchBeat(beat, transport);
        s.state = PS_CLIP_STOPPING;
        s.liveStop = live;
    }

    /// A live pad: loop toggles, one-shot restarts, gate plays while held.
    void pad(int i, bool down, double beat, bool transport) {
        if (i < 0 || i >= PS_CLIPS) return;
        Slot &s = slots_[i];
        switch (s.p.mode) {
        case PS_CLIP_GATE:
            if (down) launch(i, beat, transport, true); else stop(i, beat, transport, true, true);
            break;
        case PS_CLIP_ONESHOT:
            if (down) launch(i, beat, transport, true);
            break;
        default:
            if (!down) break;
            if (s.state == PS_CLIP_QUEUED || (s.state == PS_CLIP_PLAYING && s.stopAt < 0)) stop(i, beat, transport, true, false);
            else launch(i, beat, transport, true);
            break;
        }
    }

    /// Sequence playback: start right now; `stop` ends it (one-shots run out by themselves).
    void sequenced(int i, bool start, double beat) {
        if (i < 0 || i >= PS_CLIPS || !slots_[i].p.sample) return;
        if (start) {
            const double q = quantize_;
            quantize_ = 0;
            launch(i, beat, true, false);
            quantize_ = q;
        } else if (slots_[i].p.mode != PS_CLIP_ONESHOT) {
            stop(i, beat, true, false, true);
        }
    }

    void stopAll() {
        for (auto &s : slots_) {
            if (s.state == PS_CLIP_QUEUED) { s.state = PS_CLIP_STOPPED; s.startAt = -1; }
            else if (s.state != PS_CLIP_STOPPED) { s.fadingOut = true; s.state = PS_CLIP_STOPPING; s.stopAt = -1; }
        }
    }

    void forget(const PSSample *smp) {
        for (auto &s : slots_)
            if (s.p.sample == smp) { s = Slot{}; }
    }

    int state(int i) const { return slots_[i].state; }

    /// Fires starts / stops due in [b0, b1) (calling stamp(clip, on) for live ones), then
    /// adds the playing clips into (L, R).
    template <typename Stamp>
    void process(double b0, double b1, double bpm, float *L, float *R, int n, Stamp &&stamp) {
        for (int i = 0; i < PS_CLIPS; ++i) {
            Slot &s = slots_[i];
            if (s.startAt >= 0 && s.startAt < b1) {
                if (s.state == PS_CLIP_PLAYING || s.state == PS_CLIP_STOPPING) {
                    // Restart: a short fade would be nicer; a jump to 0 keeps it tight.
                }
                s.state = PS_CLIP_PLAYING;
                s.pos = 0;
                s.fade = 0;
                s.fadingOut = false;
                s.startAt = -1;
                if (s.liveStart) stamp(i, true);
            }
            if (s.stopAt >= 0 && s.stopAt < b1) {
                s.fadingOut = true;
                s.stopAt = -1;
                if (s.liveStop) stamp(i, false);
            }
            render(s, bpm, L, R, n);
        }
    }

private:
    struct Slot {
        PSClipParams p{};
        int state = PS_CLIP_STOPPED;
        double startAt = -1, stopAt = -1;
        double pos = 0, fade = 0;
        bool fadingOut = false, liveStart = false, liveStop = false;
    };

    static void halt(Slot &s) {
        s.state = PS_CLIP_STOPPED;
        s.startAt = s.stopAt = -1;
        s.fadingOut = false;
    }

    double launchBeat(double beat, bool transport) {
        bool any = false;
        for (auto &s : slots_) any |= s.state == PS_CLIP_PLAYING || s.state == PS_CLIP_STOPPING;
        if (quantize_ <= 0) return beat;
        if (!transport && !any) {
            origin_ = beat;      // nothing to stay in time with: start now, grid from here
            return beat;
        }
        const double origin = transport ? 0.0 : origin_;
        return origin + std::ceil((beat - origin) / quantize_ - 1e-6) * quantize_;
    }

    void render(Slot &s, double bpm, float *L, float *R, int n) {
        if (s.state != PS_CLIP_PLAYING && s.state != PS_CLIP_STOPPING) return;
        const PSSample *smp = s.p.sample;
        if (!smp || smp->frames < 2) { halt(s); return; }
        const int len = smp->frames;
        const double rate = s.p.beats > 0 ? len / (s.p.beats * 60.0 / bpm * sr_) : smp->sampleRate / sr_;
        const float *c0 = smp->channel[0].data();
        const float *c1 = smp->channels > 1 ? smp->channel[1].data() : c0;
        const bool loop = s.p.mode != PS_CLIP_ONESHOT;
        for (int i = 0; i < n; ++i) {
            if (s.fadingOut) {
                s.fade -= fadeOut_;
                if (s.fade <= 0) { halt(s); return; }
            } else if (s.fade < 1) {
                s.fade = std::min(1.0, s.fade + fadeIn_);
            }
            if (s.pos >= len - 1) {
                if (!loop) { halt(s); return; }
                s.pos -= len - 1;
            }
            const int k = static_cast<int>(s.pos);
            const double f = s.pos - k;
            const double g = s.fade * s.p.level;
            L[i] += static_cast<float>((c0[k] + (c0[k + 1] - c0[k]) * f) * g);
            R[i] += static_cast<float>((c1[k] + (c1[k + 1] - c1[k]) * f) * g);
            s.pos += rate;
        }
    }

    double sr_, fadeIn_ = 0, fadeOut_ = 0, quantize_ = 4, origin_ = 0;
    std::array<Slot, PS_CLIPS> slots_{};
};

} // namespace ps
