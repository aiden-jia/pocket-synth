import ChordTheory
import SwiftUI
import SynthCore

/// The synth panel: status screen, 7 chord pads, 3 menu keys, joystick and wheel.
/// Drawing is pure SwiftUI; all touches go through one multitouch layer on top.
struct SynthPanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let layout = SynthSurfaceLayout(size: geo.size)
            let synth = model.synth
            ZStack(alignment: .topLeading) {
                let display = synth.display
                StatusScreen(display: display)
                    .place(layout.screen)
                if case .game(let g)? = display.tool, g.running {
                    GameLaneView(columns: layout.pads.map { $0.midX - layout.screen.minX },
                                 lane: { model.synth.gameLane(at: $0) })
                        .place(layout.screen)
                        .allowsHitTesting(false)
                }
                if !synth.state.mode.isTool { // tools hide the looper
                    LooperMenu(model: model)
                        .position(x: layout.screen.maxX - 24, y: layout.screen.maxY - 22)
                        .zIndex(1)
                }

                ForEach(MenuKey.allCases, id: \.self) { k in
                    MenuKeyView(key: k, held: synth.isMenuHeld.contains(k))
                        .place(layout.menuKeys[k]!)
                }

                ForEach(1...7, id: \.self) { pad in
                    PadView(pad: pad,
                            label: synth.padLabel(pad),
                            held: synth.heldPads.contains(pad),
                            sounding: synth.sounding[pad] != nil,
                            locked: synth.state.locks[pad] != nil,
                            octave: synth.state.padOctave[pad - 1])
                        .place(layout.pads[pad - 1])
                }

                JoystickView(offset: model.stickOffset,
                             direction: synth.stick,
                             modeLabel: synth.state.stickMode.shortName)
                    .place(layout.joystick)

                WheelView(label: wheelLabel(synth))
                    .place(layout.wheel)

                #if canImport(UIKit)
                SynthTouchSurface(layout: layout,
                                  onEvent: { e, t in model.handle(e, at: t) },
                                  onStickOffset: { model.stickOffset = $0 })
                #endif
            }
        }
    }

    private func wheelLabel(_ s: SynthController) -> String {
        let held = s.isMenuHeld
        if held == [.key] { return "ATK" }
        if held == [.sound] { return "REL" }
        if held == [.mode] { return "CUT" }
        return "VOL"
    }
}

// MARK: - Pieces

private extension View {
    func place(_ r: CGRect) -> some View {
        frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
    }
}

struct StatusScreen: View {
    let display: DisplayModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Theme.screen)
            RoundedRectangle(cornerRadius: 14).stroke(Theme.screenText.opacity(0.15))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(display.status)
                    Spacer()
                    Text("\(display.bpm) BPM")
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.screenText.opacity(0.7))

                if let menu = display.menu {
                    MenuStrip(menu: menu)
                } else if let tool = display.tool {
                    ToolContent(tool: tool, detail: display.detail)
                } else {
                    Spacer(minLength: 0)
                    Text(display.chordName ?? "—")
                        .font(.system(size: display.steps == nil ? 44 : 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.screenText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                    if let steps = display.steps { StepStrip(cells: steps) }
                    Spacer(minLength: 0)
                    if let looper = display.looper { LooperStrip(looper: looper) }
                    if let detail = display.detail {
                        Text(detail)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.screenText.opacity(0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(12)

            if let text = display.dialog ?? display.toast {
                Text(text)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.screen)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(display.dialog != nil ? Theme.warm : Theme.screenText))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: display.toast)
    }
}

/// The six loop tracks and the looper transport, with the loop's progress.
struct LooperStrip: View {
    let looper: LooperDisplay

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                ForEach(looper.cells, id: \.index) { c in
                    HStack(spacing: 3) {
                        Text("\(c.index + 1)").opacity(0.6)
                        Text(c.solo ? "S" : c.muted ? "M" : c.state.symbol)
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .foregroundStyle(c.state == .record ? Theme.screen : Theme.screenText)
                    .background(RoundedRectangle(cornerRadius: 4).fill(cellFill(c)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.screenText, lineWidth: c.isCursor ? 1.5 : 0))
                }
                Text(looper.position == nil ? looper.lengthText : looper.paused ? "❚❚" : "▶")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 46, height: 20)
                    .foregroundStyle(Theme.screenText)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.screenText, lineWidth: looper.transportSelected ? 1.5 : 0))
                Spacer().frame(width: 34) // room for the loop menu
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.screenText.opacity(0.1))
                    if let p = looper.position {
                        Capsule().fill(Theme.screenText.opacity(0.6)).frame(width: geo.size.width * p)
                    }
                }
            }
            .frame(height: 3)
            .padding(.trailing, 40)
        }
    }

    private func cellFill(_ c: LoopCell) -> Color {
        switch c.state {
        case .record: Color.red.opacity(0.85)
        case .waiting: Theme.warm.opacity(0.35)
        case .play: Theme.screenText.opacity(c.muted ? 0.05 : 0.22)
        case .off: Theme.screenText.opacity(0.05)
        }
    }
}

