import SamplerCore
import SwiftUI
import UniformTypeIdentifiers

/// The sampler panel: mode sidebar · active view · pads.
struct SamplerPanelView: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var showQLinks = false

    var body: some View {
        let s = model.sampler
        GeometryReader { geo in
            HStack(spacing: 12) {
                SamplerSidebar(sampler: s, showQLinks: $showQLinks, onImport: { importing = true })
                    .frame(width: 76)
                VStack(spacing: 6) {
                    Group {
                        switch s.view {
                        case .main: SampleBrowserView(model: model, onImport: { importing = true })
                        case .grid: SeqView(model: model, sampler: s)
                        case .sample: SamplingView(model: model)
                        case .edit: SampleEditView(model: model, sampler: s)
                        case .program: ProgramScreen(model: model, sampler: s)
                        case .mixer: MixerScreen(model: model, sampler: s)
                        case .song: SongView(model: model, sampler: s)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                    .clipped()
                    if showQLinks { QLinkStrip(sampler: s).frame(height: 64) }
                }
                PadColumn(sampler: s, model: model)
                    .frame(width: min(geo.size.height - 60, geo.size.width * 0.38))
                    .layoutPriority(1)
            }
            .padding(12)
        }
        .background(Theme.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importSamples(urls) }
        }
        .alert("Import", isPresented: Binding(get: { model.importMessage != nil },
                                              set: { if !$0 { model.importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importMessage ?? "")
        }
    }
}

struct SamplerSidebar: View {
    @Bindable var sampler: SamplerController
    @Binding var showQLinks: Bool
    let onImport: () -> Void

    private func icon(_ v: SamplerView) -> String {
        switch v {
        case .main: "square.grid.3x3"
        case .grid: "rectangle.split.3x3"
        case .song: "list.number"
        case .sample: "mic"
        case .edit: "waveform"
        case .program: "slider.horizontal.3"
        case .mixer: "slider.vertical.3"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SamplerView.allCases, id: \.self) { v in
                Button { sampler.view = v } label: {
                    VStack(spacing: 1) {
                        Image(systemName: icon(v)).font(.system(size: 13))
                        Text(v.label).font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity, minHeight: 33)
                    .foregroundStyle(sampler.view == v ? Theme.background : Theme.text)
                    .background(RoundedRectangle(cornerRadius: 10).fill(sampler.view == v ? Theme.accent : Theme.panel))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { showQLinks.toggle() } label: {
                    Image(systemName: "dial.medium")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(showQLinks ? Theme.background : Theme.text)
                        .background(RoundedRectangle(cornerRadius: 9).fill(showQLinks ? Theme.accent : Theme.raised))
                }
                .buttonStyle(.plain)
                Button(action: onImport) {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raised))
                }
                .buttonStyle(.plain)
                Button { sampler.stopAll() } label: {
                    Label("Silence", systemImage: "speaker.slash.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raised))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.text)
        }
    }
}

// MARK: - Main: selected pad + sample pool

struct SampleBrowserView: View {
    let model: AppModel
    let onImport: () -> Void

    var body: some View {
        let s = model.sampler
        let pad = s.selected
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(PadAddress.name(s.selectedPad))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                if let info = s.project.sample(pad.primarySample) {
                    Text(info.name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Text(String(format: "%.2f s", info.duration)).font(.caption).foregroundStyle(Theme.dim)
                } else {
                    Text("Empty pad").font(.headline).foregroundStyle(Theme.dim)
                }
                Spacer()
            }
            Text("SAMPLES — tap one to put it on \(PadAddress.name(s.selectedPad))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)

            if s.project.samples.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "waveform.badge.plus").font(.system(size: 34)).foregroundStyle(Theme.dim)
                    Text("Import WAV, AIFF, MP3 or M4A files.\nThey land on the selected pad and the empty pads after it.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(Theme.dim)
                    Button("Import samples", action: onImport).buttonStyle(.borderedProminent).tint(Theme.accent)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(s.project.samples) { info in
                            SampleRow(info: info,
                                      onPad: pad.primarySample == info.id,
                                      missing: model.missingSamples.contains(info.id),
                                      assign: { s.assign(info.id, to: s.selectedPad) },
                                      delete: { model.deleteSample(info.id) })
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

struct SampleRow: View {
    let info: SampleInfo
    let onPad: Bool
    let missing: Bool
    let assign: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: missing ? "exclamationmark.triangle" : "waveform")
                .foregroundStyle(missing ? Theme.warm : Theme.accent)
            Text(info.name).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Text(String(format: "%.2f s", info.duration)).font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
            Menu {
                Button("Delete sample", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 26)
            }
            .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(onPad ? Theme.accent.opacity(0.18) : Theme.raised))
        .contentShape(Rectangle())
        .onTapGesture(perform: assign)
    }
}
