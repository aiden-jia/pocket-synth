import ChordTheory
import SamplerCore
import SwiftUI

/// Geometry of the 4×4 pad grid, shared by drawing and touch handling.
struct PadGridLayout: Equatable {
    let cells: [CGRect] // indexed by grid index (0 = bottom-left)

    init(size: CGSize, gap: CGFloat = 8) {
        let side = max(0, min((size.width - 3 * gap) / 4, (size.height - 3 * gap) / 4))
        let total = side * 4 + gap * 3
        let x0 = (size.width - total) / 2, y0 = (size.height - total) / 2
        var cells = [CGRect](repeating: .zero, count: 16)
        for row in 0..<4 {
            for col in 0..<4 {
                cells[PadAddress.gridIndex(row: row, column: col)] =
                    CGRect(x: x0 + CGFloat(col) * (side + gap), y: y0 + CGFloat(row) * (side + gap),
                           width: side, height: side)
            }
        }
        self.cells = cells
    }

    func hit(_ p: CGPoint) -> Int? { cells.firstIndex { $0.insetBy(dx: -3, dy: -3).contains(p) } }
}

/// The 4×4 pads of the current bank.
struct PadGridView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geo in
            let layout = PadGridLayout(size: geo.size)
            let s = model.sampler
            ZStack(alignment: .topLeading) {
                ForEach(0..<16, id: \.self) { g in
                    let pad = PadAddress.pad(bank: s.bank, gridIndex: g)
                    let p = s.project.program.pads[pad]
                    let notes = s.track.program.isNotes
                    let clips = s.track.program == .clip
                    let stepping = s.view == .grid && s.seqEditor == .step
                    let clipState = clips ? s.clipStates[g] : .stopped
                    SamplerPadView(name: stepping ? "\(g + 1)" : clips ? "CLIP \(g + 1)"
                                       : notes ? PitchName.noteName(s.perform.note(g)) : PadAddress.name(pad),
                                   sampleName: stepping ? (s.stepIsOn(g) ? "●" : nil)
                                       : clips ? s.project.sample(s.project.clips.pads[g].sampleID)?.name
                                       : notes ? s.track.program.label : levelLabel(s, g) ?? s.project.sample(p.primarySample)?.name,
                                   held: s.heldPads.contains(pad) || clipState == .playing,
                                   selected: clips ? clipState == .queued || clipState == .stopping : s.selectedPad == pad,
                                   velocity: clipState == .playing ? 70 : s.lastVelocity[pad])
                        .frame(width: layout.cells[g].width, height: layout.cells[g].height)
                        .position(x: layout.cells[g].midX, y: layout.cells[g].midY)
                }
                #if canImport(UIKit)
                PadTouchSurface(layout: layout,
                                onDown: { g, y, size in
                                    // In Chop, the pads play the slices (slice 1 = pad 1).
                                    if s.view == .edit, s.editMode == .chop, model.chop != nil {
                                        model.previewSlice(g)
                                    } else {
                                        s.padDown(gridIndex: g, y: y, size: size)
                                    }
                                },
                                onMove: { g, y, size in s.padPressure(gridIndex: g, y: y, size: size) },
                                onUp: { g in s.padUp(gridIndex: g) })
                #endif
            }
        }
    }

    private func levelLabel(_ s: SamplerController, _ g: Int) -> String? {
        switch s.sixteenLevels {
        case .velocity: "VEL \(SamplerController.levelVelocity(g))"
        case .tune: String(format: "TUNE %+d", Int(SamplerController.levelTune(g)))
        case nil: nil
        }
    }
}

struct SamplerPadView: View {
    let name: String
    let sampleName: String?
    let held: Bool
    let selected: Bool
    let velocity: Int?

    var body: some View {
        let glow = held ? 0.35 + 0.65 * Double(velocity ?? 100) / 127 : 0
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(sampleName == nil ? Theme.panel : Theme.raised)
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.warm.opacity(glow))
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(held ? Theme.background : Theme.dim)
                Spacer(minLength: 0)
                Text(sampleName ?? "")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(2)
                    .foregroundStyle(held ? Theme.background : Theme.text)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .scaleEffect(held ? 0.96 : 1)
        .animation(.easeOut(duration: 0.05), value: held)
    }
}

/// Right column: pads, bank buttons and the performance keys.
struct PadColumn: View {
    @Bindable var sampler: SamplerController
    let model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            PadGridView(model: model)
            HStack(spacing: 4) {
                ForEach(0..<DrumProgram.banks, id: \.self) { b in
                    KeyButton(label: PadAddress.bankName(b), on: sampler.bank == b, tint: Theme.accent) { sampler.bank = b }
                }
            }
            HStack(spacing: 4) {
                KeyButton(label: "FULL LVL", on: sampler.fullLevel, tint: Theme.warm) { sampler.fullLevel.toggle() }
                if sampler.track.program == .clip {
                    KeyButton(label: "STOP CLIPS", on: false, tint: Theme.warm) { sampler.stopClips() }
                } else if sampler.track.program.isNotes {
                    PerformMenu(sampler: sampler)
                } else {
                Menu {
                    Picker("16 Levels", selection: Binding(get: { sampler.sixteenLevels }, set: { sampler.setSixteenLevels($0) })) {
                        Text("Off").tag(LevelsParameter?.none)
                        ForEach(LevelsParameter.allCases, id: \.self) { Text($0.label).tag(LevelsParameter?.some($0)) }
                    }
                    Picker("Velocity", selection: $sampler.velocityMode) {
                        ForEach(VelocityMode.allCases, id: \.self) { Text("Velocity: \($0.label)").tag($0) }
                    }
                } label: {
                    KeyLabel(label: sampler.sixteenLevels.map { "16 \($0 == .velocity ? "VEL" : "TUNE")" } ?? "16 LVL",
                             on: sampler.sixteenLevels != nil, tint: Theme.warm)
                }
                }
                HoldKey(label: "ERASE", on: sampler.eraseHeld, tint: .red) { sampler.eraseHeld = $0 }
                KeyButton(icon: "arrow.uturn.backward", on: false, tint: Theme.text, enabled: sampler.history.canUndo) { sampler.undo() }
                KeyButton(icon: "arrow.uturn.forward", on: false, tint: Theme.text, enabled: sampler.history.canRedo) { sampler.redo() }
            }
            HStack(spacing: 4) {
                RetroKey(model: model)
                    .frame(width: 58)
                NoteRepeatKey(sampler: sampler)
                Menu {
                    Picker("Rate", selection: Binding(get: { sampler.repeatRate }, set: { sampler.setRepeatRate($0) })) {
                        ForEach(RepeatRate.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    KeyLabel(label: sampler.repeatRate.label, on: false, tint: Theme.accent)
                }
                .frame(width: 58)
            }
        }
    }
}

