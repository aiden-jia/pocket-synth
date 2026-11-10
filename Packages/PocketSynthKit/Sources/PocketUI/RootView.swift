import SamplerCore
import SwiftUI

/// Top-level view: a top bar with the panel switch, then the active panel.
/// Switching panels never stops audio (DESIGN §8).
public struct RootView: View {
    @State private var model = AppModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            ZStack {
                SynthPanelView(model: model)
                    .opacity(model.panel == .synth ? 1 : 0)
                    .allowsHitTesting(model.panel == .synth)
                SamplerPanelView(model: model)
                    .opacity(model.panel == .sampler ? 1 : 0)
                    .allowsHitTesting(model.panel == .sampler)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        #if os(iOS)
        // Edge swipes (home indicator, Control Center) shouldn't steal pad touches.
        .defersSystemGestures(on: .all)
        #endif
        .task {
            // Engine telemetry (playheads, recorded hits), toasts and idle menus.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                model.frame()
            }
        }
    }
}

struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.sampler
        let t = s.transport
        HStack(spacing: 10) {
            Picker("Panel", selection: $model.panel) {
                ForEach(AppModel.Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Spacer(minLength: 4)

            if let error = model.audioError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warm)
                    .font(.caption)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                BarButton(icon: "stop.fill", on: false) { s.stop() }
                BarButton(icon: "play.fill", on: t.playing, tint: Theme.accent) { s.play() }
                BarButton(icon: "record.circle.fill", on: t.recording != nil, tint: .red) { s.record() }
                Menu {
                    Picker("Record", selection: Bindable(s).recordMode) {
                        ForEach(RecordMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Count-in", selection: Binding(get: { t.countInBars }, set: { s.setCountIn(bars: $0) })) {
                        Text("No count-in").tag(0)
                        Text("Count-in 1 bar").tag(1)
                        Text("Count-in 2 bars").tag(2)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 30)
                        .foregroundStyle(Theme.dim)
                }
            }

            Text(model.positionText)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.recording != nil ? Color.red : Theme.text)
                .frame(width: 52, alignment: .leading)

            let click = model.synth.state.metronome
            BarButton(icon: "metronome.fill", on: click, tint: Theme.warm) { model.synth.setMetronome(!click) }

            HStack(spacing: 2) {
                BarButton(icon: "minus", on: false) { model.setBPM(model.bpm - 1) }
                Button { model.tapTempo() } label: {
                    VStack(spacing: 0) {
                        Text("\(Int(model.bpm))")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                        Text("TAP").font(.system(size: 8, weight: .bold, design: .monospaced)).opacity(0.6)
                    }
                    .frame(width: 44, height: 30)
                    .foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain)
                BarButton(icon: "plus", on: false) { model.setBPM(model.bpm + 1) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }
}

struct BarButton: View {
    let icon: String
    let on: Bool
    var tint: Color = Theme.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 30)
                .foregroundStyle(on ? Theme.background : tint)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? tint : Theme.raised))
        }
        .buttonStyle(.plain)
    }
}
