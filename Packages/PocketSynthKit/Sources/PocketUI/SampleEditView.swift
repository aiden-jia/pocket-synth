import AudioEngine
import DSPKit
import SamplerCore
import SwiftUI

/// Sample Edit (SAMPLER_SPEC §5): Trim and Chop, plus destructive processes.
struct SampleEditView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $sampler.editMode) {
                    ForEach(EditMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(Theme.dim)
                }
                ProcessMenu(model: model, disabled: sampler.selected.primarySample == nil || model.busy != nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            switch sampler.editMode {
            case .trim: TrimView(model: model)
            case .chop: ChopView(model: model, sampler: sampler)
            }
        }
    }
}

/// Destructive processes on the selected pad's sample (each makes an undoable new version).
struct ProcessMenu: View {
    let model: AppModel
    let disabled: Bool

    var body: some View {
        Menu {
            Section("Level") {
                Button("Normalize") { model.applyProcess { _, _ in .normalize() } }
                Button("Gain +3 dB") { model.applyProcess { _, _ in .gain(dB: 3) } }
                Button("Gain −3 dB") { model.applyProcess { _, _ in .gain(dB: -3) } }
                Button("Fade in (trim start)") { model.applyProcess { a, r in .fadeIn(frames: max(1, r.lowerBound + Int(0.01 * a.sampleRate))) } }
                Button("Fade out (trim end)") { model.applyProcess { a, r in .fadeOut(frames: max(1, a.frames - r.upperBound + Int(0.05 * a.sampleRate))) } }
                Button("Remove DC") { model.applyProcess { _, _ in .removeDC } }
            }
            Section("Edit (uses the trim)") {
                Button("Crop to trim") { model.applyProcess { _, r in .crop(r) } }
                Button("Delete trim region") { model.applyProcess { _, r in .delete(r) } }
                Button("Silence trim region") { model.applyProcess { _, r in .silence(r) } }
                Button("Reverse") { model.applyProcess { _, _ in .reverse } }
                Button("Trim leading silence") { model.applyProcess { _, _ in .trimSilence() } }
            }
            Section("Time & pitch") {
                Menu("Pitch shift") {
                    ForEach([12, 7, 5, 2, 1, -1, -2, -5, -7, -12], id: \.self) { st in
                        Button(String(format: "%+d semitones", st)) { model.applyProcess { _, _ in .pitchShift(semitones: Double(st)) } }
                    }
                }
                Menu("Time stretch") {
                    ForEach([50, 75, 90, 110, 125, 150, 200], id: \.self) { pct in
                        Button("\(pct) % length") { model.applyProcess { _, _ in .timeStretch(ratio: Double(pct) / 100) } }
                    }
                    Button("Fit trim to 1 bar at project tempo") {
                        let bpm = model.bpm
                        model.applyProcess { a, r in
                            .timeStretch(ratio: (4 * 60 / bpm) / (Double(r.count) / a.sampleRate))
                        }
                    }
                }
            }
            Section("Character") {
                Button("Bit crush (8-bit, ÷2)") { model.applyProcess { _, _ in .bitCrush(bits: 8, downsample: 2) } }
                Button("Lo-fi (6-bit, ÷4)") { model.applyProcess { _, _ in .bitCrush(bits: 6, downsample: 4) } }
                Button("To mono") { model.applyProcess { _, _ in .toMono } }
            }
            Divider()
            Button("Discard unused audio", systemImage: "trash", role: .destructive) { model.discardUnusedAudio() }
        } label: {
            ToolLabel(text: "PROCESS", icon: "chevron.down")
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - Chop

struct ChopView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController

    /// What the finger on the waveform is moving.
    private enum Drag: Equatable {
        case marker(Int)
        case searchLower, searchUpper       // a smart window's handles
        case searchWindow(offset: Int)      // the whole window, held `offset` frames in
    }
    @State private var drag: Drag?
    @State private var dragMoved = false

    var body: some View {
        Group {
            if let c = model.chop, let peaks = model.peaks(c.sample), let info = sampler.project.sample(c.sample) {
                VStack(alignment: .leading, spacing: 8) {
                    controls(c)
                    waveform(c, peaks)
                    HStack(spacing: 6) {
                        Text("\(c.slices.count) slice\(c.slices.count == 1 ? "" : "s") · \(info.name)")
                            .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                        Spacer()
                        if c.method == .manual || c.selected != nil { markerButtons(c) }
                        Menu {
                            ForEach(ChopConversion.allCases, id: \.self) { conv in
                                Button(conv.label) { model.convertChop(conv) }
                            }
                        } label: {
                            ToolLabel(text: "CONVERT", icon: "chevron.down", on: true)
                        }
                    }
                }
                .padding(14)
            } else {
                EmptyHint(text: "Select a pad with a sample to chop it.\nThe pads play the slices while this screen is open.")
            }
        }
        .onAppear { model.startChop() }
        .onChange(of: sampler.selectedPad) { _, _ in
            // Hitting pads here plays slices; only a new sample starts a new chop.
            if sampler.selected.primarySample != model.chop?.sample { model.startChop() }
        }
    }

    @ViewBuilder
    private func controls(_ c: ChopSession) -> some View {
        Picker("Method", selection: Binding(get: { c.method }, set: { m in model.updateChop { $0.method = m } })) {
            ForEach(ChopMethod.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        HStack(spacing: 8) {
            switch c.method {
            case .threshold:
                Slider(value: Binding(get: { c.sensitivity }, set: { v in model.updateChop { $0.sensitivity = v } }), in: 0...1)
                    .tint(Theme.accent)
                Text("SENS \(Int(c.sensitivity * 100))").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
            case .regions:
                ToolButton(icon: "minus") { model.updateChop { $0.regionCount = max(2, $0.regionCount - 1) } }
                Text("\(c.regionCount)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                ToolButton(icon: "plus") { model.updateChop { $0.regionCount = min(128, $0.regionCount + 1) } }
                Spacer(minLength: 0)
            case .beats:
                ToolButton(icon: "minus") { model.updateChop { $0.bpm = max(40, ($0.bpm - 1).rounded()) } }
                Text(String(format: "%.1f", c.bpm)).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text).frame(minWidth: 44)
                ToolButton(icon: "plus") { model.updateChop { $0.bpm = min(300, ($0.bpm + 1).rounded()) } }
                Button("Detect") { model.detectChopBPM() }.font(.caption).buttonStyle(.bordered).tint(Theme.accent)
                Picker("Every", selection: Binding(get: { c.division }, set: { d in model.updateChop { $0.division = d } })) {
                    ForEach(BeatDivision.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .font(.caption)
            case .smart:
                Text(smartHint(c)).font(.caption).foregroundStyle(Theme.dim)
                    .lineLimit(2, reservesSpace: true) // the waveform stays put as the hint changes
                Spacer(minLength: 0)
                let found = c.snapFrame != nil
                let addable = found && !c.markers.contains(c.snapFrame!)
                ToolButton(icon: "play.fill") { model.previewSnap() }
                    .disabled(!found).opacity(found ? 1 : 0.4)
                Button { model.addSmartSlice() } label: {
                    ToolLabel(text: "ADD SLICE", icon: "scissors", on: addable)
                }
                .buttonStyle(.plain)
                .disabled(!addable).opacity(addable ? 1 : 0.4)
            case .manual:
                Text("Tap the waveform to add a slice; drag a marker to move it.")
                    .font(.caption).foregroundStyle(Theme.dim).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    private func smartHint(_ c: ChopSession) -> String {
        if c.searchRange == nil { return "Tap near where a sound starts, then drag to adjust." }
        if model.snapSearching { return "Finding the start…" }
        guard let f = c.snapFrame else { return "Nothing starts here. Move or widen the window." }
        let at = String(format: "Starts at %.3f s.", Double(f) / c.sampleRate)
        if let i = c.markers.firstIndex(of: f) { return "\(at) Slice \(i + 1) is there." }
        return at
    }

    private func markerButtons(_ c: ChopSession) -> some View {
        HStack(spacing: 4) {
            if let s = c.selected {
                ToolButton(icon: "scissors") { model.updateChop { $0.split(s) } }
                ToolButton(icon: "arrow.right.to.line") { model.updateChop { $0.mergeWithNext(s) } }
                ToolButton(icon: "trash") { model.updateChop { $0.removeMarker(s) } }
            }
        }
    }

    private func waveform(_ c: ChopSession, _ peaks: SampleLibrary.Peaks) -> some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(c.frames) * w }
            ZStack(alignment: .topLeading) {
                WaveformView(peaks: peaks, reverse: false)
                Canvas { ctx, size in
                    for (i, r) in c.slices.enumerated() {
                        let x0 = x(r.lowerBound), x1 = x(r.upperBound)
                        if i == c.selected {
                            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                                     with: .color(Theme.warm.opacity(0.18)))
                        }
                        let line = Path { $0.move(to: CGPoint(x: x0, y: 0)); $0.addLine(to: CGPoint(x: x0, y: size.height)) }
                        ctx.stroke(line, with: .color(i == c.selected ? Theme.warm : Theme.accent), lineWidth: i == 0 ? 0 : 1.5)
                        if x1 - x0 > 14 {
                            ctx.draw(Text("\(i + 1)").font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.screenText),
                                     at: CGPoint(x: x0 + 3, y: 8), anchor: .leading)
                        }
                    }
                    if c.method == .smart, let r = c.searchRange {
                        drawSearch(ctx, size, from: x(r.lowerBound), to: x(r.upperBound), snap: c.snapFrame.map(x))
                    }
                }
                #if canImport(UIKit)
                SingleTouchSurface(began: { began($0, c, w) }, moved: { moved($0, c, w) }, ended: { _ in ended() })
                #endif
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.screen))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Touch zone of a smart window handle, outside its edge so even a narrow window keeps
    /// its middle free for dragging the whole window.
    private static let handleReach: CGFloat = 22

    /// The smart search window: a shaded span with a handle just outside each edge, and a
    /// dashed line with a flag where the detector found the start.
    private func drawSearch(_ ctx: GraphicsContext, _ size: CGSize, from x0: CGFloat, to x1: CGFloat, snap: CGFloat?) {
        ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(Theme.text.opacity(0.14)))
        for (edge, out) in [(x0, CGFloat(-1)), (x1, CGFloat(1))] {
            ctx.fill(Path(CGRect(x: edge - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.text.opacity(0.6)))
            let knob = CGRect(x: out < 0 ? edge - 10 : edge + 2, y: size.height / 2 - 14, width: 8, height: 28)
            ctx.fill(Path(roundedRect: knob, cornerRadius: 4), with: .color(Theme.text))
        }
        guard let sx = snap else { return }
        let line = Path { $0.move(to: CGPoint(x: sx, y: 0)); $0.addLine(to: CGPoint(x: sx, y: size.height)) }
        ctx.stroke(line, with: .color(Theme.warm), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        let flag = Path { p in
            p.move(to: CGPoint(x: sx - 5, y: 0))
            p.addLine(to: CGPoint(x: sx + 5, y: 0))
            p.addLine(to: CGPoint(x: sx, y: 8))
            p.closeSubpath()
        }
        ctx.fill(flag, with: .color(Theme.warm))
    }

    private func frame(_ p: CGPoint, _ c: ChopSession, _ w: CGFloat) -> Int {
        Int(max(0, min(1, p.x / w)) * CGFloat(c.frames))
    }

    private func began(_ p: CGPoint, _ c: ChopSession, _ w: CGFloat) {
        let f = frame(p, c, w)
        let perPoint = CGFloat(c.frames) / w
        dragMoved = false
        // Smart window first: a handle just outside each edge (and the inner 10 pt of a
        // wide window), the whole window from anywhere else inside it.
        if c.method == .smart, let r = c.searchRange {
            let lx = CGFloat(r.lowerBound) / perPoint, ux = CGFloat(r.upperBound) / perPoint
            let inner: CGFloat = ux - lx > 48 ? 10 : 0
            if p.x >= lx - Self.handleReach, p.x < lx + inner { drag = .searchLower; return }
            if p.x > ux - inner, p.x <= ux + Self.handleReach { drag = .searchUpper; return }
            if p.x >= lx, p.x <= ux { drag = .searchWindow(offset: f - r.lowerBound); return }
        }
        // Near a marker: select it (and drag it).
        let tol = Int(10 * perPoint)
        if let i = c.markers.indices.dropFirst().min(by: { abs(c.markers[$0] - f) < abs(c.markers[$1] - f) }),
           abs(c.markers[i] - f) <= tol {
            model.updateChop { $0.selected = i }
            drag = .marker(i)
            return
        }
        switch c.method {
        case .manual:
            model.updateChop { $0.addMarker(at: f) }
            model.previewSlice(atFrame: f)
        case .smart:
            // Outside the window: it jumps here (same width) and follows the finger.
            model.updateChop { $0.centerSearch(at: f) }
            dragMoved = true // a fresh window isn't a tap to audition
            drag = .searchWindow(offset: (model.chop?.searchRange).map { f - $0.lowerBound } ?? 0)
        default:
            model.previewSlice(atFrame: f)
        }
    }

    private func moved(_ p: CGPoint, _ c: ChopSession, _ w: CGFloat) {
        guard let d = drag else { return }
        dragMoved = true
        let f = frame(p, c, w)
        switch d {
        case .marker(let i):
            // Editing makes a detected chop manual; a smart chop is already hand-made.
            if c.method != .manual && c.method != .smart { model.updateChop { $0.method = .manual } }
            model.updateChop { $0.moveMarker(i, to: f) }
        case .searchLower:
            model.updateChop { s in
                guard let r = s.searchRange else { return }
                s.setSearchRange(min(f, r.upperBound - s.minSearchFrames), r.upperBound)
            }
        case .searchUpper:
            model.updateChop { s in
                guard let r = s.searchRange else { return }
                s.setSearchRange(r.lowerBound, max(f, r.lowerBound + s.minSearchFrames))
            }
        case .searchWindow(let offset):
            model.updateChop { $0.moveSearch(to: f - offset) }
        }
    }

    private func ended() {
        // A tap (no drag) inside the window auditions the snap.
        if case .searchWindow = drag, !dragMoved { model.previewSnap() }
        drag = nil
    }
}

// MARK: - Sampler mode

struct SamplingView: View {
    @Bindable var model: AppModel

    var body: some View {
        let st = model.sampling
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Source", selection: Binding(get: { st.source }, set: { s in Task { await model.setSamplingSource(s) } })) {
                    ForEach(SamplingSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.text)
                Spacer()
                Picker("Max", selection: $model.sampling.maxSeconds) {
                    ForEach([10.0, 30, 60, 120], id: \.self) { Text("max \(Int($0)) s").tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.dim)
            }

            LevelMeter(level: model.meter, threshold: st.useThreshold ? st.thresholdDB : nil)
                .frame(height: 22)

            HStack(spacing: 10) {
                Toggle("Threshold", isOn: $model.sampling.useThreshold).toggleStyle(.button).tint(Theme.warm)
                Slider(value: $model.sampling.thresholdDB, in: -60...0).tint(Theme.warm).disabled(!st.useThreshold)
                Text("\(Int(st.thresholdDB)) dB").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 48)
            }
            HStack(spacing: 10) {
                Text("Pre-roll").font(.callout).foregroundStyle(Theme.text)
                Slider(value: $model.sampling.preRollMs, in: 0...500, step: 10).tint(Theme.accent)
                Text("\(Int(st.preRollMs)) ms").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 48)
            }
            HStack(spacing: 8) {
                Toggle("Stereo", isOn: $model.sampling.stereo).toggleStyle(.button)
                Toggle("Trim silence", isOn: $model.sampling.trimSilence).toggleStyle(.button)
                Toggle("Then edit", isOn: $model.sampling.openEditAfter).toggleStyle(.button)
            }
            .tint(Theme.accent)
            .font(.caption)

            Spacer(minLength: 0)
            HStack(spacing: 12) {
                recordButton
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                    Text("Takes land on \(PadAddress.name(model.sampler.selectedPad)) and the empty pads after it.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                if model.recorderState == .armed || model.recorderState == .recording {
                    Button("Cancel") { model.cancelSampling() }.buttonStyle(.bordered).tint(Theme.dim)
                }
            }
            if let e = model.samplingError {
                Text(e).font(.caption).foregroundStyle(Theme.warm)
            }
        }
        .padding(14)
    }

    private var statusText: String {
        switch model.recorderState {
        case .idle, .done: "READY"
        case .armed: "WAITING FOR SOUND…"
        case .recording: String(format: "REC %.1f s", model.recordedSeconds)
        }
    }

    private var recordButton: some View {
        let active = model.recorderState == .armed || model.recorderState == .recording
        return Button {
            if active { model.stopSampling() } else { model.armSampling() }
        } label: {
            Image(systemName: active ? "stop.fill" : "record.circle")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 64, height: 52)
                .foregroundStyle(active ? Theme.background : Color.red)
                .background(RoundedRectangle(cornerRadius: 12).fill(active ? Color.red : Theme.raised))
        }
        .buttonStyle(.plain)
    }
}

/// Peak meter in dB (-60…0) with an optional threshold line.
struct LevelMeter: View {
    let level: Float
    let threshold: Double?

    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? max(-60, 20 * log10(Double(level))) : -60
            let x = CGFloat((db + 60) / 60) * geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.raised)
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent, Theme.warm, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, x))
                if let t = threshold {
                    Rectangle().fill(Color.white).frame(width: 2)
                        .offset(x: CGFloat((t + 60) / 60) * geo.size.width - 1)
                }
            }
        }
    }
}