/// Pad Perform settings for note tracks (SAMPLER_SPEC §2).
struct PerformMenu: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        let p = sampler.perform
        Menu {
            Picker("Layout", selection: $sampler.perform.mode) {
                ForEach(PadPerform.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Root", selection: $sampler.perform.root) {
                ForEach(0..<12, id: \.self) { Text(PitchName.name($0)).tag($0) }
            }
            if p.mode == .scale {
                Picker("Scale", selection: $sampler.perform.scale) {
                    ForEach(Scale.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Picker("Octave", selection: $sampler.perform.octave) {
                ForEach(0...7, id: \.self) { Text("Pad 1 = \(PitchName.name(p.root))\($0)").tag($0) }
            }
        } label: {
            KeyLabel(label: p.mode == .chromatic ? "CHROM \(PitchName.name(p.root))\(p.octave)" : "SCALE \(PitchName.name(p.root))",
                     on: true, tint: Theme.accent)
        }
    }
}

/// Small square-ish key used in the pad column.
struct KeyLabel: View {
    var label: String? = nil
    var icon: String? = nil
    let on: Bool
    let tint: Color

    var body: some View {
        Group {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
            else { Text(label ?? "").font(.system(size: 11, weight: .bold, design: .monospaced)) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 28)
        .foregroundStyle(on ? Theme.background : Theme.text)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? tint : Theme.panel))
    }
}

struct KeyButton: View {
    var label: String? = nil
    var icon: String? = nil
    let on: Bool
    let tint: Color
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) { KeyLabel(label: label, icon: icon, on: on, tint: tint) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}

/// A key that is on only while held.
struct HoldKey: View {
    let label: String
    let on: Bool
    let tint: Color
    let changed: (Bool) -> Void

    var body: some View {
        KeyLabel(label: label, on: on, tint: tint)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !on { changed(true) } }
                .onEnded { _ in changed(false) })
    }
}

/// Note Repeat: hold for momentary repeat, or tap to latch it on (tap again to stop).
struct NoteRepeatKey: View {
    let sampler: SamplerController
    @State private var pressedAt: Date?
    @State private var wasOn = false

    var body: some View {
        KeyLabel(label: "NOTE REPEAT", on: sampler.noteRepeat, tint: Theme.accent)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = Date()
                    wasOn = sampler.noteRepeat
                    sampler.setNoteRepeat(true)
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressedAt ?? Date())
                    pressedAt = nil
                    // A long hold is momentary; a tap toggles the latch.
                    if held > 0.35 || wasOn { sampler.setNoteRepeat(false) }
                })
    }
}

#if canImport(UIKit)
import UIKit

/// Multitouch layer for the pads: velocity from where (or how big) the touch lands.
struct PadTouchSurface: UIViewRepresentable {
    let layout: PadGridLayout
    let onDown: (Int, Double, Double) -> Void
    let onMove: (Int, Double, Double) -> Void
    let onUp: (Int) -> Void

    func makeUIView(context: Context) -> PadTouchView {
        let v = PadTouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: PadTouchView, context: Context) {
        v.layout = layout
        v.onDown = onDown
        v.onMove = onMove
        v.onUp = onUp
    }
}

final class PadTouchView: UIView {
    var layout = PadGridLayout(size: .zero)
    var onDown: (Int, Double, Double) -> Void = { _, _, _ in }
    var onMove: (Int, Double, Double) -> Void = { _, _, _ in }
    var onUp: (Int) -> Void = { _ in }
    private var owners: [ObjectIdentifier: Int] = [:]

    private func measure(_ t: UITouch, in g: Int) -> (y: Double, size: Double) {
        let p = t.location(in: self)
        let cell = layout.cells[g]
        let y = Double(min(1, max(0, (p.y - cell.minY) / max(cell.height, 1))))
        let size = Double(min(1, max(0, (t.majorRadius - 8) / 30)))
        return (y, size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let g = layout.hit(t.location(in: self)) else { continue }
            owners[ObjectIdentifier(t)] = g
            let m = measure(t, in: g)
            onDown(g, m.y, m.size)
        }
    }

    /// Finger drift / size change while held → pressure (note repeat velocity).
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let g = owners[ObjectIdentifier(t)] else { continue }
            let m = measure(t, in: g)
            onMove(g, m.y, m.size)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            if let g = owners.removeValue(forKey: ObjectIdentifier(t)) { onUp(g) }
        }
    }
}
#endif
