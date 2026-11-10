import SamplerCore
import SwiftUI

/// Song mode (SAMPLER_SPEC §7): sequences in order with repeats, played straight or
/// looped, and flattened into one sequence on request.
struct SongView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController
    @State private var showExport = false

    var body: some View {
        let song = sampler.project.song
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    if sampler.songIndex != nil { sampler.stop() } else { sampler.playSong() }
                } label: {
                    ToolLabel(text: sampler.songIndex != nil ? "STOP SONG" : "PLAY SONG",
                              icon: sampler.songIndex != nil ? "stop.fill" : "play.fill", on: sampler.songIndex != nil)
                }
                .buttonStyle(.plain)
                .disabled(song.steps.isEmpty)
                ToolButton(icon: "repeat", on: song.loop) { sampler.editSong("Loop") { $0.loop.toggle() } }
                Menu {
                    ForEach(sampler.project.sequences.indices, id: \.self) { i in
                        Button(sampler.project.sequences[i].name) { sampler.addSongStep(sequence: i) }
                    }
                } label: {
                    ToolLabel(text: "ADD STEP", icon: "plus")
                }
                Spacer()
                Menu {
                    Button("Convert song to sequence", systemImage: "rectangle.stack.badge.plus") { sampler.convertSongToSequence() }
                        .disabled(song.steps.isEmpty)
                    Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                } label: {
                    ToolLabel(text: nil, icon: "ellipsis")
                }
            }
            if song.steps.isEmpty {
                EmptyHint(text: "Add sequences as steps.\nEach plays its repeats, then the next one starts on time.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(song.steps.enumerated()), id: \.element.id) { i, step in
                            stepRow(i, step)
                        }
                    }
                }
            }
        }
        .padding(12)
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
    }

    /// Which playlist entry (step, pass) is playing.
    private var playing: (step: Int, pass: Int)? {
        guard let idx = sampler.songIndex else { return nil }
        var n = 0
        for (i, s) in sampler.project.song.steps.enumerated() {
            if idx < n + s.repeats { return (i, idx - n + 1) }
            n += s.repeats
        }
        return nil
    }

    private func stepRow(_ i: Int, _ step: SongStep) -> some View {
        let seqs = sampler.project.sequences
        let name = seqs.indices.contains(step.sequence) ? seqs[step.sequence].name : "Missing"
        let bars = seqs.indices.contains(step.sequence) ? seqs[step.sequence].bars : 0
        let now = playing?.step == i
        return HStack(spacing: 8) {
            Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 20)
            Menu {
                ForEach(seqs.indices, id: \.self) { s in
                    Button(seqs[s].name) { sampler.editSong("Step sequence") { $0.steps[i].sequence = s } }
                }
            } label: {
                Text(name).font(.callout.bold()).foregroundStyle(Theme.text).lineLimit(1)
            }
            Text("\(bars) bar\(bars == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.dim)
            Spacer()
            if now, let p = playing { Text("▶ \(p.pass)/\(step.repeats)").font(.caption.monospacedDigit().bold()).foregroundStyle(Theme.accent) }
            ToolButton(icon: "minus") { sampler.editSong("Repeats") { $0.steps[i].repeats = max(1, $0.steps[i].repeats - 1) } }
            Text("×\(step.repeats)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text).frame(width: 30)
            ToolButton(icon: "plus") { sampler.editSong("Repeats") { $0.steps[i].repeats = min(99, $0.steps[i].repeats + 1) } }
            ToolButton(icon: "arrow.up") {
                guard i > 0 else { return }
                sampler.editSong("Move step") { $0.steps.swapAt(i, i - 1) }
            }
            ToolButton(icon: "trash") { sampler.editSong("Delete step") { $0.steps.remove(at: i) } }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(now ? Theme.accent.opacity(0.18) : Theme.raised))
    }
}

/// Export (SAMPLER_SPEC §10): mixdown, stems or a MIDI file of the sequence or song.
struct ExportSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AppModel.ExportKind = .mixdown
    @State private var source: AppModel.ExportSource = .sequence
    @State private var bitDepth = 24

    var body: some View {
        NavigationStack {
            Form {
                Picker("Export", selection: $kind) {
                    ForEach(AppModel.ExportKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("What", selection: $source) {
                    ForEach(AppModel.ExportSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if kind != .midi {
                    Picker("Format", selection: $bitDepth) {
                        Text("WAV 16-bit").tag(16)
                        Text("WAV 24-bit").tag(24)
                        Text("WAV 32-bit float").tag(32)
                    }
                }
                Section {
                    Button {
                        Task { await model.export(kind, source: source, bitDepth: bitDepth) }
                    } label: {
                        HStack {
                            Text(model.exporting ? "Exporting…" : "Export")
                            if model.exporting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.exporting)
                } footer: {
                    Text("Files go to Files › On My iPhone › PocketSynth › Exports. Live synth playing and the looper aren't included; synth tracks are.")
                }
                if !model.exportedFiles.isEmpty, !model.exporting {
                    Section("Exported") {
                        ForEach(model.exportedFiles, id: \.self) { url in
                            ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
