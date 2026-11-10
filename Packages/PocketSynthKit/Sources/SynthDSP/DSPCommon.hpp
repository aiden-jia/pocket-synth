// Shared DSP building blocks: lock-free queue, filters, delay lines, noise.
#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

namespace ps {

constexpr double kPi = 3.141592653589793;
constexpr double kTwoPi = 6.283185307179586;

inline double noteToHz(double note) { return 440.0 * std::pow(2.0, (note - 69.0) / 12.0); }

/// Time constant for an exponential segment that reaches -40 dB in `ms`.
inline double expCoef(double ms, double sr) {
    return std::exp(std::log(0.01) / std::max(1.0, ms * 0.001 * sr));
}

/// Lock-free single-producer / single-consumer FIFO.
template <typename T, size_t N>
class SPSCQueue {
public:
    bool push(const T &v) {
        const size_t h = head_.load(std::memory_order_relaxed);
        const size_t next = (h + 1) % N;
        if (next == tail_.load(std::memory_order_acquire)) return false; // full: drop
        buffer_[h] = v;
        head_.store(next, std::memory_order_release);
        return true;
    }
    bool pop(T &v) {
        const size_t t = tail_.load(std::memory_order_relaxed);
        if (t == head_.load(std::memory_order_acquire)) return false;
        v = buffer_[t];
        tail_.store((t + 1) % N, std::memory_order_release);
        return true;
    }

private:
    std::array<T, N> buffer_{};
    std::atomic<size_t> head_{0};
    std::atomic<size_t> tail_{0};
};

/// Topology-preserving-transform state-variable filter (Simper / Zavalishin).
struct SVF {
    double ic1 = 0, ic2 = 0;
    double lp = 0, bp = 0, hp = 0;

    static double gFor(double hz, double sr) {
        return std::tan(kPi * std::clamp(hz, 10.0, 0.45 * sr) / sr);
    }
    void process(double x, double g, double k) {
        const double a1 = 1.0 / (1.0 + g * (g + k));
        const double a2 = g * a1;
        const double a3 = g * a2;
        const double v3 = x - ic2;
        const double v1 = a1 * ic1 + a2 * v3;
        const double v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2 * v1 - ic1;
        ic2 = 2 * v2 - ic2;
        lp = v2;
        bp = v1;
        hp = x - k * v1 - v2;
    }
    void reset() { ic1 = ic2 = lp = bp = hp = 0; }
};

struct OnePole {
    double z = 0, a = 0;
    void setHz(double hz, double sr) { a = std::exp(-kTwoPi * std::min(hz, 0.49 * sr) / sr); }
    double lowpass(double x) { z = x + a * (z - x); return z; }
    double highpass(double x) { return x - lowpass(x); }
};

/// Circular delay line with fractional (Hermite) reads. Allocate before rendering.
class DelayLine {
public:
    void allocate(size_t n) {
        buf_.assign(n + 4, 0.0f);
        w_ = 0;
    }
    void clear() { std::fill(buf_.begin(), buf_.end(), 0.0f); }
    size_t size() const { return buf_.size(); }
    void push(float x) {
        buf_[w_] = x;
        w_ = (w_ + 1) % buf_.size();
    }
    /// Sample written `d` samples ago (the newest sample has age 1), Hermite-interpolated.
    float read(double d) const {
        const size_t n = buf_.size();
        d = std::clamp(d, 2.0, static_cast<double>(n - 3));
        const size_t di = static_cast<size_t>(d);
        const float f = static_cast<float>(d - di);
        auto at = [&](size_t age) { return buf_[(w_ + n - age) % n]; };
        const float xm1 = at(di - 1);
        const float x0 = at(di);
        const float x1 = at(di + 1);
        const float x2 = at(di + 2);
        // Hermite between x0 (age di) and x1 (age di+1).
        const float c1 = 0.5f * (x1 - xm1);
        const float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
        const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
        return ((c3 * f + c2) * f + c1) * f + x0;
    }

private:
    std::vector<float> buf_;
    size_t w_ = 0;
};

struct Noise {
    uint32_t s = 0x9E3779B9u;
    float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;

    Noise(uint32_t seed = 0x9E3779B9u) : s(seed ? seed : 1) {}
    float white() {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        return static_cast<float>(s) * (2.0f / 4294967295.0f) - 1.0f;
    }
    /// Paul Kellet's refined pink filter.
    float pink() {
        const float w = white();
        b0 = 0.99886f * b0 + w * 0.0555179f;
        b1 = 0.99332f * b1 + w * 0.0750759f;
        b2 = 0.96900f * b2 + w * 0.1538520f;
        b3 = 0.86650f * b3 + w * 0.3104856f;
        b4 = 0.55000f * b4 + w * 0.5329522f;
        b5 = -0.7616f * b5 - w * 0.0168980f;
        const float out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362f;
        b6 = w * 0.115926f;
        return out * 0.11f;
    }
};

} // namespace ps
