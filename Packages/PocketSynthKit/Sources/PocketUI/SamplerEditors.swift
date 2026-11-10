import AudioEngine
import SamplerCore
import SwiftUI

// MARK: - Trim

struct TrimView: View {
    let model: AppModel

    var body: some View {
        let s = model.sampler
        let layer = s.selected.layers[0]
        if let id = layer.sampleID, let info = s.project.sample(id), let peaks = model.peaks(id) {
            let start = layer.start
            let end = layer.end ?? info.frames
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(PadAddress.name(s.selectedPad)) · \(info.name)")
                        .font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Button { s.audition() } label: { Image(systemName: "play.fill") }
                    Button {
                        s.updateSelected { $0.layers[0].reverse.toggle() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundStyle(layer.reverse ? Theme.warm : Theme.text)
                    }
                    Button("Reset") { s.setTrim(pad: s.selectedPad, start: 0, end: info.frames) }
                }
                .buttonStyle(.bordered)
                .tint(Theme.text)

                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(info.frames) * w }
                    let frame: (CGFloat) -> Int = { Int((max(0, min(w, $0)) / w) * CGFloat(info.frames)) }
                    ZStack(alignment: .topLeading) {
                        WaveformView(peaks: peaks, reverse: layer.reverse)
                        Rectangle().fill(Color.black.opacity(0.55)).frame(width: x(start))
                        Rectangle().fill(Color.black.opacity(0.55))
                            .frame(width: max(0, w - x(end)))
                            .offset(x: x(end))
                        TrimHandle(color: Theme.accent)
                            .position(x: x(start), y: geo.size.height / 2)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                                .onChanged { s.setTrim(pad: s.selectedPad, start: frame($0.location.x), end: end) })
                        TrimHandle(color: Theme.warm)
                            .position(x: x(end), y: geo.size.height / 2)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                                .onChanged { s.setTrim(pad: s.selectedPad, start: start, end: frame($0.location.x)) })
                    }
                    .coordinateSpace(name: "wave")
                }
                .padding(.horizontal, 16) // keep the edge handles fully visible
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.screen))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Text("Start \(seconds(start, info))")
                    Spacer()
                    Text("Length \(seconds(end - start, info))")
                    Spacer()
                    Text("End \(seconds(end, info))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.dim)
            }
            .padding(14)
        } else {
            EmptyHint(text: "Select a pad with a sample to trim it.\nAssign samples from Main.")
        }
    }

    private func seconds(_ frames: Int, _ info: SampleInfo) -> String {
        String(format: "%.3f s", Double(frames) / info.sampleRate)
    }
}

struct TrimHandle: View {
    let color: Color
    var body: some View {
        ZStack {
            Rectangle().fill(color).frame(width: 2)
            Capsule().fill(color).frame(width: 14, height: 34)
        }
        .frame(width: 44) // generous hit area
        .contentShape(Rectangle())
    }
}

struct WaveformView: View {
    let peaks: SampleLibrary.Peaks
    let reverse: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 0 else { return }
            let mid = size.height / 2
            var path = Path()
            for i in 0..<n {
                let k = reverse ? n - 1 - i : i
                let x = CGFloat(i) / CGFloat(n) * size.width
                path.move(to: CGPoint(x: x, y: mid - CGFloat(peaks.max[k]) * mid * 0.95))
                path.addLine(to: CGPoint(x: x, y: mid - CGFloat(peaks.min[k]) * mid * 0.95))
            }
            ctx.stroke(path, with: .color(Theme.screenText.opacity(0.85)), lineWidth: max(1, size.width / CGFloat(n)))
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .multilineTextAlignment(.center)
            .font(.callout)
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pad edit (program parameters)

struct PadEditView: View {
    let model: AppModel
    let sampler: SamplerController

