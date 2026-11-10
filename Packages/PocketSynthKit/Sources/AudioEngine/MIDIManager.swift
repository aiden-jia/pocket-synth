import CoreMIDI
import Foundation
import os
import SynthCore
import SynthDSP

/// CoreMIDI for the whole app (SYNTH_SPEC §9).
///
/// Out: the engine queues every MIDI event with a host timestamp; a dedicated thread
/// drains the queue about once a millisecond and sends it to every destination and to our
/// virtual "PocketSynth" source. Timestamps are in the future (they include the output
/// latency), so CoreMIDI delivers them in step with the audio.
///
/// In: every source plus our virtual destination. Notes, sustain and panic go straight to
/// the engine's MIDI-in queue (under a lock, so the engine sees one producer); clock,
/// transport and control CCs go to the main actor through the callbacks.
public final class MIDIManager: @unchecked Sendable {
    public enum Transport: Sendable { case start, `continue`, stop }

    /// Incoming notes and CCs are passed on only while this is on (MIDI IN setting).
    public var inputEnabled: Bool {
        get { state.withLock { $0.inputEnabled } }
        set { state.withLock { $0.inputEnabled = newValue } }
    }

    @MainActor public var onTempo: (Double) -> Void = { _ in }
    @MainActor public var onTransport: (Transport) -> Void = { _ in }
    @MainActor public var onControl: (Int, Int, Int) -> Void = { _, _, _ in }

    public private(set) var available = false

    nonisolated(unsafe) private let engine: OpaquePointer
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var virtualDestination = MIDIEndpointRef()
    private var sender: Thread?

    private struct State {
        var inputEnabled = false
        var clock = ClockFollower()
        var destinations: [MIDIEndpointRef] = []
        var running = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(engine: OpaquePointer) {
        self.engine = engine
    }

    /// Host-clock ticks per second (mach_absolute_time).
    public static var hostTicksPerSecond: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }

    /// Creates the client, ports and virtual endpoints, and starts the sender thread.
    public func start() {
        let name = "PocketSynth" as CFString
        var status = MIDIClientCreateWithBlock(name, &client) { [weak self] _ in self?.refreshEndpoints() }
        guard status == noErr else { return }
        let receive: MIDIReceiveBlock = { [weak self] list, _ in self?.receive(list) }
        status = MIDIInputPortCreateWithProtocol(client, "In" as CFString, ._1_0, &inPort, receive)
        guard status == noErr else { return }
        MIDIOutputPortCreate(client, "Out" as CFString, &outPort)
        MIDISourceCreateWithProtocol(client, name, ._1_0, &virtualSource)
        MIDIDestinationCreateWithProtocol(client, name, ._1_0, &virtualDestination, receive)
        available = true
        refreshEndpoints()

        let t = Thread { [weak self] in self?.sendLoop() }
        t.name = "PocketSynth MIDI out"
        t.qualityOfService = .userInteractive
        sender = t
        t.start()
    }

    public func stop() {
        state.withLock { $0.running = false }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Connects every source to our input and remembers every destination.
    private func refreshEndpoints() {
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if src != virtualSource { MIDIPortConnectSource(inPort, src, nil) }
        }
        let dests = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter { $0 != virtualDestination }
        state.withLock { $0.destinations = dests }
    }

    // MARK: Out

    private func sendLoop() {
        var events = [PSMidiEvent](repeating: PSMidiEvent(), count: 256)
        let bufferSize = 64 * 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { raw.deallocate() }
        while state.withLock({ $0.running }) {
            let n = Int(ps_engine_poll_midi_out(engine, &events, Int32(events.count)))
            if n == 0 {
                usleep(1000)
                continue
            }
            let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
            var packet = MIDIEventListInit(list, ._1_0)
            for e in events.prefix(n) {
                var word = MIDIMessage.ump(status: Int(e.status), data1: Int(e.data1), data2: Int(e.data2))
                // 256 one-word packets need ~4 KB: the 64 KB buffer can't run out.
                packet = MIDIEventListAdd(list, bufferSize, packet, MIDITimeStamp(e.hostTime), 1, &word)
            }
            let dests = state.withLock { $0.destinations }
            MIDIReceivedEventList(virtualSource, list)
            for d in dests { MIDISendEventList(outPort, d, list) }
        }
    }

    // MARK: In

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var packet = UnsafeMutableRawPointer(mutating: list)
            .advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
            .assumingMemoryBound(to: MIDIEventPacket.self)
        let time = ProcessInfo.processInfo.systemUptime
        for _ in 0..<list.pointee.numPackets {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for w in words.prefix(count) { handle(MIDIMessage(ump: w), at: time) }
            }
            packet = MIDIEventPacketNext(packet)
        }
    }

    private func handle(_ m: MIDIMessage, at time: Double) {
        switch m {
        case .clock:
            if let bpm = state.withLock({ s in s.inputEnabled ? s.clock.tick(at: time) : nil }) {
                Task { @MainActor in self.onTempo(bpm) }
            }
        case .start, .continue, .stop:
            guard inputEnabled else { return }
            let t: Transport = m == .start ? .start : m == .stop ? .stop : .continue
            Task { @MainActor in self.onTransport(t) }
        case .controlChange(let ch, let cc, let v) where cc != 64 && cc != 120 && cc != 123:
            guard inputEnabled else { return }
            Task { @MainActor in self.onControl(ch, cc, v) }
        default:
            guard let b = m.bytes else { return }
            // One producer for the engine's MIDI-in queue: the lock serializes CoreMIDI threads.
            state.withLock { s in
                guard s.inputEnabled else { return }
                ps_engine_midi_in(engine, Int32(b.status), Int32(b.data1), Int32(b.data2))
            }
        }
    }
}
