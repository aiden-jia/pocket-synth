import ChordTheory
import SamplerCore
import SynthCore
import SynthDSP

/// Translates SynthCore's `EngineCommand`s and SamplerCore's `SamplerCommand`s into
/// calls on the C engine.
///
/// Chord slots go to the engine's performer, which owns all timing (DESIGN §2): it
/// reference-counts held notes (so C → C7 keeps the shared notes ringing) and runs
/// strum, arp, repeat, the chord sequencer and the drum machine on its beat clock.
@MainActor
public final class EngineBridge {
    nonisolated(unsafe) public let engine: OpaquePointer
    public let sampleRate: Double
    public let samples: SampleLibrary
    private var pads: [Int: Pad] = [:]
    private var keygroups: [Int: KeygroupProgram] = [:]
    private var tempo = 120.0
    /// Loop buffers by track (the engine owns them; kept here to read for "send to sampler").
    private var loopBuffers: [Int: OpaquePointer] = [:]
    /// Longest free loop (SYNTH_SPEC §5, phone-native: 2 minutes).
    public static let maxLoopSeconds = 120.0

    /// Fixed MIDI-style velocity 100 (SYNTH_SPEC §9), as 0...1.
    static let velocity: Float = 100.0 / 127.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        engine = ps_engine_create(sampleRate)
        samples = SampleLibrary()
        samples.engine = engine
    }

    /// A second engine for offline rendering (export) that plays the samples `library`
    /// already loaded. It never frees them; keep them loaded until it's gone.
    public init(sampleRate: Double, sharing library: SampleLibrary) {
        self.sampleRate = sampleRate
        engine = ps_engine_create(sampleRate)
        samples = library
    }

    /// Renders offline (no audio device).
    public func renderOffline(frames: Int) -> [[Float]] {
        var l = [Float](repeating: 0, count: frames), r = l
        var i = 0
        let block = 4096
        while i < frames {
            let n = min(block, frames - i)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    ps_engine_render(engine, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n))
                }
            }
            i += n
        }
        return [l, r]
    }

    deinit {
        // Engine first (it may still reference samples), then the sample buffers.
        ps_engine_destroy(engine)
    }

    // MARK: Synth

    public func apply(_ command: EngineCommand) {
        switch command {
        case .chord(let slot, let voicing):
            var notes = (voicing?.notes ?? []).prefix(Int(PS_MAX_SLOT_NOTES)).map { Int32($0) }
            ps_synth_set_slot(engine, Int32(slot), &notes, Int32(notes.count), Int32(voicing?.bass ?? -1))
        case .allNotesOff:
            ps_engine_all_notes_off(engine)
        case .sound(let index, _):
            var patch = SoundPatches.patch(forSound: index)
            ps_engine_set_patch(engine, &patch)
        case .envelope(let e):
            set(PS_PARAM_ATTACK_MS, e.attackMs)
            set(PS_PARAM_DECAY_MS, e.decayMs)
            set(PS_PARAM_SUSTAIN, e.sustain)
            set(PS_PARAM_RELEASE_MS, e.releaseMs)
        case .volume(let v):
            set(PS_PARAM_VOLUME, v)
        case .tempo(let bpm):
            tempo = bpm
            set(PS_PARAM_TEMPO_BPM, bpm)
        case .filter(let enabled, let cutoff):
            set(PS_PARAM_FILTER_ENABLED, enabled ? 1 : 0)
            set(PS_PARAM_CUTOFF_HZ, cutoff)
        case .stereo(let on):
            set(PS_PARAM_STEREO, on ? 1 : 0)
        case .glide(let g):
            set(PS_PARAM_GLIDE_MS, Self.glideMs(g))
        case .fx(let kind, let index):
            if let param = Self.param(for: kind) {
                set(param, Double(index))
            } else if kind == .lfo {
                set(PS_PARAM_VIBRATO_CENTS, [0, 10, 25, 50][min(index, 3)])
            } // vocoder: phase 6
        case .mode(let m):
            ps_synth_set_performer(engine, Int32(Self.performer(for: m).rawValue))
        case .rhythm(let strum, let pattern, let layer, let arpRate, let repeatRate, let seqRate):
            var r = PSRhythm()
            r.strumMs = Float(strum.stepMs)
            r.arpPattern = Int32(ArpPattern.allCases.firstIndex(of: pattern)!)
            r.arpLayer = Int32(ArpLayer.allCases.firstIndex(of: layer)!)
            r.arpRateBeats = arpRate.beats
            r.arpSwing = Float(arpRate.swing)
            r.repeatRateBeats = repeatRate.beats
            r.repeatSwing = Float(repeatRate.swing)
            r.repeatStutter = repeatRate == .stutter ? 1 : 0
            r.seqRateBeats = seqRate.beats
            ps_synth_set_rhythm(engine, &r)
        case .drumHit(let voice, let velocity):
            ps_drum_trigger(engine, Int32(voice.rawValue), Int32(velocity))
        case .drumRepeat(let voice, let beats, let swing):
            ps_drum_repeat(engine, Int32(voice.rawValue), beats, Float(swing), 100)
        case .drumKit(let kit):
            ps_drum_set_kit(engine, Int32(kit - 1))
        case .beat(let pattern, let playing):
            if var p = pattern.map(Self.beatPattern) {
                ps_beat_set(engine, &p, playing ? 1 : 0)
            } else {
                ps_beat_set(engine, nil, playing ? 1 : 0)
            }
        case .chordSequence(let steps):
            for (i, v) in steps.prefix(Int(PS_SEQ_STEPS)).enumerated() {
                var notes = (v?.notes ?? []).prefix(Int(PS_MAX_SLOT_NOTES)).map { Int32($0) }
                ps_synth_set_seq_step(engine, Int32(i), &notes, Int32(notes.count), Int32(v?.bass ?? -1))
            }
        case .chordSequencePlaying(let playing, let length):
            ps_synth_set_seq(engine, Int32(length), playing ? 1 : 0)
        case .looperRecordFirst(let track, let bars, let countIn, let gen):
            let frames = bars.map { Int(Double($0 * 4) * 60 / tempo * sampleRate) }
            let buf = ps_sample_create(Int32(frames ?? Int(Self.maxLoopSeconds * sampleRate)), 2, sampleRate)!
            loopBuffers[track] = buf
            ps_looper_record_first(engine, Int32(track), buf, Int32(frames ?? 0), Int32(countIn), Int32(gen))
        case .looperStopFirst(let gen):
            ps_looper_stop_first(engine, Int32(gen))
        case .looperArm(let track, let gen):
            let length = Int(ps_looper_length(engine))
            guard length > 0 else { return }
            let buf = ps_sample_create(Int32(length), 2, sampleRate)!
            loopBuffers[track] = buf
            ps_looper_arm(engine, Int32(track), buf, Int32(gen))
        case .looperClear(let track, let gen):
            loopBuffers[track] = nil // the engine frees it through the garbage queue
            ps_looper_clear(engine, Int32(track), Int32(gen))
        case .looperPause(let on):
            ps_looper_pause(engine, on ? 1 : 0)
        case .looperGain(let track, let gain):
            ps_looper_set_gain(engine, Int32(track), Float(gain))
        case .metronome(let on, let level):
            set(PS_PARAM_METRONOME, on ? 1 : 0)
            set(PS_PARAM_METRONOME_LEVEL, level)
        case .midiOut(let on):
            set(PS_PARAM_MIDI_OUT, on ? 1 : 0)
            set(PS_PARAM_MIDI_CLOCK_OUT, on ? 1 : 0)
        }
    }

    static func performer(for mode: SynthMode) -> PSPerformer {
        switch mode {
        case .strum: PS_PERF_STRUM
        case .arp: PS_PERF_ARP
        case .repeat: PS_PERF_REPEAT
        case .seq: PS_PERF_SEQ
        case .drums: PS_PERF_DRUMS
        case .beat: PS_PERF_BEAT
        default: PS_PERF_PLAY // play, lead, drone and the tools
        }
    }

    static func beatPattern(_ p: BeatPattern) -> PSBeatPattern {
        var out = PSBeatPattern()
        out.steps = Int32(min(p.steps, Int(PS_BEAT_MAX_STEPS)))
        out.stepBeats = p.stepBeats
        out.swing = Float(p.swing)
        let voices = Int(PS_DRUM_VOICES)
        withUnsafeMutableBytes(of: &out.velocity) { raw in
            for step in 0..<Int(out.steps) {
                for v in 0..<min(voices, p.hits[step].count) {
                    raw[step * voices + v] = UInt8(clamping: p.hits[step][v])
                }
            }
        }
        return out
    }

    private func set(_ p: PSParam, _ v: Double) { ps_engine_set_param(engine, p, Float(v)) }

    static func param(for kind: FXKind) -> PSParam? {
        switch kind {
        case .reverb: PS_PARAM_FX_REVERB
        case .delay: PS_PARAM_FX_DELAY
        case .chorus: PS_PARAM_FX_CHORUS
        case .flanger: PS_PARAM_FX_FLANGER
        case .drive: PS_PARAM_FX_DRIVE
        case .tape: PS_PARAM_FX_TAPE
        case .tremolo: PS_PARAM_FX_TREMOLO
        case .lfo, .filter, .vocoder: nil
        }
    }

    static func glideMs(_ g: Glide) -> Double {
        switch g {
        case .off: 0
        case .short: 60
        case .medium: 150
        case .long: 400
        }
    }

    // MARK: Sampler

    public func apply(_ command: SamplerCommand) {
        switch command {
        case .pad(let index, let pad):
            pads[index] = pad
            sendPad(index, pad)
        case .trigger(let pad, let velocity, let tune):
            ps_sampler_trigger_ex(engine, Int32(pad), Int32(velocity), Float(tune))
        case .release(let pad):
            ps_sampler_release(engine, Int32(pad))
        case .stopAll:
            ps_sampler_stop_all(engine)
        case .mixer(let m):
            set(PS_PARAM_SYNTH_LEVEL, m.synthLevel)
            set(PS_PARAM_SAMPLER_LEVEL, m.samplerLevel)
            set(PS_PARAM_MASTER_LEVEL, m.masterLevel)
            for (i, s) in m.submixes.enumerated() {
                ps_mixer_set_submix(engine, Int32(i), Float(s.level), Float(s.pan), s.mute ? 1 : 0,
                                    Int32(s.insert.rawValue), Float(s.amount))
            }
            for (i, r) in m.returns.enumerated() { ps_mixer_set_return(engine, Int32(i), Int32(r.type.rawValue), Float(r.level)) }
            ps_mixer_set_xy(engine, Int32(m.xy.type.rawValue), Float(m.xy.x), Float(m.xy.y), m.xy.active ? 1 : 0)
        case .sequence(let seq):
            var events = Self.engineEvents(seq)
            let compiled = ps_sequence_create(&events, Int32(events.count), Int32(seq.lengthTicks), seq.loop ? 1 : 0)
            ps_engine_set_sequence(engine, compiled)
        case .xy(let xy):
            ps_mixer_set_xy(engine, Int32(xy.type.rawValue), Float(xy.x), Float(xy.y), xy.active ? 1 : 0)
        case .queueSequence(let seq, let atBar, let loop):
            var events = Self.engineEvents(seq)
            let compiled = ps_sequence_create(&events, Int32(events.count), Int32(seq.lengthTicks), (loop ?? seq.loop) ? 1 : 0)
            ps_engine_queue_sequence(engine, compiled, atBar ? 1 : 0)
        case .transport(let playing, let start, let countIn):
            if playing { ps_transport_play(engine, Int32(start), Int32(countIn)) } else { ps_transport_stop(engine) }
        case .recording(let on, let guardTicks):
            ps_transport_set_recording(engine, on ? 1 : 0, Int32(guardTicks))
        case .metronome(let on):
            set(PS_PARAM_METRONOME, on ? 1 : 0)
        case .beatsPerBar(let n):
            set(PS_PARAM_BEATS_PER_BAR, Double(n))
        case .noteRepeat(let beats, let swing):
            ps_note_repeat_set(engine, beats, Float(swing))
        case .repeatPad(let pad, let velocity, let tune):
            ps_note_repeat_pad(engine, Int32(pad), Int32(velocity), Float(tune))
        case .keygroup(let i, let k):
            keygroups[i] = k
            sendKeygroup(i, k)
        case .liveNote(let program, let note, let velocity):
            let (target, index) = Self.target(program)
            ps_live_note(engine, target, index, Int32(note), Int32(velocity))
        }
    }

    /// Flattens the audible tracks (unmuted; only soloed ones if any are) into the
    /// engine's event array, each event tagged with its track's target.
    static func engineEvents(_ seq: PadSequence) -> [PSNoteEvent] {
        let anySolo = seq.tracks.contains { $0.solo }
        return seq.tracks.filter { !$0.mute && (!anySolo || $0.solo) }.flatMap { track in
            let (target, program) = Self.target(track.program)
            return track.events.map {
                PSNoteEvent(tick: Int32($0.tick), length: Int32($0.length), pad: Int32($0.pad),
                            velocity: Int32($0.velocity), tune: Float($0.tune), target: target, program: program)
            }
        }
    }

    static func target(_ p: TrackProgram) -> (Int32, Int32) {
        switch p {
        case .drum: (Int32(PS_TARGET_DRUM.rawValue), 0)
        case .keygroup(let i): (Int32(PS_TARGET_KEYGROUP.rawValue), Int32(i))
        case .synth: (Int32(PS_TARGET_SYNTH.rawValue), 0)
        case .midi(let ch): (Int32(PS_TARGET_MIDI.rawValue), Int32(max(0, min(15, ch - 1))))
        }
    }

    private func sendKeygroup(_ index: Int, _ k: KeygroupProgram) {
        guard index < Int(PS_KEYGROUP_PROGRAMS) else { return }
        var common = PSPadParams()
        common.oneShot = 0
        common.mono = k.mono ? 1 : 0
        common.attackMs = Float(k.envelope.attackMs)
        common.holdMs = Float(k.envelope.holdMs)
        common.decayMs = Float(k.envelope.decayMs)
        common.sustain = Float(k.envelope.sustain)
        common.releaseMs = Float(k.envelope.releaseMs)
        common.level = Float(k.level)
        common.pan = Float(k.pan)
        let zones = Array(k.zones.prefix(Int(PS_KEYGROUP_ZONES)))
        for (zi, z) in zones.enumerated() {
            var pad = Pad()
            pad.layers = z.layers
            let params = Self.params(for: pad) { self.samples.handle(for: $0) }
            var zone = PSKeygroupZone()
            zone.lowNote = Int32(z.lowNote)
            zone.highNote = Int32(z.highNote)
            zone.rootNote = Int32(z.rootNote)
            zone.layers = params.layers
            zone.layerCount = params.layerCount
            ps_keygroup_set_zone(engine, Int32(index), Int32(zi), &zone)
        }
        ps_keygroup_set_program(engine, Int32(index), Int32(zones.count), &common)
    }

    // MARK: Telemetry

    /// Hits recorded since the last call.
    public func pollRecorded() -> [RecordedHit] {
        var buf = [PSRecordedEvent](repeating: PSRecordedEvent(), count: 256)
        var out: [RecordedHit] = []
        while true {
            let n = Int(ps_engine_poll_recorded(engine, &buf, Int32(buf.count)))
            out += buf.prefix(n).map {
                RecordedHit(tick: Int($0.tick), pad: Int($0.pad), velocity: Int($0.velocity), tune: Double($0.tune),
                            isNote: $0.target != Int32(PS_TARGET_DRUM.rawValue))
            }
            if n < buf.count { return out }
        }
    }

    public var transportTicks: Double { ps_transport_ticks(engine) }
    public var sequenceGeneration: Int { Int(ps_transport_sequence_generation(engine)) }
    public var transportPlaying: Bool { ps_transport_playing(engine) != 0 }
    public var chordSequencePosition: Int? {
        let p = Int(ps_synth_seq_position(engine))
        return p >= 0 ? p : nil
    }
    public var beatPosition: Int? {
        let p = Int(ps_beat_position(engine))
        return p >= 0 ? p : nil
    }

    // MARK: Sampling

    private var recordBuffer: OpaquePointer?

    public enum RecorderState: Int, Sendable { case idle, armed, recording, done }

    /// Starts a take of `source` (PSSource) into a fresh buffer of `maxSeconds`.
    public func armRecorder(source: Int, threshold: Float, preRollFrames: Int, maxSeconds: Double) {
        let buf = ps_sample_create(Int32(maxSeconds * sampleRate), 2, sampleRate)!
        recordBuffer = buf
        ps_recorder_arm(engine, buf, Int32(source), threshold, Int32(preRollFrames))
    }

    public func stopRecorder() { ps_recorder_stop(engine) }

    public func setMeterSource(_ source: Int) { ps_recorder_set_meter_source(engine, Int32(source)) }

    public var recorderState: RecorderState { RecorderState(rawValue: Int(ps_recorder_state(engine))) ?? .idle }
    public var recorderFrames: Int { Int(ps_recorder_frames(engine)) }
    public var recorderPeak: Float { ps_recorder_peak(engine) }

    /// The finished take's audio; hands the buffer back to the engine.
    public func takeRecording() -> (channels: [[Float]], sampleRate: Double)? {
        defer {
            ps_recorder_release(engine)
            recordBuffer = nil
        }
        guard recorderState == .done, let buf = recordBuffer else { return nil }
        let n = min(recorderFrames, Int(ps_sample_frames(buf)))
        guard n > 1 else { return nil }
        let channels = (0..<2).map { ch in Array(UnsafeBufferPointer(start: ps_sample_channel(buf, Int32(ch)), count: n)) }
        return (channels, sampleRate)
    }

    public func discardRecording() {
        ps_recorder_stop(engine)
        ps_recorder_release(engine)
        recordBuffer = nil
    }

    /// Feeds mic/interface audio (call from the input tap's thread only).
    nonisolated public func pushInput(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        ps_engine_push_input(engine, left, right, Int32(frames))
    }

    /// Plays part of a loaded sample on the hidden preview pad.
    public func preview(_ id: SampleID, range: Range<Int>, velocity: Int = 110) {
        guard let h = samples.handle(for: id) else { return }
        ps_sampler_preview(engine, h, Int32(range.lowerBound), Int32(range.upperBound), Int32(velocity))
    }

    // MARK: Looper telemetry

    /// Call before audio starts: MIDI timestamps are host ticks, delayed by `latency` s.
    public func setHostClock(latency: Double) {
        let tps = MIDIManager.hostTicksPerSecond
        ps_engine_set_host_clock(engine, tps, latency * tps)
    }

    /// Live synth playing goes out on this channel (0-based).
    public func setLiveMIDIChannel(_ ch: Int) { set(PS_PARAM_MIDI_CHANNEL, Double(ch)) }

    public var looperReports: [LoopTrackReport] {
        (0..<Int(PS_LOOPER_TRACKS)).map { LoopTrackReport(packed: Int(ps_looper_track(engine, Int32($0)))) }
    }
    public var looperLength: Int { Int(ps_looper_length(engine)) }
    public var looperPosition: Double { ps_looper_position(engine) }

    /// A finished loop's audio (only while the track plays, so nothing is writing it).
    public func loopAudio(track: Int) -> (channels: [[Float]], sampleRate: Double)? {
        let length = looperLength
        guard length > 0, let buf = loopBuffers[track],
              LoopTrackReport(packed: Int(ps_looper_track(engine, Int32(track)))).state == .play else { return nil }
        let n = min(length, Int(ps_sample_frames(buf)))
        let channels = (0..<2).map { ch in Array(UnsafeBufferPointer(start: ps_sample_channel(buf, Int32(ch)), count: n)) }
        return (channels, sampleRate)
    }

    /// Frees sequences and samples the audio thread has let go of.
    public func collectGarbage() { samples.collectGarbage() }

    /// Re-sends pads that use `id` (after a sample finished loading).
    public func refreshPads(using id: SampleID) {
        for (i, p) in pads where p.layers.contains(where: { $0.sampleID == id }) { sendPad(i, p) }
        for (i, k) in keygroups where k.zones.contains(where: { $0.layers.contains { $0.sampleID == id } }) {
            sendKeygroup(i, k)
        }
    }

    private func sendPad(_ index: Int, _ pad: Pad) {
        var p = Self.params(for: pad) { self.samples.handle(for: $0) }
        ps_sampler_set_pad(engine, Int32(index), &p)
    }

    /// Converts a pad to the engine's POD struct. Layers whose sample isn't loaded are skipped.
    static func params(for pad: Pad, handle: (SampleID) -> OpaquePointer?) -> PSPadParams {
        var p = PSPadParams()
        p.oneShot = pad.trigger == .oneShot ? 1 : 0
        p.mono = pad.mono ? 1 : 0
        p.muteGroup = Int32(pad.muteGroup)
        p.attackMs = Float(pad.envelope.attackMs)
        p.holdMs = Float(pad.envelope.holdMs)
        p.decayMs = Float(pad.envelope.decayMs)
        p.sustain = Float(pad.envelope.sustain)
        p.releaseMs = Float(pad.envelope.releaseMs)
        p.level = Float(pad.level)
        p.pan = Float(pad.pan)
        p.output = Int32(max(0, min(Int(PS_SUBMIXES), pad.output)))
        let s = pad.sends + [0, 0, 0, 0]
        p.sends = (Float(s[0]), Float(s[1]), Float(s[2]), Float(s[3]))

        var layers: [PSLayer] = []
        for l in pad.layers.prefix(Int(PS_MAX_LAYERS)) {
            guard let id = l.sampleID, let h = handle(id) else { continue }
            var c = PSLayer()
            c.sample = h
            c.start = Int32(l.start)
            c.end = Int32(l.end ?? 0)
            c.tuneSemitones = Float(l.tune)
            c.level = Float(l.level)
            c.pan = Float(l.pan)
            c.velocityLow = Int32(l.velocityLow)
            c.velocityHigh = Int32(l.velocityHigh)
            c.reverse = l.reverse ? 1 : 0
            layers.append(c)
        }
        p.layerCount = Int32(layers.count)
        withUnsafeMutableBytes(of: &p.layers) { raw in
            let dst = raw.bindMemory(to: PSLayer.self)
            for (i, l) in layers.enumerated() { dst[i] = l }
        }
        return p
    }
}
