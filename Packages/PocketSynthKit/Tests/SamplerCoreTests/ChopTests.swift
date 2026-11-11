import Foundation
import Testing
@testable import SamplerCore

@Suite("Chop session")
struct ChopSessionTests {
    func session() -> ChopSession { ChopSession(sample: SampleID("s"), frames: 48_000, sampleRate: 48_000) }

    @Test func markersStayCleanAndSlicesCoverTheSample() {
        var c = session()
        c.setMarkers([12_000, 0, 24_000, 12_000, 60_000, -5])
        #expect(c.markers == [0, 12_000, 24_000])
        #expect(c.slices == [0..<12_000, 12_000..<24_000, 24_000..<48_000])
        #expect(c.slice(containing: 30_000) == 2)
    }

    @Test func manualEdits() {
        var c = session()
        c.addMarker(at: 10_000)
        c.addMarker(at: 30_000)
        #expect(c.markers == [0, 10_000, 30_000] && c.selected == 2)
        c.moveMarker(1, to: 40_000)            // can't pass its neighbour
        #expect(c.markers[1] == 29_999)
        c.moveMarker(0, to: 5)                 // marker 0 is fixed
        #expect(c.markers[0] == 0)
        c.split(0)
        #expect(c.markers.count == 4)
        c.mergeWithNext(0)
        #expect(c.markers.count == 3)
        c.removeMarker(0)
        #expect(c.markers.first == 0)
    }
}

@MainActor
@Suite("Chop conversions and sample versions")
struct ChopConversionTests {
    func make() -> (SamplerController, SampleInfo) {
        let c = SamplerController()
        var t = 0.0
        c.now = { t += 10; return t }
        let info = SampleInfo(id: SampleID("loop"), name: "Loop", fileName: "loop.wav", frames: 96_000,
                              sampleRate: 48_000, channels: 2)
        c.addSamples([info], autoAssign: false)
        return (c, info)
    }

    @Test func slicesGoOnPadsAsTrims() {
        let (c, info) = make()
        let used = c.assignSlices([0..<24_000, 24_000..<96_000], of: info.id, startPad: 4)
        #expect(used == [4, 5])
        #expect(c.project.program.pads[4].layers[0].end == 24_000)
        #expect(c.project.program.pads[5].layers[0].start == 24_000 && c.project.program.pads[5].layers[0].end == nil)
        c.undo()
        #expect(c.project.program.pads[4].isEmpty)
    }

    @Test func sliceSequenceReplaysOriginalTiming() {
        let (c, info) = make()
        let slices = [0..<24_000, 24_000..<48_000, 72_000..<96_000] // at 120 BPM: beats 0, 1, 3
        c.convertToSliceSequence(slices, of: info.id, startPad: 0, sampleRate: 48_000, bpm: 120)
        #expect(c.project.currentSequence == 1)
        #expect(c.sequence.bars == 1)
        #expect(c.sequence.tracks[0].events.map(\.tick) == [0, 960, 2880])
        #expect(c.sequence.tracks[0].events.map(\.pad) == [0, 1, 2])
        #expect(c.sequence.tracks[0].events[0].length == 960)
        c.undo() // one step undoes both
        #expect(c.project.sequences.count == 1 && c.project.program.pads[0].isEmpty)
    }

    @Test func firstEmptyBankSkipsUsedBanks() {
        let (c, info) = make()
        c.assignSlices([0..<10], of: info.id, startPad: 0)       // bank A used
        #expect(c.firstEmptyBank(from: 0) == 1)
        #expect(c.firstEmptyBank(from: 3) == 3)
    }

