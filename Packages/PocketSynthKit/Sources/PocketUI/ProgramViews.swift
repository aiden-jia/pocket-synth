import ChordTheory
import SamplerCore
import SwiftUI

/// Program edit: the drum program's selected pad, or a keygroup program.
struct ProgramScreen: View {
    let model: AppModel
    @Bindable var sampler: SamplerController
    @State private var tab = Tab.drum
    @State private var keygroup = 0

    enum Tab: String, CaseIterable { case drum = "Drum pads", keys = "Keygroups" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Program", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            switch tab {
            case .drum: PadEditView(model: model, sampler: sampler)
            case .keys: KeygroupEditView(model: model, sampler: sampler, index: $keygroup)
            }
        }
        .onAppear {
            if case .keygroup(let i) = sampler.track.program { tab = .keys; keygroup = i }
        }
    }
}

struct KeygroupEditView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController
    @Binding var index: Int
    @State private var picking = false

    var body: some View {
        let kgs = sampler.project.keygroups
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if !kgs.isEmpty {
                        Picker("Keygroup", selection: $index) {
                            ForEach(kgs.indices, id: \.self) { Text("\($0 + 1) \(kgs[$0].name)").tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.text)
                    }
                    Spacer()
                    Button("Auto-map samples…", systemImage: "pianokeys") { picking = true }
                        .font(.caption).buttonStyle(.bordered).tint(Theme.accent)
                        .disabled(kgs.count >= KeygroupProgram.maxPrograms)
                }
                if kgs.indices.contains(index) {
                    editor(kgs[index])
                } else {
                    EmptyHint(text: "A keygroup plays samples across the keyboard.\nAuto-map finds each sample's pitch and spreads them out.")
                        .frame(height: 160)
                }
            }
            .padding(14)
        }
        .sheet(isPresented: $picking) {
            SamplePicker(samples: sampler.visibleSamples) { ids in
                Task {
                    if let i = await model.autoMapKeygroup(ids, name: "Keys \(kgs.count + 1)") { index = i }
                }
            }
        }
    }

    @ViewBuilder
    private func editor(_ k: KeygroupProgram) -> some View {
        let i = index
        HStack(spacing: 12) {
            Toggle("Mono", isOn: Binding(get: { k.mono }, set: { v in sampler.updateKeygroup(i) { $0.mono = v } })).fixedSize()
            Spacer()
            Button("Play it on a new track", systemImage: "plus.rectangle.on.rectangle") { sampler.addTrack(.keygroup(i)) }
                .font(.caption)
        }
        .foregroundStyle(Theme.text)
        ParamSlider("Level", k.level, 0...2, { String(format: "%.0f%%", $0 * 100) }) { v in
            sampler.updateKeygroup(i, key: "kg-level-\(i)") { $0.level = v }
        }
        ParamSlider("Attack", k.envelope.attackMs, 0...2000, { "\(Int($0)) ms" }) { v in
            sampler.updateKeygroup(i, key: "kg-attack-\(i)") { $0.envelope.attackMs = v }
        }
        ParamSlider("Release", k.envelope.releaseMs, 1...5000, { "\(Int($0)) ms" }) { v in
            sampler.updateKeygroup(i, key: "kg-release-\(i)") { $0.envelope.releaseMs = v }
        }
        Text("ZONES").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
        ForEach(k.zones.indices, id: \.self) { z in zoneRow(k.zones[z], z) }
        if k.zones.count < KeygroupProgram.maxZones {
            Menu {
                ForEach(sampler.visibleSamples) { s in
                    Button(s.name) { sampler.updateKeygroup(i) { $0.zones.append(KeygroupZone(sample: s.id)) } }
                }
            } label: {
                Label("Add zone", systemImage: "plus").font(.callout)
            }
        }
    }

    private func zoneRow(_ zone: KeygroupZone, _ z: Int) -> some View {
        let i = index
        let name = sampler.project.sample(zone.primarySample)?.name ?? "—"
        func step(_ label: String, _ value: Int, _ set: @escaping (inout KeygroupZone, Int) -> Void) -> some View {
            HStack(spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(Theme.dim)
                ToolButton(icon: "minus") { sampler.updateKeygroup(i) { set(&$0.zones[z], value - 1) } }
                Text(PitchName.noteName(value)).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text).frame(width: 34)
                ToolButton(icon: "plus") { sampler.updateKeygroup(i) { set(&$0.zones[z], value + 1) } }
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.callout.bold()).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                ToolButton(icon: "trash") { sampler.updateKeygroup(i) { $0.zones.remove(at: z) } }
            }
            HStack(spacing: 10) {
                step("LOW", zone.lowNote) { $0.lowNote = max(0, min($0.highNote, $1)) }
                step("HIGH", zone.highNote) { $0.highNote = min(127, max($0.lowNote, $1)) }
                step("ROOT", zone.rootNote) { $0.rootNote = max(0, min(127, $1)) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
    }
}

/// Multi-select from the sample pool.
struct SamplePicker: View {
    let samples: [SampleInfo]
    let done: ([SampleID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<SampleID> = []

    var body: some View {
        NavigationStack {
            List(samples) { s in
                Button {
                    if chosen.contains(s.id) { chosen.remove(s.id) } else { chosen.insert(s.id) }
                } label: {
                    HStack {
                        Image(systemName: chosen.contains(s.id) ? "checkmark.circle.fill" : "circle")
                        Text(s.name)
                        Spacer()
                        Text(String(format: "%.2f s", s.duration)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Samples to map")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Map \(chosen.count)") {
                        done(samples.map(\.id).filter(chosen.contains))
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
    }
}