/// Looper actions that need a list: send a loop to the sampler, clear everything.
struct LooperMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(0..<LooperState.trackCount, id: \.self) { t in
                if model.synth.loopIsPlayable(t) {
                    Button("Send loop \(t + 1) to Sampler", systemImage: "square.and.arrow.down") {
                        model.sendLoopToSampler(track: t)
                    }
                    Button("Send loop \(t + 1) to an audio track", systemImage: "waveform.path") {
                        model.sendLoopToAudioTrack(track: t)
                    }
                }
            }
            if !model.synth.looperHasAudio {
                Text("Record a loop: click the stick (length in Sound › ↑ › LOOP)")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.screenText.opacity(0.8))
                .frame(width: 36, height: 30)
        }
    }
}

/// Seq mode: one page of chord steps; the cursor is outlined, the playing step filled.
struct StepStrip: View {
    let cells: [StepCell]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(cells, id: \.index) { c in
                VStack(spacing: 2) {
                    Text("\(c.index + 1)").font(.system(size: 10, design: .monospaced)).opacity(0.6)
                    Text(c.label)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(c.isPlaying ? Theme.screen : Theme.screenText)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(c.isPlaying ? Theme.screenText : Theme.screenText.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.screenText, lineWidth: c.isCursor ? 1.5 : 0))
            }
        }
    }
}

struct MenuStrip: View {
    let menu: MenuDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(menu.title)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.screenText)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(menu.items.enumerated()), id: \.offset) { i, item in
                            Text(item)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundStyle(i == menu.selected ? Theme.screen : Theme.screenText)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(i == menu.selected ? Theme.screenText : Theme.screenText.opacity(0.08)))
                                .id(i)
                        }
                    }
                }
                .onAppear { if let s = menu.selected { proxy.scrollTo(s, anchor: .center) } }
                .onChange(of: menu.selected) { _, s in
                    if let s { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(s, anchor: .center) } }
                }
            }
            Text(menu.hint)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.screenText.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PadView: View {
    let pad: Int
    let label: String
    let held: Bool
    let sounding: Bool
    let locked: Bool
    let octave: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(held ? Theme.accent.opacity(0.85) : Theme.raised)
            RoundedRectangle(cornerRadius: 14)
                .stroke(sounding ? Theme.accent : Theme.stroke, lineWidth: sounding ? 2 : 1)
            VStack(spacing: 4) {
                HStack {
                    Text("\(pad)").font(.system(size: 12, weight: .bold, design: .rounded))
                    Spacer()
                    if locked { Image(systemName: "lock.fill").font(.system(size: 10)) }
                    if octave != 0 {
                        Text(octave > 0 ? "+\(octave)" : "\(octave)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(held ? Theme.background : Theme.dim)
                Spacer(minLength: 0)
                Text(label)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(held ? Theme.background : Theme.text)
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .scaleEffect(held ? 0.97 : 1)
        .animation(.easeOut(duration: 0.06), value: held)
    }
}

struct MenuKeyView: View {
    let key: MenuKey
    let held: Bool

    private var icon: String {
        switch key {
        case .key: "music.quarternote.3"
        case .sound: "waveform"
        case .mode: "square.grid.2x2"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(key.label).font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(held ? Theme.background : Theme.text)
        .background(RoundedRectangle(cornerRadius: 10).fill(held ? Theme.warm : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }
}

struct JoystickView: View {
    let offset: CGVector?
    let direction: StickDirection?
    let modeLabel: String

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Theme.panel)
                Circle().stroke(Theme.stroke, lineWidth: 1)
                // Direction ticks.
                ForEach(0..<8, id: \.self) { i in
                    Capsule()
                        .fill(direction?.rawValue == i ? Theme.accent : Theme.dim.opacity(0.4))
                        .frame(width: 4, height: side * 0.07)
                        .offset(y: -side * 0.42)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
                Circle()
                    .fill(offset == nil ? Theme.raised : Theme.accent.opacity(0.9))
                    .frame(width: side * 0.38, height: side * 0.38)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    .offset(x: offset?.dx ?? 0, y: offset?.dy ?? 0)
                Text(modeLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .offset(y: side * 0.32)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WheelView: View {
    let label: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
            VStack(spacing: 7) {
                ForEach(0..<14, id: \.self) { _ in
                    Capsule().fill(Theme.dim.opacity(0.35)).frame(height: 2)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 30)
            VStack {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 8)
                Spacer()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }
}
