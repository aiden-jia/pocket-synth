import SamplerCore
import SwiftUI

/// Grid editor (SAMPLER_SPEC §6): one lane per pad of the current bank (pad 16 on top,
/// pad 1 at the bottom, like the pads), bars across, and a velocity lane for the
/// selected pad.
///
/// Tap an empty cell to add a note, tap a note to select it, tap it again to delete it,
/// drag a note to move it. Drag in the velocity lane to set velocities.
struct GridEditorView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController
    @State private var page = 0
    @State private var selectedEvent: UInt32?
    @State private var drag: DragState?
    @State private var dragStart: CGPoint = .zero
    @State private var confirmClear = false

    enum DragState {
        case note(id: UInt32, tick: Int, lane: Int, moved: Bool)
        case cell
        case velocity
    }

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            GeometryReader { geo in
                let g = GridGeometry(size: geo.size, sequence: sampler.sequence, page: currentPage,
                                     grid: sampler.project.timingCorrect.value.ticks)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(ctx, g) }
                    laneLabels(g)
                    // UIKit touches: SwiftUI drag gestures drop quick successive taps.
                    #if canImport(UIKit)
                    SingleTouchSurface(began: { began($0, g) }, moved: { moved($0, g) }, ended: { ended($0, g) })
                    #endif
                }
            }
        }
        .padding(10)
        .confirmationDialog("Clear every note in this sequence?", isPresented: $confirmClear) {
            Button("Clear track", role: .destructive) { sampler.clearTrack() }
        }
    }

    /// Page shown: follows the playhead while playing.
    private var currentPage: Int {
        let seq = sampler.sequence
        let pages = GridGeometry.pages(seq)
        if sampler.transport.playing, sampler.transport.position >= 0 {
            let windowTicks = GridGeometry.visibleBars(seq) * seq.ticksPerBar
            return min(pages - 1, Int(sampler.transport.position) / max(1, windowTicks))
        }
        return min(page, pages - 1)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let seq = sampler.sequence
        let tc = sampler.project.timingCorrect
        return HStack(spacing: 6) {
            Menu {
                ForEach(0..<min(sampler.project.sequences.count + 1, SamplerProject.maxSequences), id: \.self) { i in
                    Button(i < sampler.project.sequences.count ? sampler.project.sequences[i].name : "New sequence") {
                        sampler.selectSequence(i)
                        page = 0
                    }
                }
            } label: {
                ToolLabel(text: String(format: "S%02d", sampler.project.currentSequence + 1), icon: "chevron.down")
            }

            HStack(spacing: 2) {
                ToolButton(icon: "minus") { sampler.setBars(seq.bars - 1) }
                Text("\(seq.bars) BAR\(seq.bars == 1 ? "" : "S")")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 46)
                ToolButton(icon: "plus") { sampler.setBars(seq.bars + 1) }
            }

            ToolButton(icon: "repeat", on: seq.loop) { sampler.setLoop(!seq.loop) }

            Menu {
                Picker("Note value", selection: Binding(get: { tc.value }, set: { v in sampler.setTimingCorrect { $0.value = v } })) {
                    ForEach(NoteValue.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Swing", selection: Binding(get: { Int(tc.swing) }, set: { v in sampler.setTimingCorrect { $0.swing = Double(v) } })) {
                    ForEach([50, 54, 58, 62, 66, 71, 75], id: \.self) { Text("Swing \($0)%").tag($0) }
                }
                Picker("Strength", selection: Binding(get: { Int(tc.strength) }, set: { v in sampler.setTimingCorrect { $0.strength = Double(v) } })) {
                    ForEach([100, 75, 50, 25], id: \.self) { Text("Strength \($0)%").tag($0) }
                }
                Toggle("Correct while recording", isOn: Binding(get: { tc.onInput }, set: { v in sampler.setTimingCorrect { $0.onInput = v } }))
                Divider()
                Button("Quantize all notes", systemImage: "wand.and.stars") { sampler.quantizeTrack() }
            } label: {
                ToolLabel(text: "TC \(tc.value.label)\(tc.swing > 50 ? " S\(Int(tc.swing))" : "")", icon: "chevron.down", on: tc.onInput)
            }

            Menu {
                Button("Double length", systemImage: "square.on.square") { sampler.doubleSequence() }
                Toggle("Mute track", isOn: Binding(get: { seq.tracks[0].mute }, set: { sampler.setTrackMute($0) }))
                Divider()
                Button("Clear track…", systemImage: "trash", role: .destructive) { confirmClear = true }
            } label: {
                ToolLabel(text: nil, icon: "ellipsis")
            }

            Spacer(minLength: 0)

            let pages = GridGeometry.pages(seq)
            if pages > 1 {
                ToolButton(icon: "chevron.left") { page = max(0, currentPage - 1) }
                Text("\(currentPage + 1)/\(pages)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                ToolButton(icon: "chevron.right") { page = min(pages - 1, currentPage + 1) }
            }
        }
        .frame(height: 28)
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ g: GridGeometry) {
        let seq = sampler.sequence
        let selectedLane = g.lane(forPad: sampler.selectedPad, bank: sampler.bank)

        // Lanes
        for lane in 0..<16 {
            let r = CGRect(x: g.gridX, y: g.laneY(lane), width: g.gridWidth, height: g.laneHeight)
            let fill = lane == selectedLane ? Theme.accent.opacity(0.10) : (lane % 2 == 0 ? Theme.raised.opacity(0.55) : Theme.raised.opacity(0.35))
            ctx.fill(Path(r), with: .color(fill))
        }
        // Grid lines: TC steps, beats, bars.
        var t = g.windowStart
        while t <= g.windowStart + g.windowTicks {
            let x = g.x(t)
            let isBar = t % seq.ticksPerBar == 0
            let isBeat = t % PPQN.ticks == 0
            let line = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: g.lanesHeight + g.velocityHeight + 4)) }
            ctx.stroke(line, with: .color(.white.opacity(isBar ? 0.35 : isBeat ? 0.16 : 0.06)), lineWidth: isBar ? 1.2 : 0.6)
            if isBar {
                ctx.draw(Text("\(t / seq.ticksPerBar + 1)").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.dim), at: CGPoint(x: x + 3, y: g.lanesHeight + g.velocityHeight + 10), anchor: .leading)
            }
            t += g.gridTicks
        }

        // Notes
        for e in seq.tracks[0].events {
            guard let lane = g.lane(forPad: e.pad, bank: sampler.bank), g.visible(e.tick) else { continue }
            let r = g.noteRect(e, lane: lane)
            let selected = e.id == selectedEvent
            let color = selected ? Theme.warm : Theme.accent.opacity(0.35 + 0.65 * Double(e.velocity) / 127)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color))
            if e.tune != 0 {
                ctx.draw(Text(String(format: "%+d", Int(e.tune))).font(.system(size: 8, weight: .bold)).foregroundColor(Theme.background),
                         at: CGPoint(x: r.minX + 2, y: r.midY), anchor: .leading)
            }
        }

        // Velocity lane for the selected pad.
        let vr = CGRect(x: g.gridX, y: g.lanesHeight + 4, width: g.gridWidth, height: g.velocityHeight)
        ctx.fill(Path(roundedRect: vr, cornerRadius: 4), with: .color(Theme.raised.opacity(0.6)))
        for e in seq.tracks[0].events where e.pad == sampler.selectedPad && g.visible(e.tick) {
            let x = g.x(e.tick)
            let h = vr.height * Double(e.velocity) / 127
            let bar = CGRect(x: x, y: vr.maxY - h, width: 4, height: h)
            ctx.fill(Path(bar), with: .color(e.id == selectedEvent ? Theme.warm : Theme.accent))
        }

        // Playhead
        let pos = sampler.transport.position
        if sampler.transport.playing, pos >= 0, g.visible(Int(pos)) {
            let x = g.x(Int(pos))
            let p = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: vr.maxY)) }
            ctx.stroke(p, with: .color(sampler.transport.recording != nil ? .red : Theme.text), lineWidth: 1.5)
        }
    }

    private func laneLabels(_ g: GridGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<16, id: \.self) { lane in
                let pad = g.pad(forLane: lane, bank: sampler.bank)
                let name = sampler.project.sample(sampler.project.program.pads[pad].primarySample)?.name
                VStack(alignment: .leading, spacing: 0) {
                    Text(PadAddress.name(pad)).font(.system(size: 9, weight: .bold, design: .monospaced))
                    if g.laneHeight > 20, let name {
                        Text(name).font(.system(size: 8)).lineLimit(1)
                    }
                }
                .foregroundStyle(pad == sampler.selectedPad ? Theme.accent : (name == nil ? Theme.dim.opacity(0.6) : Theme.text))
                .frame(width: g.gridX - 4, height: g.laneHeight, alignment: .leading)
                .offset(y: g.laneY(lane))
                .allowsHitTesting(false)
            }
            Text("VEL").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
                .offset(y: g.lanesHeight + 4 + g.velocityHeight / 2 - 6)
                .allowsHitTesting(false)
        }
    }

    // MARK: Touches

    private func began(_ p: CGPoint, _ g: GridGeometry) {
        dragStart = p
        if p.y > g.lanesHeight + 2 {
            drag = .velocity
            moved(p, g)
        } else if p.x < g.gridX {
            if let lane = g.lane(at: p.y) {
                let pad = g.pad(forLane: lane, bank: sampler.bank)
                sampler.selectedPad = pad
                sampler.audition(pad)
            }
            drag = nil
        } else if let hit = noteAt(p, g) {
            drag = .note(id: hit.id, tick: hit.tick, lane: g.lane(forPad: hit.pad, bank: sampler.bank) ?? 0, moved: false)
        } else {
            drag = .cell
        }
    }

    private func moved(_ p: CGPoint, _ g: GridGeometry) {
        let seq = sampler.sequence
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        switch drag {
        case .note(let id, let tick, let lane, let moved):
            guard moved || hypot(dx, dy) > 6 else { return }
            drag = .note(id: id, tick: tick, lane: lane, moved: true)
            let dt = Int((dx / g.gridWidth) * Double(g.windowTicks))
            let snapped = Int((Double(tick + dt) / Double(g.gridTicks)).rounded()) * g.gridTicks
            let newLane = max(0, min(15, lane + Int((dy / g.laneHeight).rounded())))
            let pad = g.pad(forLane: newLane, bank: sampler.bank)
            if let e = seq.tracks[0].events.first(where: { $0.id == id }), e.tick != snapped || e.pad != pad {
                sampler.moveEvent(id, toTick: max(0, min(seq.lengthTicks - 1, snapped)), pad: pad)
            }
            selectedEvent = id
        case .velocity:
            let tick = g.tick(at: p.x)
            let candidates = seq.tracks[0].events.filter { $0.pad == sampler.selectedPad && g.visible($0.tick) }
            guard let e = candidates.min(by: { abs($0.tick - tick) < abs($1.tick - tick) }) else { return }
            let vel = Int(127 * (1 - (p.y - g.lanesHeight - 4) / g.velocityHeight))
            sampler.setVelocity(e.id, vel)
            selectedEvent = e.id
        default:
            break
        }
    }

    private func ended(_ p: CGPoint, _ g: GridGeometry) {
        defer { drag = nil }
        switch drag {
        case .note(let id, _, _, let moved):
            guard !moved else { return }
            if selectedEvent == id {
                sampler.deleteEvent(id)
                selectedEvent = nil
            } else {
                selectedEvent = id
                if let e = sampler.sequence.tracks[0].events.first(where: { $0.id == id }) { sampler.selectedPad = e.pad }
            }
        case .cell:
            guard p.x >= g.gridX, hypot(p.x - dragStart.x, p.y - dragStart.y) < 10, let lane = g.lane(at: p.y) else { return }
            let pad = g.pad(forLane: lane, bank: sampler.bank)
            let tick = (g.tick(at: p.x) / g.gridTicks) * g.gridTicks
            sampler.toggleStep(pad: pad, tick: tick, span: g.gridTicks)
            sampler.selectedPad = pad
            selectedEvent = sampler.sequence.tracks[0].events.first { $0.pad == pad && $0.tick == tick }?.id
        default:
            break
        }
    }

    private func noteAt(_ p: CGPoint, _ g: GridGeometry) -> NoteEvent? {
        sampler.sequence.tracks[0].events.last { e in
            guard let lane = g.lane(forPad: e.pad, bank: sampler.bank), g.visible(e.tick) else { return false }
            return g.noteRect(e, lane: lane).insetBy(dx: -4, dy: -2).contains(p)
        }
    }
}

