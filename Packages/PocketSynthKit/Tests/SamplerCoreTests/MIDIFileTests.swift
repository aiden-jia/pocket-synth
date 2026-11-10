import Foundation
import Testing
@testable import SamplerCore

@Suite("MIDI file export")
struct MIDIFileTests {
    @Test func headerTracksAndEvents() {
        var seq = PadSequence(name: "S", bars: 1)
        seq.add(tick: 0, length: 240, pad: 0, velocity: 100)       // drum A01 → note 36, ch 10
        seq.tracks.append(Track(name: "Keys", program: .midi(channel: 3)))
        seq.add(track: 1, tick: 960, length: 480, pad: 60, velocity: 80)
        let d = [UInt8](MIDIFile.make(seq, bpm: 120))
        #expect(Array(d[0..<4]) == Array("MThd".utf8))
        #expect(d[9] == 1 && d[11] == 3)                 // format 1, 3 tracks
        #expect(Int(d[12]) << 8 | Int(d[13]) == 960)     // PPQN
        // Tempo 120 = 500 000 µs per quarter.
        let tempo: [UInt8] = [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
        #expect(d.indices.contains { Array(d[$0..<min(d.count, $0 + 6)]) == tempo })
        #expect(d.indices.contains { Array(d[$0..<min(d.count, $0 + 3)]) == [0x99, 36, 100] })
        #expect(d.indices.contains { Array(d[$0..<min(d.count, $0 + 3)]) == [0x92, 60, 80] })
    }

    @Test func variableLengthQuantities() {
        #expect(MIDIFile.vlq(0) == [0])
        #expect(MIDIFile.vlq(127) == [0x7F])
        #expect(MIDIFile.vlq(128) == [0x81, 0x00])
        #expect(MIDIFile.vlq(3840) == [0x9E, 0x00])
    }
}
