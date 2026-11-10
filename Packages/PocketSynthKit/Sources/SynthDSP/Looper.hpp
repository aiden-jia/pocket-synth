// Synth looper (SYNTH_SPEC §5): six stereo tracks of the synth panel's output.
// The first take sets the loop length (fixed bars or free); later takes start at the
// loop point and last exactly one pass. Pause slows the loops down like a tape stop.
#pragma once

#include "DSPCommon.hpp"
#include "Sampler.hpp"

namespace ps {

class Looper {
public:
    struct Track {
        PSSample *buffer = nullptr;
        int state = PS_LOOP_OFF;
        int generation = 0;
        float gain = 1, smoothed = 1;
    };

    /// Hands a buffer back to the main thread (garbage queue).
    struct Release {
        void *context = nullptr;
        void (*fn)(void *, PSSample *) = nullptr;
        void operator()(PSSample *s) const { if (fn) fn(context, s); }
    };

    Looper(double sr, Release release) : sr_(sr), release_(release) {}

    // First take -------------------------------------------------------------------

    /// `startBeat`: the clock beat where recording begins (after any count-in).
    void recordFirst(int track, PSSample *buf, int limitFrames, double startBeat, int generation) {
        if (track < 0 || track >= PS_LOOPER_TRACKS || !buf) return;
        drop(track);
        Track &t = tracks_[track];
        t.buffer = buf;
        t.state = PS_LOOP_WAITING;
        t.generation = generation;
        first_ = track;
        firstLimit_ = std::min(limitFrames > 0 ? limitFrames : buf->frames, buf->frames);
        firstStart_ = startBeat;
        recorded_ = 0;
    }

    void stopFirst(int generation) {
        if (first_ < 0) return;
        Track &t = tracks_[first_];
        t.generation = generation;
        if (t.state == PS_LOOP_RECORD && recorded_ > 1) finishFirst();
    }

    void arm(int track, PSSample *buf, int generation) {
        if (track < 0 || track >= PS_LOOPER_TRACKS || !buf || length_ <= 0) {
            if (buf) release_(buf);
            return;
        }
        drop(track);
        Track &t = tracks_[track];
        t.buffer = buf;
        t.state = PS_LOOP_WAITING;
        t.generation = generation;
    }

    void clear(int track, int generation) {
        if (track < 0 || track >= PS_LOOPER_TRACKS) return;
        drop(track);
        tracks_[track].generation = generation;
        if (track == first_) first_ = -1;
        resetIfEmpty();
    }

    void clearAll() {
        for (int i = 0; i < PS_LOOPER_TRACKS; ++i) drop(i);
        first_ = -1;
        resetIfEmpty();
    }

    void pause(bool on) {
        pausing_ = on;
        if (!on) paused_ = false;
    }

    void setGain(int track, float g) {
        if (track >= 0 && track < PS_LOOPER_TRACKS) tracks_[track].gain = std::max(0.0f, g);
    }

    /// The clock should tick (count-in, recording or loops playing).
    bool running() const {
        if (first_ >= 0 && tracks_[first_].state != PS_LOOP_OFF && tracks_[first_].state != PS_LOOP_PLAY) return true;
        return length_ > 0 && !paused_;
    }

    void forget(const PSSample *s) {
        for (auto &t : tracks_)
            if (t.buffer == s) { t.buffer = nullptr; t.state = PS_LOOP_OFF; }
    }

    // Render -----------------------------------------------------------------------

