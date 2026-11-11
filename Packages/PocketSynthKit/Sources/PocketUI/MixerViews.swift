import SamplerCore
import SwiftUI

/// Mixer (SAMPLER_SPEC §8): levels, 8 submixes with an insert, 4 returns, XY FX.
struct MixerScreen: View {
    let model: AppModel
    @Bindable var sampler: SamplerController
    @State private var tab = Tab.levels

    enum Tab: String, CaseIterable {
        case levels = "Levels", submixes = "Submixes", returns = "Returns", xy = "XY FX"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mixer", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            switch tab {
            case .levels: MixerView(model: model, sampler: sampler)
            case .submixes: SubmixView(sampler: sampler)
            case .returns: ReturnsView(sampler: sampler)
            case .xy: XYPadView(sampler: sampler)
            }
        }
    }
}

struct SubmixView: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        let subs = sampler.project.mixer.submixes
        HStack(spacing: 6) {
            ForEach(0..<SamplerMixer.submixCount, id: \.self) { i in
                let s = subs[i]
                let used = sampler.project.program.pads.contains { $0.output == i + 1 }
                VStack(spacing: 4) {
                    Menu {
                        Picker("Insert", selection: Binding(get: { s.insert }, set: { v in sampler.setMixer { $0.submixes[i].insert = v } })) {
                            ForEach(InsertType.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Text(s.insert == .none ? "—" : String(s.insert.label.prefix(5)).uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .foregroundStyle(s.insert == .none ? Theme.dim : Theme.background)
                            .background(RoundedRectangle(cornerRadius: 5).fill(s.insert == .none ? Theme.raised : Theme.warm))
                    }
                    if s.insert != .none {
                        Knob(value: s.amount, range: 0...1, size: 30) { v in sampler.setMixer { $0.submixes[i].amount = v } }
                    } else {
                        Spacer().frame(height: 30)
                    }
                    Fader(label: "SUB \(i + 1)", value: s.level, compact: true,
                          onChange: { sampler.setParam(.submixLevel(i), $0) }, onEnd: { sampler.endParam(.submixLevel(i)) })
                    Button { sampler.setMixer { $0.submixes[i].mute.toggle() } } label: {
                        Text("M").font(.system(size: 10, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .foregroundStyle(s.mute ? Theme.background : Theme.text)
                            .background(RoundedRectangle(cornerRadius: 4).fill(s.mute ? Color.red : Theme.raised))
                    }
                    .buttonStyle(.plain)
                    Circle().fill(used ? Theme.accent : Theme.stroke).frame(width: 5, height: 5)
                }
            }
        }
        .padding(12)
    }
}

struct ReturnsView: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        let rets = sampler.project.mixer.returns
        HStack(spacing: 14) {
            ForEach(0..<SamplerMixer.returnCount, id: \.self) { i in
                let r = rets[i]
                VStack(spacing: 6) {
                    Menu {
                        Picker("Effect", selection: Binding(get: { r.type }, set: { v in sampler.setMixer { $0.returns[i].type = v } })) {
                            ForEach(ReturnType.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Text(r.type.label.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(Theme.text)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                    }
                    Fader(label: "RET \(i + 1)", value: r.level,
                          onChange: { sampler.setParam(.returnLevel(i), $0) }, onEnd: { sampler.endParam(.returnLevel(i)) })
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Sends are per pad:\nProgram › Routing.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            .frame(width: 110)
        }
        .padding(12)
    }
}

/// XY performance pad: hold to play the effect, or latch it on.
struct XYPadView: View {
    @Bindable var sampler: SamplerController
    @State private var latched = false
    @State private var touching = false

    var body: some View {
        let xy = sampler.project.mixer.xy
        VStack(spacing: 8) {
            HStack {
                Picker("Effect", selection: Binding(get: { xy.type }, set: { v in sampler.setXY { $0.type = v } })) {
                    ForEach(XYType.allCases.filter { $0 != .off }, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer()
                Toggle("Latch", isOn: Binding(get: { latched }, set: { v in latched = v; sampler.setXY { $0.active = v || touching } }))
                    .toggleStyle(.button).tint(Theme.warm)
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.screen)
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                        p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                    }
                    .stroke(Theme.screenText.opacity(0.12))
                    Circle()
                        .fill(xy.active ? Theme.warm : Theme.screenText.opacity(0.4))
                        .frame(width: 34, height: 34)
                        .position(x: xy.x * w, y: (1 - xy.y) * h)
                    VStack {
                        Spacer()
                        HStack {
                            Text(xy.type.axes.x).font(.caption2)
                            Spacer()
                            Text("↑ " + xy.type.axes.y).font(.caption2)
                        }
                        .foregroundStyle(Theme.screenText.opacity(0.6))
                        .padding(8)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        touching = true
                        sampler.setXY {
                            $0.x = min(1, max(0, g.location.x / w))
                            $0.y = min(1, max(0, 1 - g.location.y / h))
                            $0.active = true
                        }
                    }
                    .onEnded { _ in
                        touching = false
                        sampler.setXY { $0.active = latched }
                    })
            }
        }
        .padding(12)
        .onAppear { latched = xy.active }
    }
}

/// A rotary knob: drag up / down to turn.
struct Knob: View {
    let value: Double
    let range: ClosedRange<Double>
    var size: CGFloat = 40
    var label: String? = nil
    let onChange: (Double) -> Void
    var onEnd: () -> Void = {}
    @State private var start: Double?

    var body: some View {
        let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        VStack(spacing: 2) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875).stroke(Theme.raised, lineWidth: 4).rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * f).stroke(Theme.accent, lineWidth: 4).rotationEffect(.degrees(90))
                Circle().fill(Theme.panel).padding(6)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard g.translation.height != 0 else { return } // a plain tap changes nothing
                    if start == nil { start = value }
                    let delta = -g.translation.height / 150 * (range.upperBound - range.lowerBound)
                    onChange(min(range.upperBound, max(range.lowerBound, start! + delta)))
                }
                .onEnded { _ in
                    if start != nil { onEnd() }
                    start = nil
                })
            if let label {
                Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

/// Four Q-Link knobs (SAMPLER_SPEC §9) with a page picker and the automation mode.
struct QLinkStrip: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    Picker("Q-Link", selection: $sampler.qlinkPage) {
                        ForEach(QLinkPage.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    menuLabel(sampler.qlinkPage.label.uppercased(), color: Theme.accent)
                }
                Menu {
                    Picker("Automation", selection: $sampler.automationMode) {
                        ForEach(AutomationMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    menuLabel("AUTO " + sampler.automationMode.label.uppercased(),
                              color: sampler.automationMode == .write ? .red : Theme.dim)
                }
            }
            .frame(width: 104)
            ForEach(Array(sampler.qlinks.enumerated()), id: \.offset) { i, p in
                if let p {
                    Knob(value: sampler.value(of: p), range: p.range, size: 36, label: p.label,
                         onChange: { sampler.setParam(p, $0) }, onEnd: { sampler.endParam(p) })
                        .frame(maxWidth: .infinity)
                        .contextMenu { assignMenu(i) }
                } else {
                    Menu { assignMenu(i) } label: {
                        Text("Assign").font(.caption2).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private func menuLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(text).lineLimit(1).fixedSize()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func assignMenu(_ i: Int) -> some View {
        if sampler.qlinkPage == .project {
            ForEach(AutoParam.assignable(selectedPad: sampler.selectedPad), id: \.self) { p in
                Button(p.label) { sampler.projectQLinks[i] = p }
            }
            Button("Unassign", role: .destructive) { sampler.projectQLinks[i] = nil }
        }
    }
}
