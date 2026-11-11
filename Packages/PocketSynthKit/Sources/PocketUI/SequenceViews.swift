import ChordTheory
import SamplerCore
import SwiftUI

/// The sequencer screen: one toolbar (sequence, track, editor, Timing Correct, more) over
/// the Grid, List or Step editor (SAMPLER_SPEC §6).
struct SeqView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController
    @State private var page = 0
    @State private var confirmClear = false
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            switch sampler.seqEditor {
            case .grid: GridEditorView(model: model, sampler: sampler, page: $page)
            case .list: ListEditorView(sampler: sampler)
            case .step: StepEditorView(sampler: sampler)
            }
        }
        .padding(10)
        .confirmationDialog("Clear every note on this track?", isPresented: $confirmClear) {
            Button("Clear track", role: .destructive) { sampler.clearTrack() }
        }
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
    }

    private var toolbar: some View {
        let seq = sampler.sequence
        let tc = sampler.project.timingCorrect
        return HStack(spacing: 5) {
            Menu {
                ForEach(0..<min(sampler.project.sequences.count + 1, SamplerProject.maxSequences), id: \.self) { i in
                    Button(i < sampler.project.sequences.count ? sampler.project.sequences[i].name : "New sequence") {
                        sampler.selectSequence(i)
                        page = 0
                    }
                }
                Divider()
                Toggle("Next Sequence (switch at the end)", isOn: $sampler.nextSequenceMode)
                Toggle("…at the next bar instead", isOn: $sampler.nextSequenceAtBar)
            } label: {
                ToolLabel(text: String(format: "S%02d", sampler.project.currentSequence + 1)
                    + (sampler.queuedSequence.map { String(format: "→%02d", $0 + 1) } ?? ""), icon: "chevron.down")
            }
            TrackMenu(sampler: sampler)
            Picker("Editor", selection: $sampler.seqEditor) {
                Image(systemName: "rectangle.split.3x3").tag(SeqEditor.grid)
                Image(systemName: "list.bullet").tag(SeqEditor.list)
                Image(systemName: "square.grid.4x3.fill").tag(SeqEditor.step)
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
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
                ToolLabel(text: tc.value.label, icon: "chevron.down", on: tc.onInput)
            }
            Menu {
                Section("Length: \(seq.bars) bar\(seq.bars == 1 ? "" : "s")") {
                    Button("Add a bar", systemImage: "plus") { sampler.setBars(seq.bars + 1) }
                    Button("Remove a bar", systemImage: "minus") { sampler.setBars(seq.bars - 1) }
                    Button("Double length", systemImage: "square.on.square") { sampler.doubleSequence() }
                    Toggle("Loop", isOn: Binding(get: { seq.loop }, set: { sampler.setLoop($0) }))
                }
                Section("Automation") {
                    Picker("Automation", selection: $sampler.automationMode) {
                        ForEach(AutomationMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Button("Clear this track's automation", systemImage: "scribble") { sampler.clearAutomation() }
                }
                Divider()
                Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                Button("Clear track…", systemImage: "trash", role: .destructive) { confirmClear = true }
            } label: {
                ToolLabel(text: nil, icon: "ellipsis")
            }
            Spacer(minLength: 0)
            if sampler.seqEditor == .grid {
                let pages = GridGeometry.pages(seq)
                if pages > 1 {
                    ToolButton(icon: "chevron.left") { page = max(0, page - 1) }
                    ToolButton(icon: "chevron.right") { page = min(pages - 1, page + 1) }
                }
            }
        }
        .frame(height: 28)
    }
}

/// Track picker and track settings (program, mute, solo).
struct TrackMenu: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        let t = sampler.track
        Menu {
            Section("Tracks") {
                ForEach(sampler.sequence.tracks.indices, id: \.self) { i in
                    let tr = sampler.sequence.tracks[i]
                    Button {
                        sampler.selectTrack(i)
                    } label: {
                        Label("\(i + 1) \(tr.name) · \(tr.program.label)" + (tr.mute ? " · M" : "") + (tr.solo ? " · S" : ""),
                              systemImage: i == sampler.trackIndex ? "checkmark" : "")
                    }
                }
            }
            Section("This track") {
                Toggle("Mute", isOn: Binding(get: { t.mute }, set: { sampler.setTrackMute($0) }))
                Toggle("Solo", isOn: Binding(get: { t.solo }, set: { sampler.setTrackSolo(sampler.trackIndex, $0) }))
                Menu("Program") { programButtons { sampler.setTrackProgram(sampler.trackIndex, $0) } }
                if sampler.sequence.tracks.count > 1 {
                    Button("Delete track", systemImage: "trash", role: .destructive) { sampler.deleteTrack(sampler.trackIndex) }
                }
            }
            Menu("New track") { programButtons { sampler.addTrack($0) } }
        } label: {
            ToolLabel(text: "T\(sampler.trackIndex + 1)·\(t.program.shortLabel)", icon: "chevron.down", on: t.solo)
        }
    }

    @ViewBuilder
    private func programButtons(_ pick: @escaping (TrackProgram) -> Void) -> some View {
        Button("Drum (pads)") { pick(.drum) }
        ForEach(sampler.project.keygroups.indices, id: \.self) { i in
            Button("Keygroup: \(sampler.project.keygroups[i].name)") { pick(.keygroup(i)) }
        }
        Button("Synth (the synth's sound)") { pick(.synth) }
        Menu("MIDI out") {
            ForEach(1...16, id: \.self) { ch in Button("Channel \(ch)") { pick(.midi(channel: ch)) } }
        }
    }
}