    var body: some View {
        let s = sampler
        let pad = s.selected
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(PadAddress.name(s.selectedPad))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Picker("Trigger", selection: Binding(get: { pad.trigger },
                                                         set: { v in s.updateSelected { $0.trigger = v } })) {
                        ForEach(TriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                HStack(spacing: 16) {
                    Toggle("Mono", isOn: Binding(get: { pad.mono }, set: { v in s.updateSelected { $0.mono = v } }))
                        .fixedSize()
                    Stepper("Mute group \(pad.muteGroup == 0 ? "off" : "\(pad.muteGroup)")",
                            value: Binding(get: { pad.muteGroup }, set: { v in s.updateSelected { $0.muteGroup = v } }),
                            in: 0...32)
                        .fixedSize()
                }
                .foregroundStyle(Theme.text)

                Section("PAD") {
                    ParamSlider("Level", pad.level, 0...2, db) { v in s.updateSelected { $0.level = v } }
                    ParamSlider("Pan", pad.pan, -1...1, panText) { v in s.updateSelected { $0.pan = v } }
                    ParamSlider("Tune", pad.layers[0].tune, -24...24, semis) { v in
                        s.updateSelected { p in for i in p.layers.indices { p.layers[i].tune = v.rounded() } }
                    }
                }
                Section("ROUTING") {
                    Picker("Output", selection: Binding(get: { pad.output }, set: { v in s.updateSelected { $0.output = v } })) {
                        Text("Sampler main").tag(0)
                        ForEach(1...SamplerMixer.submixCount, id: \.self) { Text("Submix \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.text)
                    ForEach(0..<SamplerMixer.returnCount, id: \.self) { k in
                        ParamSlider("Send \(k + 1)", pad.sends[k], 0...1, pct) { v in s.updateSelected { $0.sends[k] = v } }
                    }
                }
                Section("ENVELOPE") {
                    let e = pad.envelope
                    ParamSlider("Attack", e.attackMs, 0...2000, ms) { v in s.updateSelected { $0.envelope.attackMs = v } }
                    ParamSlider("Hold", e.holdMs, 0...2000, ms) { v in s.updateSelected { $0.envelope.holdMs = v } }
                    ParamSlider("Decay", e.decayMs, 0...5000, { $0 == 0 ? "off" : ms($0) }) { v in
                        s.updateSelected { $0.envelope.decayMs = v }
                    }
                    ParamSlider("Sustain", e.sustain, 0...1, pct) { v in s.updateSelected { $0.envelope.sustain = v } }
                    ParamSlider("Release", e.releaseMs, 1...5000, ms) { v in s.updateSelected { $0.envelope.releaseMs = v } }
                }
                Section("LAYERS") {
                    ForEach(pad.layers.indices, id: \.self) { i in
                        LayerRow(index: i, layer: pad.layers[i], samples: s.project.samples,
                                 update: { body in s.updateSelected { body(&$0.layers[i]) } },
                                 remove: pad.layers.count > 1 ? { s.updateSelected { $0.layers.remove(at: i) } } : nil)
                    }
                    if pad.layers.count < Pad.maxLayers {
                        Button("Add layer", systemImage: "plus") {
                            s.updateSelected { $0.layers.append(PadLayer()) }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(14)
        }
    }

    private func db(_ v: Double) -> String { v <= 0.0001 ? "-∞ dB" : String(format: "%+.1f dB", 20 * log10(v)) }
    private func panText(_ v: Double) -> String { abs(v) < 0.01 ? "C" : String(format: "%@%d", v < 0 ? "L" : "R", Int(abs(v) * 100)) }
    private func semis(_ v: Double) -> String { String(format: "%+d st", Int(v.rounded())) }
    private func ms(_ v: Double) -> String { "\(Int(v)) ms" }
    private func pct(_ v: Double) -> String { "\(Int(v * 100))%" }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
            content
        }
    }
}

struct ParamSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onChange: @MainActor (Double) -> Void

    init(_ title: String, _ value: Double, _ range: ClosedRange<Double>,
         _ format: @escaping (Double) -> String, onChange: @escaping @MainActor (Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.format = format
        self.onChange = onChange
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(Theme.accent)
            Text(format(value)).frame(width: 72, alignment: .trailing).font(.caption.monospacedDigit())
        }
        .font(.callout)
        .foregroundStyle(Theme.text)
    }
}

struct LayerRow: View {
    let index: Int
    let layer: PadLayer
    let samples: [SampleInfo]
    let update: ((inout PadLayer) -> Void) -> Void
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
            Menu {
                Button("Empty") { update { $0.sampleID = nil } }
                ForEach(samples) { info in
                    Button(info.name) { update { $0.sampleID = info.id; $0.start = 0; $0.end = nil } }
                }
            } label: {
                Text(samples.first { $0.id == layer.sampleID }?.name ?? "Empty")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Stepper("Vel \(layer.velocityLow)–\(layer.velocityHigh)",
                    value: Binding(get: { layer.velocityLow },
                                   set: { v in update { $0.velocityLow = min(v, $0.velocityHigh) } }),
                    in: 0...127, step: 8)
                .fixedSize()
                .font(.caption.monospacedDigit())
            Stepper("",
                    value: Binding(get: { layer.velocityHigh },
                                   set: { v in update { $0.velocityHigh = max(v, $0.velocityLow) } }),
                    in: 0...127, step: 8)
                .labelsHidden()
            if let remove {
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
    }
}

// MARK: - Mixer

struct MixerView: View {
    let model: AppModel
    let sampler: SamplerController

    var body: some View {
        let s = sampler
        let m = s.project.mixer
        HStack(spacing: 10) {
            // Faders go through setParam, so Write automation records them.
            Fader(label: "SYNTH", value: m.synthLevel, onChange: { s.setParam(.synthLevel, $0) }, onEnd: { s.endParam(.synthLevel) })
            Fader(label: "SAMPLER", value: m.samplerLevel, onChange: { s.setParam(.samplerLevel, $0) }, onEnd: { s.endParam(.samplerLevel) })
            Fader(label: "MASTER", value: m.masterLevel, color: Theme.warm,
                  onChange: { s.setParam(.masterLevel, $0) }, onEnd: { s.endParam(.masterLevel) })
            Divider().background(Theme.stroke)
            VStack(alignment: .leading, spacing: 6) {
                Text("BANK \(PadAddress.bankName(s.bank)) PADS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
                ForEach([1, 0], id: \.self) { row in // top row = pads 9–16, like the grid
                    HStack(spacing: 4) {
                        ForEach(0..<8, id: \.self) { col in
                            let g = row * 8 + col
                            let pad = PadAddress.pad(bank: s.bank, gridIndex: g)
                            Fader(label: String(format: "%02d", g + 1),
                                  value: s.project.program.pads[pad].level, range: 0...2, compact: true,
                                  onChange: { s.setParam(.padLevel(pad), $0) }, onEnd: { s.endParam(.padLevel(pad)) })
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

struct Fader: View {
    let label: String
    let value: Double
    var range: ClosedRange<Double> = 0...1.5
    var color: Color = Theme.accent
    var compact = false
    let onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let h = geo.size.height
                let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.raised)
                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.75)).frame(height: max(4, f * h))
                    // Unity mark
                    Rectangle().fill(Theme.text.opacity(0.4)).frame(height: 1)
                        .offset(y: -CGFloat((1 - range.lowerBound) / (range.upperBound - range.lowerBound)) * h)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let u = Double(1 - min(max(g.location.y / h, 0), 1))
                    var v = range.lowerBound + u * (range.upperBound - range.lowerBound)
                    if abs(v - 1) < 0.03 { v = 1 } // snap to unity
                    onChange(v)
                }
                .onEnded { _ in onEnd() })
            }
            .frame(minWidth: compact ? 10 : 24, maxWidth: compact ? 22 : 40)
            Text(label)
                .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: compact ? 22 : nil)
        }
    }
}
