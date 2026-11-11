import AudioEngine
import ChordTheory
import CoreGraphics
import DSPKit
import Foundation
import Observation
import SamplerCore
import SynthCore

/// App-wide owner of the audio host, engine bridge, both panel controllers and storage.
@MainActor
@Observable
public final class AppModel {
    public enum Panel: String, CaseIterable, Identifiable, Sendable {
        case synth = "Synth"
        case sampler = "Sampler"
        public var id: String { rawValue }
    }

    public var panel: Panel = .synth
    public let synth: SynthController
    public let sampler: SamplerController
    /// Current joystick knob offset in points, for drawing only.
    public var stickOffset: CGVector?
    public private(set) var audioError: String?
    public var importMessage: String?
    /// Samples whose files couldn't be loaded at launch.
    public private(set) var missingSamples: Set<SampleID> = []

    @ObservationIgnored private let host: AudioHost
    @ObservationIgnored private let midi: MIDIManager
    @ObservationIgnored private var controlMap = MIDIControlMap()
    @ObservationIgnored private var liveChannel = -1
    @ObservationIgnored private let bridge: EngineBridge
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var snapTask: Task<Void, Never>?
    /// The chopped sample's audio, copied once for the smart-slice detector (it runs on
    /// every move of the search window).
    @ObservationIgnored private var chopAudio: (id: SampleID, audio: AudioData)?

    // Mic input users: the Sample view (source = mic), Tuner, Mic mode, the MIC vocoder.
    @ObservationIgnored private let inputMonitor = InputMonitor()
    @ObservationIgnored private var samplingUsesMic = false
    @ObservationIgnored private var micWanted = false
    @ObservationIgnored private var synthMicTake = false
    @ObservationIgnored private var tunerSmoother = TunerSmoother()
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var lastHousekeeping = -1.0
    /// Sampler pads lit by engine hits (sequence playback, note repeat).
    let padLights = PadLights()
    static let micSampleID = SampleID("synth-mic-sample")

    // Retrospective record, audio-track takes, auto-sampler (phase 6, sampler)
    @ObservationIgnored private var retro = RetroBuffer()
    /// Hits held in the retrospective buffer (last 30 s).
    public private(set) var retroHits = 0
    @ObservationIgnored private var audioTake: (track: Int, startTick: Double, source: SamplingSource)?
    /// Auto-sampler progress (takes done, total) while it runs.
    public private(set) var autoSampling: (done: Int, total: Int)?
    @ObservationIgnored private var autoSampleTask: Task<Void, Never>?
    @ObservationIgnored private var autoSamplerUsesMic = false
    var micSampleURL: URL { store.directory.appendingPathComponent("mic-sample.wav") }

    // Sampling (SAMPLER_SPEC §4)
    public var sampling = SamplingSettings()
    public private(set) var recorderState: EngineBridge.RecorderState = .idle
    public private(set) var recordedSeconds = 0.0
    public private(set) var meter: Float = 0
    public private(set) var samplingError: String?

    // Sample Edit
    public private(set) var chop: ChopSession?
    /// Smart chop: the detector is looking at a new search window.
    public private(set) var snapSearching = false
    public private(set) var busy: String?

    var sessionURL: URL { store.directory.appendingPathComponent("synth.json") }

    public init(store: ProjectStore = .defaultStore()) {
        self.store = store
        host = AudioHost()
        let sampleRate = host.prepareSession()
        bridge = EngineBridge(sampleRate: sampleRate)
        midi = MIDIManager(engine: bridge.engine)
        let session = SynthSession.load(from: store.directory.appendingPathComponent("synth.json"))
        synth = SynthController(state: session?.state ?? SynthState(),
                                presets: session?.presets ?? Array(repeating: nil, count: 4),
                                gameBest: session?.gameBest ?? [:])
        sampler = SamplerController(project: store.load() ?? SamplerProject())

        let bridge = self.bridge
        synth.send = { bridge.apply($0) }
        sampler.send = { bridge.apply($0) }
        synth.start()
        loadMicSample()
        synth.onMicRecord = { [weak self] in self?.synthMicRecord($0) }
        synth.outputLatency = host.outputLatency
        sampler.onAudioRecord = { [weak self] start, track in self?.audioRecord(start, track: track) }
        loadProjectSamples()
        sampler.start()
        sampler.onChange = { [weak self] in self?.scheduleSave($0) }
        synth.onSessionChange = { [weak self] in self?.scheduleSessionSave($0) }

        bridge.setHostClock(latency: host.outputLatency)
        midi.onTempo = { [weak self] in self?.synth.setTempo($0) }
        midi.onTransport = { [weak self] t in
            switch t {
            case .start, .continue: self?.sampler.play()
            case .stop: self?.sampler.stop()
            }
        }
        midi.onControl = { [weak self] ch, cc, v in
            guard let self, let action = self.controlMap.handle(channel: ch, controller: cc, value: v) else { return }
            self.synth.apply(action)
        }
        midi.inputEnabled = synth.state.midiIn
        midi.start()

        do {
            try host.start(rendering: bridge.engine)
        } catch {
            audioError = "Audio failed to start: \(error.localizedDescription)"
        }
    }