    @Test func processedVersionReplacesReferencesAndUndoGoesBack() {
        let (c, info) = make()
        c.assignSlices([0..<48_000], of: info.id)
        let v2 = SampleInfo(id: SampleID("v2"), name: "Loop", fileName: "v2.wav", frames: 48_000, sampleRate: 48_000, channels: 2)
        c.replaceSample(info.id, with: v2, label: "Time stretch")
        #expect(c.project.program.pads[0].layers[0].sampleID == v2.id)
        #expect(c.project.program.pads[0].layers[0].end == nil) // length changed: trim reset
        #expect(c.visibleSamples.map(\.id) == [v2.id])
        c.undo()
        #expect(c.project.program.pads[0].layers[0].sampleID == info.id)
        #expect(c.visibleSamples.map(\.id).contains(info.id)) // archived but in use again
        c.redo()
        let gone = c.discardUnused()
        #expect(gone.map(\.id) == [info.id])
        #expect(!c.history.canUndo)
    }

    @Test func extractedSlicesGetTheirOwnPads() {
        let (c, _) = make()
        let a = SampleInfo(name: "Loop 1", fileName: "a.wav", frames: 10, sampleRate: 48_000, channels: 1)
        let b = SampleInfo(name: "Loop 2", fileName: "b.wav", frames: 10, sampleRate: 48_000, channels: 1)
        #expect(c.assignExtracted([a, b], startPad: 16) == [16, 17])
        #expect(c.project.program.pads[17].primarySample == b.id)
    }

    @Test func oldSampleInfoDecodes() throws {
        let json = #"{"id":{"rawValue":"x"},"name":"n","fileName":"f.wav","frames":10,"sampleRate":48000,"channels":1}"#
        let i = try JSONDecoder().decode(SampleInfo.self, from: Data(json.utf8))
        #expect(!i.archived)
    }
}

@Suite("Smart chop")
struct SmartChopTests {
    func session(frames: Int = 480_000) -> ChopSession { ChopSession(sample: SampleID("s"), frames: frames, sampleRate: 48_000) }

    @Test func searchWindowStaysInsideAndWideEnough() {
        var c = session()
        c.centerSearch(at: 100_000)
        #expect(c.searchRange == 92_800..<107_200)          // 300 ms default
        c.centerSearch(at: 1_000)                           // same width, pushed inside
        #expect(c.searchRange == 0..<14_400)
        c.setSearchRange(470_000, 900_000)
        #expect(c.searchRange == 470_000..<480_000)
        c.setSearchRange(5_000, 5_010)                      // too narrow: 20 ms minimum
        #expect(c.searchRange == 5_000..<5_960)
        c.setSearchRange(479_900, 479_950)                  // too narrow at the very end
        #expect(c.searchRange == 479_040..<480_000)
        c.moveSearch(to: 1_000_000)
        #expect(c.searchRange == 479_040..<480_000)
        c.moveSearch(to: -10)
        #expect(c.searchRange == 0..<960)
    }

    @Test func shortSampleGetsAShortWindow() {
        var c = session(frames: 24_000)                     // 0.5 s
        c.centerSearch(at: 12_000)
        #expect(c.searchRange?.count == 2_400)
    }

    @Test func movingTheWindowDropsTheOldSnap() {
        var c = session()
        c.centerSearch(at: 100_000)
        c.snapFrame = 99_000
        c.setSearchRange(92_800, 107_200)                   // unchanged: snap kept
        #expect(c.snapFrame == 99_000)
        c.moveSearch(to: 200_000)
        #expect(c.snapFrame == nil)
    }

    @Test func addsASliceAtTheSnapOnce() {
        var c = session()
        c.centerSearch(at: 100_000)
        #expect(c.addSnappedMarker() == nil)                 // nothing found yet
        c.snapFrame = 98_765
        #expect(c.addSnappedMarker() == 1)
        #expect(c.markers == [0, 98_765] && c.selected == 1)
        #expect(c.addSnappedMarker() == nil)                 // already there
        c.snapFrame = 0
        #expect(c.addSnappedMarker() == nil)                 // slice 0 always starts at 0
        c.clearSearch()
        #expect(c.searchRange == nil && c.snapFrame == nil)
    }
}
