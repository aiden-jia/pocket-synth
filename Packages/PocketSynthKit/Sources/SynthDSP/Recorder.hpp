// Sampling recorder (SAMPLER_SPEC §4): records one source into a stereo PSSample, with a
// threshold arm, a pre-roll ring (audio from just before the trigger) and a peak meter.
// Plus the input ring that carries mic audio from the input tap thread to the engine.
#pragma once

#include "DSPCommon.hpp"
#include "Sampler.hpp"

namespace ps {

/// Lock-free stereo ring: one producer thread pushes, the audio thread pops.
class InputRing {
public:
    explicit InputRing(size_t frames) : l_(frames + 1), r_(frames + 1) {}

    void push(const float *L, const float *R, int n) {
        const size_t cap = l_.size();
        size_t h = head_.load(std::memory_order_relaxed);
        const size_t t = tail_.load(std::memory_order_acquire);
        for (int i = 0; i < n; ++i) {
            const size_t next = (h + 1) % cap;
            if (next == t) break; // full: drop the rest
            l_[h] = L[i];
            r_[h] = R ? R[i] : L[i];
            h = next;
        }
        head_.store(h, std::memory_order_release);
    }

    /// Pops up to `max` frames. Returns how many.
    int pop(float *L, float *R, int max) {
        const size_t cap = l_.size();
        size_t t = tail_.load(std::memory_order_relaxed);
        const size_t h = head_.load(std::memory_order_acquire);
        int n = 0;
        while (n < max && t != h) {
            L[n] = l_[t];
            R[n] = r_[t];
            t = (t + 1) % cap;
            ++n;
        }
        tail_.store(t, std::memory_order_release);
        return n;
    }

private:
    std::vector<float> l_, r_;
    std::atomic<size_t> head_{0}, tail_{0};
};

class Recorder {
public:
    explicit Recorder(double sr) : sr_(sr) {
        const size_t n = static_cast<size_t>(0.5 * sr) + 1;
        ring_[0].assign(n, 0.0f);
        ring_[1].assign(n, 0.0f);
        peakDecay_ = static_cast<float>(expCoef(300, sr));
    }

    void setMeterSource(int s) { meterSource_ = s; }

    /// Returns the previous buffer (if any) so the caller can release it.
    PSSample *arm(PSSample *buf, int source, float threshold, int preRoll) {
        PSSample *old = buf_;
        buf_ = buf;
        meterSource_ = source;
        threshold_ = std::max(0.0f, threshold);
        preRoll_ = std::clamp(preRoll, 0, static_cast<int>(ring_[0].size()) - 1);
        written_ = 0;
        state_ = PS_REC_ARMED;
        if (threshold_ <= 0) trigger();
        return old;
    }

    void stop() {
        if (state_ == PS_REC_ARMED || state_ == PS_REC_RECORDING) state_ = PS_REC_DONE;
    }

    PSSample *release() {
        PSSample *b = buf_;
        buf_ = nullptr;
        state_ = PS_REC_IDLE;
        written_ = 0;
        return b;
    }

    void forget(const PSSample *s) {
        if (buf_ == s) { buf_ = nullptr; state_ = PS_REC_IDLE; }
    }

    /// Offer `n` frames of `source`; only the metered/recorded source is used.
    void feed(int source, const float *L, const float *R, int n) {
        if (source != meterSource_) return;
        for (int i = 0; i < n; ++i) {
            const float a = std::max(std::fabs(L[i]), std::fabs(R[i]));
            peak_ = std::max(a, peak_ * peakDecay_);
            if (state_ == PS_REC_ARMED && a >= threshold_) trigger();
            if (state_ == PS_REC_RECORDING) {
                if (written_ >= buf_->frames) { state_ = PS_REC_DONE; }
                else {
                    buf_->channel[0][written_] = L[i];
                    buf_->channel[1][written_] = R[i];
                    ++written_;
                }
            }
            ring_[0][ringPos_] = L[i];
            ring_[1][ringPos_] = R[i];
            ringPos_ = (ringPos_ + 1) % ring_[0].size();
        }
    }

    int state() const { return state_; }
    int frames() const { return written_; }
    float peak() const { return peak_; }

private:
    void trigger() {
        state_ = PS_REC_RECORDING;
        if (!buf_) { state_ = PS_REC_IDLE; return; }
        const size_t n = ring_[0].size();
        const int pre = std::min(preRoll_, buf_->frames);
        for (int k = 0; k < pre; ++k) {
            const size_t idx = (ringPos_ + n - static_cast<size_t>(pre) + static_cast<size_t>(k)) % n;
            buf_->channel[0][k] = ring_[0][idx];
            buf_->channel[1][k] = ring_[1][idx];
        }
        written_ = pre;
    }

    double sr_;
    PSSample *buf_ = nullptr;
    int state_ = PS_REC_IDLE;
    int meterSource_ = PS_SOURCE_MASTER;
    float threshold_ = 0;
    int preRoll_ = 0;
    int written_ = 0;
    float peak_ = 0, peakDecay_ = 0.999f;
    std::array<std::vector<float>, 2> ring_;
    size_t ringPos_ = 0;
};

} // namespace ps