    /// Same clock as `UITouch.timestamp` (seconds since boot).
    public static var now: Double { ProcessInfo.processInfo.systemUptime }

    public func handle(_ event: ControlEvent, at time: Double = AppModel.now) {
        synth.handle(event, at: time)
    }

    /// Called every screen refresh (up to 120 Hz): only what you watch move — playheads
    /// and pad lights — so they track the audio closely. Each update only writes state
    /// when it changed, so views redraw only then. The rest runs ~30×/s in `frame()`.
    public func displayFrame(at time: Double = AppModel.now) {
        sampler.updatePlayhead(bridge.transportTicks)
        padLights.update(bridge, now: time)
        sampler.updateClipStates(bridge.clipStates)
        let step = synth.seqPlaying ? bridge.chordSequencePosition : nil
        if synth.seqPlayhead != step { synth.seqPlayhead = step }
        // Housekeeping at ~30 Hz (a little slack so 60 and 120 Hz screens both hit it).
        if time - lastHousekeeping >= 1.0 / 30 - 0.003 {
            lastHousekeeping = time
            frame()
        }
    }

    /// Called ~30×/s: engine telemetry (recorded hits, looper) and housekeeping.
    public func frame() {
        sampler.poll(hits: bridge.pollRecorded(), position: bridge.transportTicks,
                     enginePlaying: bridge.transportPlaying, sequenceGeneration: bridge.sequenceGeneration)
        synth.updateLooper(bridge.looperReports, length: bridge.looperLength, position: bridge.looperPosition)
        let ch = synth.liveMIDIChannel
        if ch != liveChannel {
            liveChannel = ch
            bridge.setLiveMIDIChannel(ch)
        }
        if midi.inputEnabled != synth.state.midiIn { midi.inputEnabled = synth.state.midiIn }
        synth.tick(at: Self.now)
        retro.add(bridge.pollRetro(time: Self.now), now: Self.now)
        if retro.hitCount != retroHits { retroHits = retro.hitCount }
        updateMicInput()
        frameCount += 1
        if synth.state.mode == .tuner, frameCount % 3 == 0 { updateTuner() }
        pollRecorder()
        bridge.collectGarbage()
    }

    // MARK: Transport (shared by both panels)

    public var bpm: Double { synth.state.bpm }

    public func setBPM(_ bpm: Double) { synth.setTempo(bpm) }

    @ObservationIgnored private var taps: [Double] = []

    /// Tap tempo: the average of the last few taps (a 2 s pause starts over).
    public func tapTempo(at time: Double = AppModel.now) {
        if let last = taps.last, time - last > 2 { taps.removeAll() }
        taps.append(time)
        taps = Array(taps.suffix(5))
        guard taps.count >= 2 else { return }
        let interval = (taps.last! - taps.first!) / Double(taps.count - 1)
        setBPM(60 / interval)
    }

    /// Position as "bar.beat" (1-based); count-in shows as "-1.4" etc.
    public var positionText: String {
        let bpb = sampler.sequence.beatsPerBar
        let beat = sampler.playheadBeat // changes once a beat, not every frame
        if beat < 0 { return "IN \(-beat)" }
        return "\(beat / bpb + 1).\(beat % bpb + 1)"
    }

    // MARK: Samples

    public func peaks(_ id: SampleID?) -> SampleLibrary.Peaks? {
        id.flatMap { bridge.samples.peaks[$0] }
    }

    /// Copies files into the project, decodes them and auto-assigns them to pads.
    public func importSamples(_ urls: [URL]) {
        var infos: [SampleInfo] = []
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = SampleID()
            var dest: URL?
            do {
                dest = try store.importFile(url, id: id)
                let meta = try bridge.samples.load(id: id, from: dest!)
                infos.append(SampleInfo(id: id, name: url.deletingPathExtension().lastPathComponent,
                                        fileName: dest!.lastPathComponent, frames: meta.frames,
                                        sampleRate: meta.sampleRate, channels: meta.channels))
            } catch {
                if let dest { try? FileManager.default.removeItem(at: dest) }
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let pads = sampler.addSamples(infos)
        var message = ""
        if !infos.isEmpty {
            message = "Imported \(infos.count) sample\(infos.count == 1 ? "" : "s")"
            if let first = pads.first { message += " → \(PadAddress.name(first))…" }
        }
        if !failures.isEmpty { message += (message.isEmpty ? "" : "\n") + "Couldn't import:\n" + failures.joined(separator: "\n") }
        importMessage = message.isEmpty ? nil : message
    }

    public func deleteSample(_ id: SampleID) {
        guard !exporting else { return } // the export engine is still playing it
        guard let info = sampler.project.sample(id) else { return }
        sampler.removeSample(id)
        bridge.samples.unload(id)
        store.deleteFile(for: info)
        missingSamples.remove(id)
    }

    private func loadProjectSamples() {
        for info in sampler.project.samples {
            do {
                try bridge.samples.load(id: info.id, from: store.url(for: info))
            } catch {
                missingSamples.insert(info.id)
            }
        }
    }

    private func scheduleSessionSave(_ session: SynthSession) {
        sessionSaveTask?.cancel()
        let url = sessionURL
        sessionSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? session.save(to: url)
        }
    }

