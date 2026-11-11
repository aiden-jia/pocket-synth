import ChordTheory
import SamplerCore
import SwiftUI

// Phase 6 sampler extras: track arpeggiator, audio tracks, clip program, auto-sampler and
// retrospective record.

// MARK: - Arpeggiator

/// Arpeggiator settings for the selected note track (SAMPLER_SPEC §6).
struct ArpMenu: View {
    @Bindable var sampler: SamplerController

    var body: some View {
        let i = sampler.trackIndex
        let a = sampler.track.arp
        Menu("Arpeggiator: \(a.summary)") {
            Toggle("On", isOn: Binding(get: { a.on }, set: { v in sampler.setTrackArp(i) { $0.on = v } }))
            Picker("Pattern", selection: Binding(get: { a.mode }, set: { v in sampler.setTrackArp(i) { $0.mode = v } })) {
                ForEach(ArpMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Rate", selection: Binding(get: { a.rate }, set: { v in sampler.setTrackArp(i) { $0.rate = v } })) {
                ForEach(RepeatRate.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Octaves", selection: Binding(get: { a.octaves }, set: { v in sampler.setTrackArp(i) { $0.octaves = v } })) {
                ForEach(1...4, id: \.self) { Text("\($0) octave\($0 == 1 ? "" : "s")").tag($0) }
            }
            Picker("Gate", selection: Binding(get: { Int((a.gate * 100).rounded()) }, set: { v in sampler.setTrackArp(i) { $0.gate = Double(v) / 100 } })) {
                ForEach([10, 25, 50, 75, 100], id: \.self) { Text("Gate \($0)%").tag($0) }
            }
            Toggle("Latch", isOn: Binding(get: { a.latch }, set: { v in sampler.setTrackArp(i) { $0.latch = v } }))
        }
    }
}

// MARK: - Audio tracks

/// Replaces the note editors on an audio track: what plays, from where, and recording.
struct AudioTrackView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController

    var body: some View {
        let i = sampler.trackIndex
        let seq = sampler.sequence
        let clip = sampler.track.audio
        let info = sampler.project.sample(clip?.sampleID)
        let recording = sampler.audioTakeTrack == i
        VStack(alignment: .leading, spacing: 10) {
            regionBar(seq: seq, clip: clip, info: info, recording: recording)
                .frame(height: 64)
            HStack(spacing: 8) {
                Menu {
                    ForEach(sampler.visibleSamples) { s in
                        Button(s.name) { sampler.setAudioClip(i, AudioClip(sampleID: s.id, startTick: clip?.startTick ?? 0)) }
                    }
                    if clip != nil {
                        Divider()
                        Button("Remove audio", systemImage: "xmark", role: .destructive) { sampler.setAudioClip(i, nil) }
                    }
                } label: {
                    Label(info?.name ?? "Choose audio…", systemImage: "waveform").font(.callout)
                }
                Spacer()
                if let clip {
                    Text("START").font(.caption2.bold()).foregroundStyle(Theme.dim)
                    ToolButton(icon: "minus") { move(clip, by: -seq.ticksPerBar) }
                    Text("BAR \(clip.startTick / seq.ticksPerBar + 1)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                    ToolButton(icon: "plus") { move(clip, by: seq.ticksPerBar) }
                }
            }
            if let clip {
                ParamSlider("Level", clip.level, 0...2, { String(format: "%.0f%%", $0 * 100) }) { v in
                    var c = clip
                    c.level = v
                    sampler.setAudioClip(i, c)
                }
            }
            Text(recording ? "Recording into this track… press record again (or stop) to finish."
                 : "Press record to record the Sample view's source (mic or a resample) into this track while the sequence plays. "
                 + "The audio plays from its start bar at its own speed and is cut where the sequence ends.")
                .font(.caption)
                .foregroundStyle(recording ? Color.red : Theme.dim)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func move(_ clip: AudioClip, by ticks: Int) {
        var c = clip
        c.startTick = max(0, min(sampler.sequence.lengthTicks - sampler.sequence.ticksPerBar, c.startTick + ticks))
        sampler.setAudioClip(sampler.trackIndex, c)
    }

    /// The sequence as a strip of bars with the region drawn where it plays.
    private func regionBar(seq: PadSequence, clip: AudioClip?, info: SampleInfo?, recording: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let len = Double(seq.lengthTicks)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                ForEach(0..<min(seq.bars, 64), id: \.self) { b in
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                        .offset(x: w * Double(b * seq.ticksPerBar) / len)
                }
                if let clip, let info {
                    let x = w * Double(clip.startTick) / len
                    let ticks = info.duration * model.bpm / 60 * Double(PPQN.ticks)
                    let width = min(w - x, w * ticks / len)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Text(info.name).font(.caption.bold()).foregroundStyle(Theme.text).padding(.leading, 6).lineLimit(1)
                        }
                        .frame(width: max(8, width), height: geo.size.height - 12)
                        .offset(x: x, y: 6)
                } else {
                    Text(recording ? "● REC" : "No audio on this track")
                        .font(.caption).foregroundStyle(recording ? Color.red : Theme.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if sampler.transport.playing, sampler.transport.position >= 0 {
                    Rectangle().fill(recording ? Color.red : Theme.text).frame(width: 1.5)
                        .offset(x: w * sampler.transport.position / len)
                }
            }
        }
    }
}

// MARK: - Clip program

struct ClipEditView: View {
    let model: AppModel
    @Bindable var sampler: SamplerController

    var body: some View {
        let c = sampler.project.clips
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Launch", selection: Binding(get: { c.quantize }, set: { v in sampler.updateClips { $0.quantize = v } })) {
                        ForEach(ClipQuantize.allCases, id: \.self) { Text("Launch: \($0.label)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.text)
                    .fixedSize()
                    Spacer()
                    Button("Stop", systemImage: "stop.fill") { sampler.stopClips() }
                        .font(.caption).buttonStyle(.bordered).tint(Theme.warm).fixedSize()
                    Button("New track", systemImage: "plus.rectangle.on.rectangle") { sampler.addTrack(.clip) }
                        .font(.caption).buttonStyle(.bordered).tint(Theme.accent).fixedSize()
                }
                .lineLimit(1)
                Text("Pads in one column (1, 5, 9, 13 …) take turns: starting one stops the other. "
                     + "Loops are played over their length in beats, so they follow the tempo (the pitch follows too).")
                    .font(.caption).foregroundStyle(Theme.dim)
                ForEach(0..<ClipProgram.count, id: \.self) { row($0, c.pads[$0]) }
            }
            .padding(14)
        }
    }

    private func row(_ i: Int, _ pad: ClipPad) -> some View {
        let info = sampler.project.sample(pad.sampleID)
        let state = sampler.clipStates[i]
        return HStack(spacing: 8) {
            Text("\(i + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 24)
                .foregroundStyle(state == .playing ? Theme.background : Theme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(state == .playing ? Theme.accent : state == .queued ? Theme.warm.opacity(0.5) : Theme.panel))
            Menu {
                ForEach(sampler.visibleSamples) { s in
                    Button(s.name) {
                        sampler.updateClips { $0.pads[i] = ClipPad(sampleID: s.id) ; $0.pads[i].beats = ClipPad.guessBeats(seconds: s.duration, bpm: model.bpm) }
                    }
                }
                if pad.sampleID != nil {
                    Divider()
                    Button("Clear", role: .destructive) { sampler.updateClips { $0.pads[i] = ClipPad() } }
                }
            } label: {
                Text(info?.name ?? "Empty").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(info == nil ? Theme.dim : Theme.text)
            if info != nil {
                Picker("Mode", selection: Binding(get: { pad.mode }, set: { v in sampler.updateClips { $0.pads[i].mode = v } })) {
                    ForEach(ClipMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.text)
                Picker("Beats", selection: Binding(get: { pad.beats }, set: { v in sampler.updateClips { $0.pads[i].beats = v } })) {
                    Text("Own speed").tag(0.0)
                    ForEach([1.0, 2, 4, 8, 16, 32, 64], id: \.self) { Text("\(Int($0)) beats").tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.text)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
    }
}

// MARK: - Auto-sampler

struct AutoSamplerSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var s = AppModel.AutoSampleSettings()
    @State private var midi = false
    @State private var channel = 1

    var body: some View {
        NavigationStack {
            Form {
                if let p = model.autoSampling {
                    Section("Recording") {
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total))) {
                            Text("Take \(min(p.done + 1, p.total)) of \(p.total)")
                        }
                        Button("Stop", role: .destructive) { model.cancelAutoSample() }
                    }
                } else {
                    Section("Source") {
                        Picker("Play", selection: $midi) {
                            Text("The synth panel's sound").tag(false)
                            Text("External gear (MIDI out → audio in)").tag(true)
                        }
                        if midi {
                            Stepper("MIDI channel \(channel)", value: $channel, in: 1...16)
                        }
                        TextField("Name", text: $s.name)
                    }
                    Section("Notes") {
                        Stepper("From \(PitchName.noteName(s.lowNote))", value: $s.lowNote, in: 0...s.highNote)
                        Stepper("To \(PitchName.noteName(s.highNote))", value: $s.highNote, in: s.lowNote...127)
                        Stepper("Every \(s.step) semitone\(s.step == 1 ? "" : "s")", value: $s.step, in: 1...12)
                        Stepper("\(s.layers) velocity layer\(s.layers == 1 ? "" : "s")", value: $s.layers, in: 1...4)
                    }
                    Section("Timing") {
                        Stepper(String(format: "Hold %.1f s", s.holdSeconds), value: $s.holdSeconds, in: 0.2...8, step: 0.1)
                        Stepper(String(format: "Release tail %.1f s", s.releaseSeconds), value: $s.releaseSeconds, in: 0...8, step: 0.1)
                    }
                    Section {
                        Text("\(s.notes.count * s.velocities.count) takes, about \(Int(s.seconds.rounded())) s. "
                             + "Don't play while it records.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Auto-sample")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        s.source = midi ? .midi(channel: channel) : .synth
                        model.startAutoSample(s)
                    }
                    .disabled(model.autoSampling != nil || s.notes.isEmpty)
                }
            }
        }
    }
}

// MARK: - Retrospective record

/// Pad-column key: capture the last 30 s of playing as a new sequence.
struct RetroKey: View {
    let model: AppModel

    var body: some View {
        Menu {
            Section("\(model.retroHits) hits in the last 30 s") {
                Button("Capture as a new sequence", systemImage: "clock.arrow.circlepath") { model.captureRetro(quantize: false) }
                Button("Capture, quantized", systemImage: "wand.and.stars") { model.captureRetro(quantize: true) }
            }
        } label: {
            KeyLabel(label: "RETRO", on: model.retroHits > 0, tint: Theme.accent)
        }
    }
}
