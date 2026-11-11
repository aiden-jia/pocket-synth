import AudioEngine
import CoreMIDI
import Foundation
import os
import SynthDSP
import Testing

/// Round trips through real CoreMIDI: a separate client talks to MIDIManager's virtual
/// "PocketSynth" source and destination, the way another app or a DAW would.
@Suite("CoreMIDI virtual ports", .serialized)
struct MIDIManagerTests {
    /// A second CoreMIDI client standing in for another app.
    final class Peer: @unchecked Sendable {
        var client = MIDIClientRef()
        var inPort = MIDIPortRef()
        var outPort = MIDIPortRef()
        let received = OSAllocatedUnfairLock(initialState: [UInt32]())

        init() throws {
            guard MIDIClientCreateWithBlock("PocketSynth test peer" as CFString, &client, nil) == noErr else { throw Failure.noMIDI }
            let words = received
            MIDIInputPortCreateWithProtocol(client, "Peer in" as CFString, ._1_0, &inPort) { list, _ in
                var packet = UnsafeMutableRawPointer(mutating: list)
                    .advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
                    .assumingMemoryBound(to: MIDIEventPacket.self)
                for _ in 0..<list.pointee.numPackets {
                    let count = Int(packet.pointee.wordCount)
                    withUnsafeBytes(of: packet.pointee.words) { raw in
                        let w = Array(raw.bindMemory(to: UInt32.self).prefix(count))
                        words.withLock { $0 += w }
                    }
                    packet = MIDIEventPacketNext(packet)
                }
            }
            MIDIOutputPortCreate(client, "Peer out" as CFString, &outPort)
        }

        deinit { MIDIClientDispose(client) }

        /// Every source / destination called "PocketSynth" (polls briefly: new endpoints
        /// can take a moment to show up).
        static func endpoints(sources: Bool) async -> [MIDIEndpointRef] {
            for _ in 0..<100 {
                let n = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
                let found = (0..<n).map { sources ? MIDIGetSource($0) : MIDIGetDestination($0) }.filter { e in
                    var name: Unmanaged<CFString>?
                    MIDIObjectGetStringProperty(e, kMIDIPropertyName, &name)
                    return (name?.takeRetainedValue() as String?) == "PocketSynth"
                }
                if !found.isEmpty { return found }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return []
        }

        func send(_ bytes: [UInt8], to dest: MIDIEndpointRef) {
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            var word = UInt32(0x2000_0000) | UInt32(bytes[0]) << 16
                | UInt32(bytes.count > 1 ? bytes[1] : 0) << 8 | UInt32(bytes.count > 2 ? bytes[2] : 0)
            if bytes[0] >= 0xF0 { word = UInt32(0x1000_0000) | UInt32(bytes[0]) << 16 } // system real-time
            MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            MIDISendEventList(outPort, dest, &list)
        }
    }

    enum Failure: Error { case noMIDI }

    /// An engine plus a started MIDIManager on it.
    final class Rig: @unchecked Sendable {
        let engine: OpaquePointer = ps_engine_create(48000)
        let midi: MIDIManager

        init() {
            ps_engine_set_host_clock(engine, MIDIManager.hostTicksPerSecond, 0)
            ps_engine_set_param(engine, PS_PARAM_MIDI_CLOCK_OUT, 0)
            ps_engine_set_param(engine, PS_PARAM_MIDI_OUT, 1)
            midi = MIDIManager(engine: engine)
            midi.start()
        }

        func render(_ frames: Int = 480) {
            var l = [Float](repeating: 0, count: frames), r = l
            ps_engine_render_at(engine, &l, &r, Int32(frames), mach_absolute_time())
        }

        func close() {
            midi.stop()
            usleep(20_000) // let the sender thread see `running == false`
            ps_engine_destroy(engine)
        }
    }

    @Test func engineNotesReachTheVirtualSource() async throws {
        let rig = Rig()
        defer { rig.close() }
        try #require(rig.midi.available)
        let peer = try Peer()
        let sources = await Peer.endpoints(sources: true)
        try #require(!sources.isEmpty)
        for s in sources { MIDIPortConnectSource(peer.inPort, s, nil) }

        ps_drum_trigger(rig.engine, 0, 100)
        rig.render()
        var noteOn: UInt32?
        for _ in 0..<200 where noteOn == nil {
            try await Task.sleep(for: .milliseconds(5))
            noteOn = peer.received.withLock { $0.first { $0 >> 28 == 2 && ($0 >> 20) & 0xF == 0x9 } }
        }
        let word = try #require(noteOn)
        #expect((word >> 8) & 0x7F > 0)   // a note number
        #expect(word & 0x7F == 100)       // the pad's velocity
    }

    @Test func notesSentToTheVirtualDestinationPlayTheSynth() async throws {
        let rig = Rig()
        defer { rig.close() }
        try #require(rig.midi.available)
        let peer = try Peer()
        let dests = await Peer.endpoints(sources: false)
        try #require(!dests.isEmpty)

        // MIDI IN off: ignored.
        for d in dests { peer.send([0x90, 60, 100], to: d) }
        try await Task.sleep(for: .milliseconds(100))
        rig.render()
        #expect(ps_engine_active_voices(rig.engine) == 0)

        rig.midi.inputEnabled = true
        for d in dests { peer.send([0x90, 64, 100], to: d) }
        var voices: Int32 = 0
        for _ in 0..<200 where voices == 0 {
            try await Task.sleep(for: .milliseconds(5))
            rig.render()
            voices = ps_engine_active_voices(rig.engine)
        }
        #expect(voices == 1)

        for d in dests { peer.send([0xB0, 123, 0], to: d) } // all notes off
        for _ in 0..<400 where voices > 0 {
            try await Task.sleep(for: .milliseconds(5))
            rig.render(4800)
            voices = ps_engine_active_voices(rig.engine)
        }
        #expect(voices == 0)
    }

    @MainActor
    @Test func transportAndControlChangesReachTheApp() async throws {
        let rig = Rig()
        defer { rig.close() }
        try #require(rig.midi.available)
        var transport: [MIDIManager.Transport] = []
        var controls: [[Int]] = []
        rig.midi.onTransport = { transport.append($0) }
        rig.midi.onControl = { controls.append([$0, $1, $2]) }
        rig.midi.inputEnabled = true

        let peer = try Peer()
        let dests = await Peer.endpoints(sources: false)
        try #require(!dests.isEmpty)
        for d in dests {
            peer.send([0xFA], to: d)
            peer.send([0xB3, 1, 90], to: d)
        }
        for _ in 0..<200 where transport.isEmpty || controls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.first == .start)
        #expect(controls.first == [3, 1, 90])
    }
}