    // MARK: Generated samples

    /// Writes audio into the project's Samples folder and loads it. The caller adds it.
    private func addGenerated(_ audio: AudioData, name: String) throws -> SampleInfo {
        try store.prepare()
        let id = SampleID()
        let url = store.samplesDirectory.appendingPathComponent("\(id.rawValue).wav")
        try SampleLibrary.writeWAV(audio.channels, sampleRate: audio.sampleRate, to: url)
        let m = try bridge.samples.load(id: id, from: url)
        return SampleInfo(id: id, name: name, fileName: url.lastPathComponent, frames: m.frames,
                          sampleRate: m.sampleRate, channels: m.channels)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(sampler.project.samples.map(\.name))
        var n = 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func audioData(_ id: SampleID) -> AudioData? {
        bridge.samples.audio(for: id).map { AudioData(channels: $0.channels, sampleRate: $0.sampleRate) }
    }

    // MARK: Looper → sampler

    /// Copies a finished loop into the sample pool and onto the selected pad.
    public func sendLoopToSampler(track: Int) {
        guard let a = bridge.loopAudio(track: track) else {
            importMessage = "Loop \(track + 1) has no audio yet."
            return
        }
        do {
            let info = try addGenerated(AudioData(channels: a.channels, sampleRate: a.sampleRate),
                                        name: uniqueName("Loop"))
            let pads = sampler.addSamples([info])
            importMessage = "\(info.name) → \(pads.first.map(PadAddress.name) ?? "pool")"
        } catch {
            importMessage = "Couldn't save the loop: \(error.localizedDescription)"
        }
    }

    // MARK: Sampling

    /// Changes the source; the mic is only switched on while it's the source.
    public func setSamplingSource(_ source: SamplingSource) async {
        sampling.source = source
        samplingError = nil
        samplingUsesMic = source == .input
        updateMicInput()
        bridge.setMeterSource(source.engineSource)
    }

    // MARK: Mic input (shared)

    private var synthWantsMic: Bool {
        let s = synth.state
        return s.mode == .tuner || s.mode == .mic || s.fxIndex(.vocoder) == 1
    }

    /// Switches the mic on while anything uses it, and off (back to playback-only) after.
    private func updateMicInput() {
        let want = samplingUsesMic || synthWantsMic || autoSamplerUsesMic || audioTakeUsesMic
        guard want != micWanted else { return }
        micWanted = want
        guard want else {
            host.disableInput()
            inputMonitor.clear()
            return
        }
        let bridge = self.bridge, monitor = inputMonitor
        Task {
            let ok = await host.enableInput { l, r, n in
                bridge.pushInput(l, r, frames: n)
                monitor.push(l, r, frames: n)
            }
            if !ok {
                if samplingUsesMic { samplingError = "Microphone access is off. Turn it on in Settings › PocketSynth." }
                if synthWantsMic { synth.notify("MIC ACCESS OFF") }
            }
            if !micWanted { host.disableInput() } // stopped needing it while asking
        }
    }

    // MARK: Retrospective record (SAMPLER_SPEC §4)

    /// Turns the last 30 s of playing into a new sequence.
    public func captureRetro(quantize: Bool) {
        if let name = sampler.captureRetro(retro.events, quantize: quantize) {
            let s = sampler.sequence
            importMessage = "\(name): \(s.bars) bar\(s.bars == 1 ? "" : "s"), \(s.tracks.count) track\(s.tracks.count == 1 ? "" : "s")"
                + (quantize ? ", quantized." : ".")
            retro.clear()
            retroHits = 0
        } else {
            importMessage = "Nothing played in the last 30 seconds."
        }
    }

    // MARK: Audio tracks (SAMPLER_SPEC §6)

    private var audioTakeUsesMic: Bool { audioTake?.source == .input }

    /// A synth loop becomes a sample on a new audio track, starting at bar 1.
    public func sendLoopToAudioTrack(track: Int) {
        guard let a = bridge.loopAudio(track: track) else {
            importMessage = "Loop \(track + 1) has no audio yet."
            return
        }
        guard sampler.canAddAudioTrack else {
            importMessage = "This sequence already has \(PadSequence.maxAudioTracks) audio tracks."
            return
        }
        do {
            let info = try addGenerated(AudioData(channels: a.channels, sampleRate: a.sampleRate), name: uniqueName("Loop"))
            sampler.addAudioTrack(info, startTick: 0)
            importMessage = "\(info.name) is on audio track \(sampler.trackIndex + 1) of \(sampler.sequence.name)."
        } catch {
            importMessage = "Couldn't save the loop: \(error.localizedDescription)"
        }
    }

    /// Record on an audio track: records the Sample view's source while the sequence plays.
    private func audioRecord(_ start: Bool, track: Int) {
        guard start else {
            if audioTake != nil { bridge.stopRecorder() }
            return
        }
        guard recorderState == .idle || recorderState == .done else {
            importMessage = "The recorder is busy."
            return sampler.stop()
        }
        if sampling.source == .input, !host.inputEnabled {
            importMessage = "The mic is off. Pick Mic / input as the source in Sample first (or a resample source)."
            return sampler.stop()
        }
        let seq = sampler.sequence
        let startTick = sampler.playhead
        let remaining = Double(seq.lengthTicks) - startTick
        let seconds = remaining / Double(PPQN.ticks) * 60 / bpm + 1
        audioTake = (track, startTick, sampling.source)
        bridge.armRecorder(source: sampling.source.engineSource, threshold: 0, preRollFrames: 0, maxSeconds: min(600, seconds))
        recorderState = .recording
    }

    /// The take lines up with the sequence: the count-in (and, for the mic, the round-trip
    /// latency) is cut off the front.
    private func finishAudioTake() {
        guard let t = audioTake else { return }
        audioTake = nil
        recorderState = .idle
        guard let take = bridge.takeRecording() else { return }
        let rate = t.source == .input ? host.inputSampleRate : take.sampleRate
        var drop = t.startTick < 0 ? -t.startTick / Double(PPQN.ticks) * 60 / bpm : 0
        if t.source == .input { drop += host.outputLatency + host.inputLatency }
        let first = min(take.channels[0].count, Int(drop * rate))
        let channels = (sampling.stereo ? take.channels : [take.channels[0]]).map { Array($0[first...]) }
        guard (channels.first?.count ?? 0) > Int(0.05 * rate) else {
            importMessage = "The take was too short."
            return
        }
        do {
            let info = try addGenerated(AudioData(channels: channels, sampleRate: rate), name: uniqueName("Audio"))
            sampler.finishAudioTake(track: t.track, sample: info, startTick: max(0, Int(t.startTick.rounded())))
        } catch {
            importMessage = "Couldn't save the take: \(error.localizedDescription)"
        }
    }

    // MARK: Auto-sampler (SAMPLER_SPEC §3.2)

    public struct AutoSampleSettings: Equatable, Sendable {
        public enum Source: Hashable, Sendable { case synth, midi(channel: Int) }
        public var source: Source = .synth
        public var lowNote = 36
        public var highNote = 84
        /// Semitones between sampled notes.
        public var step = 3
        /// Velocity layers, 1…4.
        public var layers = 1
        public var holdSeconds = 1.5
        public var releaseSeconds = 0.8
        public var name = "Auto"
        public init() {}

        public var notes: [Int] { Array(stride(from: lowNote, through: max(lowNote, highNote), by: max(1, step))) }
        public var velocities: [Int] { (1...max(1, min(4, layers))).map { Int((127.0 * Double($0) / Double(max(1, min(4, layers)))).rounded()) } }
        public var seconds: Double { Double(notes.count * velocities.count) * (holdSeconds + releaseSeconds + 0.15) }
    }

    /// Plays each note × velocity on the synth (or MIDI out), records it, and builds a
    /// keygroup from the takes.
    public func startAutoSample(_ s: AutoSampleSettings) {
        guard autoSampling == nil, recorderState == .idle || recorderState == .done else {
            importMessage = "The recorder is busy."
            return
        }
        guard sampler.project.keygroups.count < KeygroupProgram.maxPrograms else {
            importMessage = "All \(KeygroupProgram.maxPrograms) keygroups are in use."
            return
        }
        let jobs = s.notes.flatMap { n in s.velocities.map { (note: n, velocity: $0) } }
        autoSampling = (0, jobs.count)
        if case .midi = s.source {
            autoSamplerUsesMic = true
            updateMicInput()
        }
        autoSampleTask = Task { await runAutoSample(s, jobs: jobs) }
    }

    public func cancelAutoSample() { autoSampleTask?.cancel() }

    private func runAutoSample(_ s: AutoSampleSettings, jobs: [(note: Int, velocity: Int)]) async {
        defer {
            autoSampling = nil
            autoSamplerUsesMic = false
            bridge.discardRecording()
        }
        let program: TrackProgram
        let source: SamplingSource
        switch s.source {
        case .synth:
            program = .synth
            source = .synth
        case .midi(let ch):
            program = .midi(channel: ch)
            source = .input
            for _ in 0..<40 where !host.inputEnabled { try? await Task.sleep(for: .milliseconds(50)) }
            guard host.inputEnabled else {
                importMessage = "Auto-sampling external gear needs the mic / audio input."
                return
            }
        }
        let rate = source == .input ? host.inputSampleRate : bridge.sampleRate
        var infos: [SampleInfo] = []
        var takes: [(note: Int, velocity: Int, id: SampleID)] = []
        for (i, job) in jobs.enumerated() {
            if Task.isCancelled { break }
            bridge.armRecorder(source: source.engineSource, threshold: 0, preRollFrames: 0,
                               maxSeconds: s.holdSeconds + s.releaseSeconds + 0.5)
            bridge.apply(SamplerCommand.liveNote(program, note: job.note, velocity: job.velocity))
            try? await Task.sleep(for: .seconds(s.holdSeconds))
            bridge.apply(SamplerCommand.liveNote(program, note: job.note, velocity: 0))
            try? await Task.sleep(for: .seconds(s.releaseSeconds))
            bridge.stopRecorder()
            for _ in 0..<50 where bridge.recorderState != .done { try? await Task.sleep(for: .milliseconds(10)) }
            guard let take = bridge.takeRecording() else { continue }
            var audio = AudioData(channels: take.channels, sampleRate: rate).applying(.trimSilence(thresholdDB: -60))
            audio = Self.trimTail(audio, thresholdDB: -60)
            guard audio.frames > Int(0.02 * rate) else { continue }
            do {
                let info = try addGenerated(audio, name: "\(s.name) \(PitchName.noteName(job.note)) v\(job.velocity)")
                infos.append(info)
                takes.append((job.note, job.velocity, info.id))
            } catch {
                break
            }
            autoSampling = (i + 1, jobs.count)
        }
        guard !takes.isEmpty else {
            importMessage = Task.isCancelled ? "Auto-sampling cancelled." : "Nothing was recorded (is the sound silent?)."
            return
        }
        sampler.addSamples(infos, autoAssign: false)
        if let k = sampler.addKeygroup(KeygroupProgram.autoSampled(name: s.name, takes: takes)) {
            importMessage = "\(s.name): keygroup \(k + 1) with \(takes.count) take\(takes.count == 1 ? "" : "s")"
                + (Task.isCancelled ? " (stopped early)." : ".")
        }
    }

    /// Cuts the quiet end off a take (with a 10 ms fade).
    static func trimTail(_ a: AudioData, thresholdDB: Float) -> AudioData {
        let gate = pow(10, thresholdDB / 20)
        let mono = a.mono
        guard let last = mono.lastIndex(where: { abs($0) > gate }) else { return a }
        let end = min(mono.count, last + Int(0.01 * a.sampleRate))
        let fade = min(end, Int(0.01 * a.sampleRate))
        let channels = a.channels.map { ch -> [Float] in
            var c = Array(ch[..<end])
            for i in 0..<fade { c[end - 1 - i] *= Float(i) / Float(fade) }
            return c
        }
        return AudioData(channels: channels, sampleRate: a.sampleRate)
    }

    // MARK: Tuner & Mic mode (SYNTH_SPEC §4)

    private func updateTuner() {
        guard host.inputEnabled else { return synth.setTunerReading(nil) }
        let frame = inputMonitor.latest(4096)
        let hz = PitchDetect.tunerHz(frame, sampleRate: host.inputSampleRate)
        synth.setTunerReading(tunerSmoother.add(TunerReading(hz: hz)))
    }

    private func synthMicRecord(_ start: Bool) {
        if start {
            guard host.inputEnabled else { return synth.micFailed(micWanted ? "MIC NOT READY" : "MIC ACCESS OFF") }
            guard recorderState == .idle || recorderState == .done else { return synth.micFailed("SAMPLER IS RECORDING") }
            synthMicTake = true
            bridge.armRecorder(source: SamplingSource.input.engineSource, threshold: 0, preRollFrames: 0,
                               maxSeconds: SynthController.micMaxSeconds + 0.2)
            recorderState = .recording
        } else if synthMicTake {
            bridge.stopRecorder()
        }
    }

    /// Keeps 1 s from the onset, finds its pitch, saves it and plays it in Lead mode.
    private func finishSynthMicTake() {
        synthMicTake = false
        recorderState = .idle
        guard let take = bridge.takeRecording() else { return synth.micFailed("NOTHING RECORDED") }
        let audio = AudioData(channels: [take.channels[0]], sampleRate: host.inputSampleRate)
        guard let clip = PitchDetect.micTake(audio) else { return synth.micFailed("TOO QUIET") }
        let root = PitchDetect.hz(clip).map(PitchDetect.midiPitch)
        do {
            try store.prepare()
            try SampleLibrary.writeWAV(clip.channels, sampleRate: clip.sampleRate, to: micSampleURL)
            try bridge.samples.load(id: Self.micSampleID, from: micSampleURL)
            bridge.setSynthSample(Self.micSampleID, root: root ?? 60)
            synth.micSampleReady(root: root)
        } catch {
            synth.micFailed("COULDN'T SAVE")
        }
    }

    private func loadMicSample() {
        guard let root = synth.state.micSampleRoot else { return }
        do {
            try bridge.samples.load(id: Self.micSampleID, from: micSampleURL)
            bridge.setSynthSample(Self.micSampleID, root: root)
        } catch {
            synth.forgetMicSample()
        }
    }

    public func armSampling() {
        guard recorderState == .idle || recorderState == .done else { return }
        let threshold: Float = sampling.useThreshold ? .gain(dB: Float(sampling.thresholdDB)) : 0
        let preRoll = Int(sampling.preRollMs / 1000 * bridge.sampleRate)
        bridge.armRecorder(source: sampling.source.engineSource, threshold: threshold,
                           preRollFrames: preRoll, maxSeconds: sampling.maxSeconds)
        recorderState = sampling.useThreshold ? .armed : .recording
    }

    public func stopSampling() { bridge.stopRecorder() }

    public func cancelSampling() {
        bridge.discardRecording()
        recorderState = .idle
    }

    private func pollRecorder() {
        let st = bridge.recorderState
        let level = bridge.recorderPeak
        if abs(level - meter) > 0.005 { meter = level }
        if autoSampling != nil { return } // the auto-sampler runs the recorder itself
        if st == .done, audioTake != nil { return finishAudioTake() }
        let secs = (Double(bridge.recorderFrames) / bridge.sampleRate * 10).rounded() / 10
        if secs != recordedSeconds { recordedSeconds = secs }
        // The engine only reports DONE once; finish the take then.
        if st == .done, synthMicTake { finishSynthMicTake() }
        else if st == .done, recorderState == .armed || recorderState == .recording { finishTake() }
        else if st != recorderState, st != .done, st != .idle { recorderState = st }
    }

    private func finishTake() {
        recorderState = .done
        guard let take = bridge.takeRecording() else {
            recorderState = .idle
            return
        }
        // Mic takes carry the input's own rate.
        let rate = sampling.source == .input ? host.inputSampleRate : take.sampleRate
        var audio = AudioData(channels: sampling.stereo ? take.channels : [take.channels[0]], sampleRate: rate)
        if sampling.trimSilence { audio = audio.applying(.trimSilence(thresholdDB: -50)) }
        do {
            let info = try addGenerated(audio, name: uniqueName(sampling.source == .input ? "Sample" : "Resample"))
            let pads = sampler.addSamples([info])
            importMessage = "\(info.name) (\(String(format: "%.1f", info.duration)) s) → \(pads.first.map(PadAddress.name) ?? "pool")"
            if sampling.openEditAfter, let p = pads.first {
                sampler.selectedPad = p
                sampler.editMode = .trim
                sampler.view = .edit
            }
        } catch {
            importMessage = "Couldn't save the take: \(error.localizedDescription)"
        }
        recorderState = .idle
    }

    // MARK: Chop

    public func startChop() {
        guard let id = sampler.selected.primarySample, let info = sampler.project.sample(id) else {
            chop = nil
            return
        }
        if chop?.sample == id { return }
        chopAudio = nil
        snapTask?.cancel()
        snapSearching = false
        var c = ChopSession(sample: id, frames: info.frames, sampleRate: info.sampleRate)
        c.bpm = bpm
        chop = c
        rechop()
    }

    public func updateChop(_ body: (inout ChopSession) -> Void) {
        guard var c = chop else { return }
        let before = c
        body(&c)
        chop = c
        if c.method != before.method || c.sensitivity != before.sensitivity || c.minLengthMs != before.minLengthMs
            || c.regionCount != before.regionCount || c.bpm != before.bpm || c.division != before.division {
            rechop()
        }
        if c.searchRange != before.searchRange { resnap() }
    }

    /// Recomputes markers for the current method (threshold detection runs off the main thread).
    private func rechop() {
        guard let c = chop else { return }
        detectTask?.cancel()
        switch c.method {
        case .manual, .smart:
            break // markers are the user's own edits
        case .regions:
            chop?.setMarkers(Slicing.regions(frames: c.frames, count: c.regionCount))
        case .beats:
            chop?.setMarkers(Slicing.grid(frames: c.frames, sampleRate: c.sampleRate, bpm: c.bpm, beats: c.division.beats))
        case .threshold:
            guard let audio = audioData(c.sample) else { return }
            let sens = c.sensitivity, minLen = c.minLengthFrames, id = c.sample
            detectTask = Task {
                try? await Task.sleep(for: .milliseconds(120)) // slider debounce
                guard !Task.isCancelled else { return }
                let markers = await Task.detached { Analysis.onsets(audio, sensitivity: sens, minLength: minLen) }.value
                guard !Task.isCancelled, self.chop?.sample == id, self.chop?.method == .threshold else { return }
                self.chop?.setMarkers(markers)
            }
        }
    }

    /// Smart chop: finds where the sound starts in the search window (off the main thread,
    /// lightly debounced since the window moves with the finger).
    private func resnap() {
        snapTask?.cancel()
        guard let c = chop, let range = c.searchRange else { snapSearching = false; return }
        let id = c.sample
        snapSearching = true
        snapTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            if chopAudio?.id != id { chopAudio = audioData(id).map { (id, $0) } }
            guard let audio = chopAudio?.audio else { snapSearching = false; return }
            let found = await Task.detached { Analysis.snapOnset(audio, in: range) }.value
            guard !Task.isCancelled, chop?.sample == id, chop?.searchRange == range else { return }
            chop?.snapFrame = found
            snapSearching = false
        }
    }

