import Foundation
import Testing
@testable import SamplerCore

func info(_ name: String, frames: Int = 48_000) -> SampleInfo {
    SampleInfo(name: name, fileName: "\(name).wav", frames: frames, sampleRate: 48_000, channels: 1)
}

@Suite("Pad addressing")
struct AddressTests {
    @Test func names() {
        #expect(PadAddress.name(0) == "A01")
        #expect(PadAddress.name(15) == "A16")
        #expect(PadAddress.name(16) == "B01")
        #expect(PadAddress.name(127) == "H16")
    }

    @Test func gridMapping() {
        #expect(PadAddress.gridIndex(row: 3, column: 0) == 0)   // bottom-left = 1
        #expect(PadAddress.gridIndex(row: 0, column: 3) == 15)  // top-right = 16
        #expect(PadAddress.pad(bank: 2, gridIndex: 4) == 36)
    }

    @Test func velocityModes() {
        #expect(VelocityMode.position.velocity(y: 0, size: 0) == 127)
        #expect(VelocityMode.position.velocity(y: 1, size: 0) == 20)
        #expect(VelocityMode.touchSize.velocity(y: 0, size: 1) == 127)
        #expect(VelocityMode.fixed.velocity(y: 0.9, size: 0.1) == 104)
    }
}

@Suite("Pad model")
struct PadModelTests {
    @Test func velocityLayerSelection() {
        var pad = Pad()
        var soft = PadLayer(sampleID: SampleID("soft"))
        soft.velocityHigh = 63
        var hard = PadLayer(sampleID: SampleID("hard"))
        hard.velocityLow = 64
        pad.layers = [soft, hard, PadLayer()]
        #expect(pad.layers(forVelocity: 30).map(\.sampleID) == [SampleID("soft")])
        #expect(pad.layers(forVelocity: 100).map(\.sampleID) == [SampleID("hard")])
        #expect(pad.primarySample == SampleID("soft"))
    }

    @Test func projectRoundTripsThroughJSON() throws {
        var p = SamplerProject()
        p.samples = [info("kick")]
        p.program.pads[5].layers[0].sampleID = p.samples[0].id
        p.program.pads[5].muteGroup = 3
        p.mixer.samplerLevel = 0.7
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(SamplerProject.self, from: data) == p)
    }

    @Test func storeSavesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir)
        #expect(store.load() == nil)
        var p = SamplerProject()
        p.samples = [info("snare")]
        try store.save(p)
        #expect(store.load() == p)

        let src = dir.appendingPathComponent("in.WAV")
        try Data([1, 2, 3]).write(to: src)
        let id = SampleID("abc")
        let dest = try store.importFile(src, id: id)
        #expect(dest.lastPathComponent == "abc.wav")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }
}

@MainActor
@Suite("Sampler controller")
struct SamplerControllerTests {
    @MainActor final class Rig {
        var sent: [SamplerCommand] = []
        var saves = 0
        let c = SamplerController()
        init() {
            c.send = { [unowned self] in self.sent.append($0) }
            c.onChange = { [unowned self] _ in self.saves += 1 }
        }
    }

    @Test func padHitsUseBankAndVelocity() {
        let r = Rig()
        r.c.bank = 1
        r.c.padDown(gridIndex: 2, y: 0)
        #expect(r.sent.last == .trigger(pad: 18, velocity: 127))
        #expect(r.c.selectedPad == 18)
        #expect(r.c.heldPads == [18])
        r.c.padUp(gridIndex: 2)
        #expect(r.sent.last == .release(pad: 18))
        #expect(r.c.heldPads.isEmpty)
        r.c.fullLevel = true
        r.c.padDown(gridIndex: 0, y: 1)
        #expect(r.sent.last == .trigger(pad: 16, velocity: 127))
    }

    @Test func addSamplesAutoAssignsToNextEmptyPads() {
        let r = Rig()
        r.c.addSamples([info("one")])
        r.c.selectedPad = 0
        let used = r.c.addSamples([info("kick"), info("snare"), info("hat")])
        #expect(used == [1, 2, 3])          // pad 0 is taken by "one"
        #expect(r.c.project.samples.count == 4)
        #expect(r.c.project.program.pads[2].primarySample == r.c.project.samples[2].id)
        #expect(r.sent.contains { if case .pad(3, _) = $0 { true } else { false } })
        #expect(r.saves == 2)
    }

    @Test func removeSampleClearsPads() {
        let r = Rig()
        let s = info("kick")
        r.c.addSamples([s])
        r.c.assign(s.id, to: 40)
        r.c.removeSample(s.id)
        #expect(r.c.project.samples.isEmpty)
        #expect(r.c.project.program.pads[0].isEmpty)
        #expect(r.c.project.program.pads[40].isEmpty)
    }

    @Test func trimIsClamped() {
        let r = Rig()
        let s = info("loop", frames: 1000)
        r.c.addSamples([s])
        r.c.setTrim(pad: 0, start: 900, end: 100)
        let layer = r.c.project.program.pads[0].layers[0]
        #expect(layer.start == 900)
        #expect(layer.end == 902)
        r.c.setTrim(pad: 0, start: -5, end: 5000)
        #expect(r.c.project.program.pads[0].layers[0].start == 0)
        #expect(r.c.project.program.pads[0].layers[0].end == nil) // full length
    }

    @Test func editsSendPadAndSkipNoOps() {
        let r = Rig()
        r.c.updateSelected { $0.muteGroup = 2 }
        #expect(r.sent.last == .pad(0, r.c.project.program.pads[0]))
        let count = r.sent.count
        r.c.updateSelected { $0.muteGroup = 2 }
        #expect(r.sent.count == count)
        r.c.updateSelected { $0.layers = [] }               // never fewer than one layer
        #expect(r.c.project.program.pads[0].layers.count == 1)
    }

    @Test func startSendsNonEmptyPadsAndMixer() {
        let r = Rig()
        r.c.addSamples([info("a"), info("b")])
        r.sent.removeAll()
        r.c.start()
        let pads = r.sent.filter { if case .pad = $0 { true } else { false } }
        #expect(pads.count == 2)
        #expect(r.sent.contains(.mixer(SamplerMixer())))
        #expect(r.sent.last == .sequence(r.c.sequence))
    }
}