/// Coordinates for the grid editor.
struct GridGeometry {
    let size: CGSize
    let sequence: PadSequence
    let gridTicks: Int
    let windowStart: Int
    let windowTicks: Int
    let gridX: CGFloat = 46
    let velocityHeight: CGFloat
    let lanesHeight: CGFloat

    init(size: CGSize, sequence: PadSequence, page: Int, grid: Int) {
        self.size = size
        self.sequence = sequence
        gridTicks = grid
        windowTicks = Self.visibleBars(sequence) * sequence.ticksPerBar
        windowStart = page * windowTicks
        velocityHeight = max(28, min(44, size.height * 0.14))
        lanesHeight = max(16, size.height - velocityHeight - 18)
    }

    static func visibleBars(_ s: PadSequence) -> Int { min(s.bars, 2) }
    static func pages(_ s: PadSequence) -> Int { Int((Double(s.bars) / Double(visibleBars(s))).rounded(.up)) }

    var gridWidth: CGFloat { max(1, size.width - gridX) }
    var laneHeight: CGFloat { lanesHeight / 16 }

    func x(_ tick: Int) -> CGFloat { gridX + CGFloat(tick - windowStart) / CGFloat(windowTicks) * gridWidth }
    func tick(at x: CGFloat) -> Int {
        let t = windowStart + Int((x - gridX) / gridWidth * CGFloat(windowTicks))
        return max(windowStart, min(windowStart + windowTicks - 1, t))
    }
    func visible(_ tick: Int) -> Bool { tick >= windowStart && tick < windowStart + windowTicks }