    /// Smart chop: adds a slice where the detector snapped, and plays it.
    public func addSmartSlice() {
        guard var c = chop, let i = c.addSnappedMarker() else { return }
        chop = c
        previewSlice(i)
    }

    /// Smart chop: plays from the snap point to the next slice, to check it before adding.
    public func previewSnap() {
        guard let c = chop, let f = c.snapFrame else { return }
        bridge.preview(c.sample, range: f..<(c.markers.first { $0 > f } ?? c.frames))
    }

    public func detectChopBPM() {
        guard let c = chop, let audio = audioData(c.sample) else { return }
        busy = "Detecting tempo…"
        Task {
            let found = await Task.detached { Analysis.bpm(audio) }.value
            busy = nil
            if let found { updateChop { $0.bpm = found } } else { importMessage = "No steady tempo found." }
        }
    }

    public func previewSlice(_ i: Int) {
        guard let c = chop, c.slices.indices.contains(i) else { return }
        bridge.preview(c.sample, range: c.slices[i])
    }

    public func previewSlice(atFrame frame: Int) {
        guard let i = chop?.slice(containing: frame) else { return }
        chop?.selected = i
        previewSlice(i)
    }

    /// Convert (SAMPLER_SPEC §5.2): slice 1 goes on pad 1 of the first empty bank (so the
    /// pads you already have stay), or of the current bank when every bank is in use.
    public func convertChop(_ conversion: ChopConversion) {
        guard let c = chop, let info = sampler.project.sample(c.sample) else { return }
        let bank = sampler.firstEmptyBank(from: sampler.bank) ?? sampler.bank
        let start = PadAddress.pad(bank: bank, gridIndex: 0)
        sampler.bank = bank
        let slices = c.slices
        switch conversion {
        case .pads:
            let pads = sampler.assignSlices(slices, of: c.sample, startPad: start)
            importMessage = "\(pads.count) slices → \(PadAddress.name(start))…"
        case .sequence:
            let pads = sampler.convertToSliceSequence(slices, of: c.sample, startPad: start,
                                                      sampleRate: c.sampleRate, bpm: c.bpm)
            if abs(c.bpm - bpm) > 0.01 { setBPM(c.bpm) }
            importMessage = "\(pads.count) slices → pads + \(sampler.sequence.name) at \(Int(c.bpm.rounded())) BPM"
        case .phrase:
            var k = KeygroupProgram(name: info.name)
            k.zones = [KeygroupZone(lowNote: 0, highNote: 127, rootNote: 48, sample: c.sample)]
            guard let i = sampler.addKeygroup(k) else { importMessage = "All 8 keygroups are in use."; return }
            sampler.addTrack(.keygroup(i))
            importMessage = "\(info.name) is keygroup \(i + 1) on a new track (C3 plays it at pitch)."
        case .samples:
            guard let audio = audioData(c.sample) else { return }
            do {
                let infos = try slices.prefix(DrumProgram.padCount - start).enumerated().map { i, r in
                    try addGenerated(audio.slice(r), name: "\(info.name) \(i + 1)")
                }
                sampler.assignExtracted(infos, startPad: start)
                importMessage = "\(infos.count) new samples → \(PadAddress.name(start))…"
            } catch {
                importMessage = "Couldn't extract slices: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Keygroups

    /// Auto-map (SAMPLER_SPEC §3.2): finds each sample's root note (YIN) and spreads the
    /// samples across the keyboard. Returns the new keygroup's index.
    @discardableResult
    public func autoMapKeygroup(_ ids: [SampleID], name: String) async -> Int? {
        let audios = ids.compactMap { id in audioData(id).map { (id, $0) } }
        guard !audios.isEmpty else { return nil }
        busy = "Finding root notes…"
        let roots = await Task.detached { audios.map { (id: $0.0, root: PitchDetect.rootNote($0.1) ?? 60) } }.value
        busy = nil
        guard let i = sampler.addKeygroup(KeygroupProgram.autoMap(name: name, samples: roots)) else {
            importMessage = "All 8 keygroups are in use."
            return nil
        }
        importMessage = "\(name): \(roots.count) zone\(roots.count == 1 ? "" : "s"), roots " + roots.sorted { $0.root < $1.root }
            .map { PitchName.noteName($0.root) }.joined(separator: " ")
        return i
    }

    // MARK: Processes (SAMPLER_SPEC §5.3)

    /// Runs a destructive process on the selected pad's sample. The result is a new
    /// version; the old one stays (archived) so undo works. When the pad plays a slice
    /// of a sample other pads also use, the process runs on that slice alone (its trim is
    /// then the whole slice) and only this pad gets the result.
    public func applyProcess(_ make: @escaping @Sendable (AudioData, Range<Int>) -> SampleProcess) {
        guard let target = sampler.processTarget(pad: sampler.selectedPad),
              let info = sampler.project.sample(target.sample), let full = audioData(target.sample) else { return }
        let audio = target.slice.map { full.slice($0) } ?? full
        let process = make(audio, target.slice.map { 0..<$0.count } ?? target.trim)
        let name = target.slice == nil ? info.name : "\(info.name) \(PadAddress.name(target.pad))"
        busy = "\(process.label)…"
        Task {
            let result = await Task.detached { audio.applying(process) }.value
            busy = nil
            guard result.frames > 1 else { importMessage = "Nothing left after \(process.label.lowercased())."; return }
            do {
                let new = try addGenerated(result, name: name)
                sampler.applyProcessed(target, new: new, label: process.label)
            } catch {
                importMessage = "\(process.label) failed: \(error.localizedDescription)"
            }
        }
    }

    /// Deletes archived sample versions nothing uses any more.
    public func discardUnusedAudio() {
        let gone = sampler.discardUnused()
        for info in gone {
            bridge.samples.unload(info.id)
            store.deleteFile(for: info)
        }
        importMessage = gone.isEmpty ? "Nothing to discard." : "Discarded \(gone.count) unused version\(gone.count == 1 ? "" : "s")."
    }

    public func previewSelectedPad() { sampler.audition() }

    // MARK: Export (SAMPLER_SPEC §10)

    public enum ExportKind: String, CaseIterable, Sendable {
        case mixdown, stems, midi
        public var label: String { ["Mixdown (WAV)", "Stems (WAV per track)", "MIDI file"][Self.allCases.firstIndex(of: self)!] }
    }

    public enum ExportSource: String, CaseIterable, Sendable {
        case sequence, song
        public var label: String { self == .sequence ? "Current sequence" : "Song" }
    }

    /// Files from the last export (in Documents/PocketSynth/Exports, visible in Files).
    public private(set) var exportedFiles: [URL] = []
    public private(set) var exporting = false
    /// The last export's outcome, shown in the export sheet (an alert would close it).
    public private(set) var exportStatus: String?

    var exportsDirectory: URL { store.directory.appendingPathComponent("Exports", isDirectory: true) }

    /// The sequence to export: the current one, or the song flattened into one.
    private func exportSequence(_ source: ExportSource) -> PadSequence? {
        switch source {
        case .sequence: return sampler.sequence
        case .song:
            let song = sampler.project.song
            guard !song.steps.isEmpty else { return nil }
            return song.flattened(sampler.project.sequences, name: "Song")
        }
    }

    /// A second engine set up like the live one (same sound, pads, keygroups, mixer).
    private func offlineBridge() -> EngineBridge {
        let b = EngineBridge(sampleRate: bridge.sampleRate, sharing: bridge.samples)
        for c in EngineCommand.diff(from: nil, to: synth.state) { b.apply(c) }
        b.apply(EngineCommand.metronome(on: false, level: 0))
        b.apply(EngineCommand.midiOut(false))
        for (i, p) in sampler.project.program.pads.enumerated() where !p.isEmpty { b.apply(SamplerCommand.pad(i, p)) }
        for (i, k) in sampler.project.keygroups.enumerated() { b.apply(SamplerCommand.keygroup(i, k)) }
        var mixer = sampler.project.mixer
        mixer.xy.active = false
        b.apply(SamplerCommand.mixer(mixer))
        b.apply(SamplerCommand.clips(sampler.project.clips, beatsPerBar: sampler.sequence.beatsPerBar))
        return b
    }

    /// Renders `seq` once (plus a release tail) through a fresh offline engine.
    private func render(_ seq: PadSequence, tail: Double = 2) async -> [[Float]] {
        var once = seq
        once.loop = false
        let b = offlineBridge()
        b.apply(SamplerCommand.beatsPerBar(once.beatsPerBar))
        b.apply(SamplerCommand.sequence(once))
        b.apply(SamplerCommand.transport(playing: true, startTick: 0, countInBeats: 0))
        let seconds = Double(once.lengthTicks) / Double(PPQN.ticks) * 60 / bpm + tail
        let total = Int(seconds * bridge.sampleRate)
        var out: [[Float]] = [[], []]
        let chunk = Int(bridge.sampleRate * 2)
        var done = 0
        while done < total {
            let part = b.renderOffline(frames: min(chunk, total - done))
            out[0] += part[0]
            out[1] += part[1]
            done += part[0].count
            await Task.yield() // keep the UI alive
        }
        return out
    }

    private func safeName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" }).trimmingCharacters(in: .whitespaces)
    }

    public func export(_ kind: ExportKind, source: ExportSource, bitDepth: Int = 24) async {
        guard !exporting else { return }
        guard let seq = exportSequence(source) else {
            exportStatus = "The song is empty. Add steps in Song first."
            return
        }
        exporting = true
        exportStatus = nil
        exportedFiles = []
        busy = "Exporting…"
        defer { exporting = false; busy = nil }
        do {
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
            let base = safeName(source == .song ? "Song" : seq.name)
            var files: [URL] = []
            switch kind {
            case .midi:
                let url = exportsDirectory.appendingPathComponent("\(base).mid")
                try MIDIFile.make(seq, bpm: bpm).write(to: url, options: .atomic)
                files = [url]
            case .mixdown:
                let audio = await render(seq)
                let url = exportsDirectory.appendingPathComponent("\(base).wav")
                try SampleLibrary.writeWAV(audio, sampleRate: bridge.sampleRate, to: url, bitDepth: bitDepth)
                files = [url]
            case .stems:
                for (i, t) in seq.tracks.enumerated() where !t.events.isEmpty {
                    var solo = seq
                    for j in solo.tracks.indices { solo.tracks[j].mute = j != i; solo.tracks[j].solo = false }
                    let audio = await render(solo)
                    let url = exportsDirectory.appendingPathComponent("\(base) - \(i + 1) \(safeName(t.name)).wav")
                    try SampleLibrary.writeWAV(audio, sampleRate: bridge.sampleRate, to: url, bitDepth: bitDepth)
                    files.append(url)
                }
            }
            exportedFiles = files
            exportStatus = files.isEmpty ? "Nothing to export." : "Exported \(files.count) file\(files.count == 1 ? "" : "s")."
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func scheduleSave(_ project: SamplerProject) {
        saveTask?.cancel()
        let store = self.store
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? store.save(project)
        }
    }
}