    /// `srcL/R`: the synth output to record. Adds loop playback into outL/outR.
    void process(const float *srcL, const float *srcR, float *outL, float *outR, int n, double beat0, double beatsPerFrame) {
        const double gk = 1.0 - std::exp(-1.0 / (0.01 * sr_));
        const double stopStep = 1.0 / (0.6 * sr_);  // 0.6 s tape stop
        for (int i = 0; i < n; ++i) {
            // First take: count-in → record → loop.
            if (first_ >= 0) {
                Track &f = tracks_[first_];
                if (f.state == PS_LOOP_WAITING && beat0 + i * beatsPerFrame >= firstStart_) {
                    f.state = PS_LOOP_RECORD;
                    recorded_ = 0;
                }
                if (f.state == PS_LOOP_RECORD) {
                    f.buffer->channel[0][recorded_] = srcL[i];
                    f.buffer->channel[1][recorded_] = srcR[i];
                    if (++recorded_ >= firstLimit_) finishFirst();
                }
            }
            if (length_ <= 0) continue;

            // Tape stop / resume.
            if (pausing_) {
                rate_ = std::max(0.0, rate_ - stopStep);
                if (rate_ <= 0) paused_ = true;
            } else if (rate_ < 1) {
                rate_ = std::min(1.0, rate_ + 20 * stopStep);
            }
            if (paused_) continue;

            const int p = static_cast<int>(pos_);
            const double frac = pos_ - p;
            const int p1 = p + 1 < length_ ? p + 1 : 0;
            for (auto &t : tracks_) {
                t.smoothed += (t.gain - t.smoothed) * static_cast<float>(gk);
                if (t.state == PS_LOOP_RECORD && &t != firstTrack()) {
                    t.buffer->channel[0][p] = srcL[i];
                    t.buffer->channel[1][p] = srcR[i];
                } else if (t.state == PS_LOOP_PLAY && t.buffer) {
                    const float *l = t.buffer->channel[0].data(), *r = t.buffer->channel[1].data();
                    outL[i] += static_cast<float>((l[p] + (l[p1] - l[p]) * frac) * t.smoothed);
                    outR[i] += static_cast<float>((r[p] + (r[p1] - r[p]) * frac) * t.smoothed);
                }
            }
            pos_ += rate_;
            if (pos_ >= length_) {
                pos_ -= length_;
                wrap();
            }
        }
    }

    // Telemetry --------------------------------------------------------------------

    int packed(int track) const {
        const Track &t = tracks_[track];
        return (t.generation << 3) | t.state;
    }
    int length() const { return length_; }
    double position() const { return length_ > 0 ? pos_ / length_ : 0; }
    int recorded() const { return recorded_; }

private:
    const Track *firstTrack() const { return first_ >= 0 ? &tracks_[first_] : nullptr; }

    void finishFirst() {
        Track &f = tracks_[first_];
        length_ = std::max(2, recorded_);
        f.state = PS_LOOP_PLAY;
        first_ = -1;
        pos_ = 0;
        rate_ = 1;
        paused_ = pausing_ = false;
        wrap(); // anything armed starts now
    }

    /// At the loop point: finished passes play, armed tracks start recording.
    void wrap() {
        for (auto &t : tracks_) {
            if (&t == firstTrack()) continue;
            if (t.state == PS_LOOP_RECORD) t.state = PS_LOOP_PLAY;
            else if (t.state == PS_LOOP_WAITING && t.buffer && t.buffer->frames >= length_) t.state = PS_LOOP_RECORD;
        }
    }

    void drop(int track) {
        Track &t = tracks_[track];
        if (t.buffer) release_(t.buffer);
        t.buffer = nullptr;
        t.state = PS_LOOP_OFF;
    }

    void resetIfEmpty() {
        for (auto &t : tracks_) if (t.state != PS_LOOP_OFF) return;
        length_ = 0;
        pos_ = 0;
        rate_ = 1;
        paused_ = pausing_ = false;
    }

    double sr_;
    Release release_;
    std::array<Track, PS_LOOPER_TRACKS> tracks_{};
    int length_ = 0;
    double pos_ = 0, rate_ = 1;
    bool pausing_ = false, paused_ = false;
    int first_ = -1, firstLimit_ = 0, recorded_ = 0;
    double firstStart_ = 0;
};

} // namespace ps