    /// Lane 0 is the top (pad 16 of the bank).
    func laneY(_ lane: Int) -> CGFloat { CGFloat(lane) * laneHeight }
    func lane(at y: CGFloat) -> Int? { y >= 0 && y < lanesHeight ? Int(y / laneHeight) : nil }
    func pad(forLane lane: Int, bank: Int) -> Int { PadAddress.pad(bank: bank, gridIndex: 15 - lane) }
    func lane(forPad pad: Int, bank: Int) -> Int? {
        let g = pad - bank * DrumProgram.padsPerBank
        return (0..<16).contains(g) ? 15 - g : nil
    }

    func noteRect(_ e: NoteEvent, lane: Int) -> CGRect {
        let x0 = x(e.tick)
        let w = max(5, CGFloat(e.length) / CGFloat(windowTicks) * gridWidth)
        return CGRect(x: x0, y: laneY(lane) + 1.5, width: min(w, gridX + gridWidth - x0), height: max(4, laneHeight - 3))
    }
}

#if canImport(UIKit)
import UIKit

/// Reports one touch at a time (began / moved / ended) in local coordinates.
struct SingleTouchSurface: UIViewRepresentable {
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: (CGPoint) -> Void

    func makeUIView(context: Context) -> SingleTouchView {
        let v = SingleTouchView()
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: SingleTouchView, context: Context) {
        v.began = began
        v.moved = moved
        v.ended = ended
    }
}

final class SingleTouchView: UIView {
    var began: (CGPoint) -> Void = { _ in }
    var moved: (CGPoint) -> Void = { _ in }
    var ended: (CGPoint) -> Void = { _ in }
    private weak var active: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, let t = touches.first else { return }
        active = t
        began(t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = active, touches.contains(t) else { return }
        moved(t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        guard let t = active, touches.contains(t) else { return }
        active = nil
        ended(t.location(in: self))
    }
}
#endif

struct ToolLabel: View {
    let text: String?
    var icon: String? = nil
    var on = false

    var body: some View {
        HStack(spacing: 3) {
            if let text { Text(text).font(.system(size: 11, weight: .bold, design: .monospaced)) }
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .foregroundStyle(on ? Theme.accent : Theme.text)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
    }
}

struct ToolButton: View {
    let icon: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? Theme.background : Theme.text)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent : Theme.raised))
        }
        .buttonStyle(.plain)
    }
}