// MARK: - List editor

/// Event list (SAMPLER_SPEC §6): time, pad or note, velocity, length. Tap to select;
/// the selected event can be nudged, re-velocitied or deleted.
struct ListEditorView: View {
    @Bindable var sampler: SamplerController
    @State private var selected: UInt32?

    var body: some View {
        let t = sampler.track
        let bpb = sampler.sequence.beatsPerBar
        VStack(spacing: 6) {
            HStack {
                Text("TIME").frame(width: 84, alignment: .leading)
                Text(t.program.isNotes ? "NOTE" : "PAD").frame(width: 110, alignment: .leading)
                Text("VEL").frame(width: 40, alignment: .trailing)
                Text("LENGTH").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.dim)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(t.events) { e in
                            row(e, bpb: bpb, notes: t.program.isNotes)
                                .id(e.id)
                                .onTapGesture { selected = selected == e.id ? nil : e.id }
                        }
                        if t.events.isEmpty {
                            EmptyHint(text: "No notes on this track yet.\nRecord, or tap cells in Grid / Step.").frame(height: 120)
                        }
                    }
                }
                .onChange(of: selected) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
            }
            if let id = selected, let e = t.events.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                    ToolButton(icon: "chevron.left") { sampler.nudgeEvent(id, steps: -1) }
                    ToolButton(icon: "chevron.right") { sampler.nudgeEvent(id, steps: 1) }
                    Text("VEL").font(.caption2.bold()).foregroundStyle(Theme.dim)
                    ToolButton(icon: "minus") { sampler.setVelocity(id, e.velocity - 8) }
                    Text("\(e.velocity)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                    ToolButton(icon: "plus") { sampler.setVelocity(id, e.velocity + 8) }
                    Spacer()
                    ToolButton(icon: "trash") { sampler.deleteEvent(id); selected = nil }
                }
            }
        }
    }

    private func row(_ e: NoteEvent, bpb: Int, notes: Bool) -> some View {
        let beat = e.tick / PPQN.ticks
        let time = String(format: "%d.%d.%03d", beat / bpb + 1, beat % bpb + 1, e.tick % PPQN.ticks)
        let what: String = notes ? PitchName.noteName(e.pad)
            : PadAddress.name(e.pad) + " " + (sampler.project.sample(sampler.project.program.pads[e.pad].primarySample)?.name ?? "")
        return HStack {
            Text(time).frame(width: 84, alignment: .leading)
            Text(what).lineLimit(1).frame(width: 110, alignment: .leading)
            Text("\(e.velocity)").frame(width: 40, alignment: .trailing)
            Text("\(e.length)").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(e.id == selected ? Theme.accent.opacity(0.22) : Theme.raised))
    }
}

// MARK: - Step editor

/// Step sequencer (SAMPLER_SPEC §6): 16 steps of the selected lane; tap a step here or
/// hit pad 1–16 to toggle it.
struct StepEditorView: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        let lane = sampler.stepLane
        let notes = sampler.track.program.isNotes
        let pages = sampler.stepPages
        let page = min(sampler.stepPage, pages - 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(notes ? PitchName.noteName(lane) : PadAddress.name(lane))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                if !notes, let name = sampler.project.sample(sampler.selected.primarySample)?.name {
                    Text(name).font(.callout).foregroundStyle(Theme.text).lineLimit(1)
                }
                if notes {
                    ToolButton(icon: "minus") { sampler.stepNote = max(0, sampler.stepNote - 1) }
                    ToolButton(icon: "plus") { sampler.stepNote = min(127, sampler.stepNote + 1) }
                }
                Spacer()
                ToolButton(icon: "chevron.left") { sampler.stepPage = max(0, page - 1) }
                Text("BAR \(page + 1)/\(pages)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
                ToolButton(icon: "chevron.right") { sampler.stepPage = min(pages - 1, page + 1) }
            }
            Text(notes ? "Pick the note with − / + or by playing a pad in another view. Pads 1–16 toggle steps here."
                       : "Hit a pad in another view to pick its lane. Here pads 1–16 toggle steps.")
                .font(.caption).foregroundStyle(Theme.dim)
            let playStep = playingStep(page: page)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<SamplerController.stepsPerPage, id: \.self) { i in
                    let on = sampler.stepIsOn(i)
                    Button { sampler.toggleStepCell(i) } label: {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(on ? Theme.background : Theme.dim)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.accent : (i % 4 == 0 ? Theme.raised : Theme.panel)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.text, lineWidth: playStep == i ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func playingStep(page: Int) -> Int? {
        guard sampler.transport.playing, sampler.transport.position >= 0 else { return nil }
        let step = Int(sampler.transport.position) / sampler.stepTicks
        return step / SamplerController.stepsPerPage == page ? step % SamplerController.stepsPerPage : nil
    }
}
