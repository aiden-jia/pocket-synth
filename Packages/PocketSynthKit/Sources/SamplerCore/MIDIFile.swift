import Foundation

/// Standard MIDI File export (SAMPLER_SPEC §10): type 1, 960 PPQN, a conductor track
/// with tempo and time signature, then one track per sequence track.
public enum MIDIFile {
    /// Drum pads become GM-style notes from C1 (pad A01 = 36) on channel 10.
    public static func drumNote(pad: Int) -> Int { min(127, 36 + pad) }

    public static func make(_ seq: PadSequence, bpm: Double) -> Data {
        var tracks: [Data] = []
        // Conductor
        var conductor = Data()
        conductor.append(contentsOf: vlq(0) + [0xFF, 0x51, 0x03])
        let usPerQuarter = Int((60_000_000 / max(1, bpm)).rounded())
        conductor.append(contentsOf: [UInt8(usPerQuarter >> 16 & 0xff), UInt8(usPerQuarter >> 8 & 0xff), UInt8(usPerQuarter & 0xff)])
        conductor.append(contentsOf: vlq(0) + [0xFF, 0x58, 0x04, UInt8(seq.beatsPerBar), 0x02, 0x18, 0x08])
        conductor.append(contentsOf: vlq(seq.lengthTicks) + [0xFF, 0x2F, 0x00])
        tracks.append(conductor)

        for (i, t) in seq.tracks.enumerated() {
            let channel: Int
            switch t.program {
            case .drum: channel = 9
            case .midi(let ch): channel = max(0, min(15, ch - 1))
            default: channel = i % 16 == 9 ? 10 : i % 16
            }
            // (tick, order, bytes): offs sort before ons at the same tick.
            var events: [(Int, Int, [UInt8])] = []
            for e in t.events {
                let note = UInt8(t.program == .drum ? drumNote(pad: e.pad) : max(0, min(127, e.pad)))
                events.append((e.tick, 1, [UInt8(0x90 | channel), note, UInt8(max(1, min(127, e.velocity)))]))
                events.append((min(seq.lengthTicks, e.tick + max(1, e.length)), 0, [UInt8(0x80 | channel), note, 64]))
            }
            events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            var d = Data()
            let name = Array(t.name.utf8.prefix(127))
            d.append(contentsOf: vlq(0) + [0xFF, 0x03, UInt8(name.count)] + name)
            var last = 0
            for (tick, _, bytes) in events {
                d.append(contentsOf: vlq(tick - last) + bytes)
                last = tick
            }
            d.append(contentsOf: vlq(max(0, seq.lengthTicks - last)) + [0xFF, 0x2F, 0x00])
            tracks.append(d)
        }

        var out = Data("MThd".utf8)
        out.append(contentsOf: be32(6) + be16(1) + be16(tracks.count) + be16(PPQN.ticks))
        for t in tracks {
            out.append(contentsOf: Array("MTrk".utf8) + be32(t.count))
            out.append(t)
        }
        return out
    }

    /// Variable-length quantity.
    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes = [UInt8(v & 0x7f)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7f) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }

    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
}
