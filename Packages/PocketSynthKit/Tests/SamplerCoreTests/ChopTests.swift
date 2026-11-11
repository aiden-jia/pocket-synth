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

    // Processes on slice pads (SAMPLER_SPEC §5.3): only the processed slice changes.

    func sliced() -> (SamplerController, SampleInfo) {
        let (c, info) = make()
        c.assignSlices([0..<24_000, 24_000..<48_000, 48_000..<96_000], of: info.id)
        return (c, info)
    }

    func trims(_ c: SamplerController) -> [PadLayer] { (0..<3).map { c.project.program.pads[$0].layers[0] } }

    @Test func slicePadTargetsItsSliceOnly() throws {
        let (c, info) = sliced()
        let t = try #require(c.processTarget(pad: 1))
        #expect(t.sample == info.id && t.trim == 24_000..<48_000 && t.slice == 24_000..<48_000)
        let last = try #require(c.processTarget(pad: 2))
        #expect(last.slice == 48_000..<96_000) // runs to the sample's end, still a slice
    }

    @Test func processingASliceLeavesTheOtherSlicePadsAlone() throws {
        let (c, info) = sliced()
        let before = trims(c)
        let t = try #require(c.processTarget(pad: 1))
        let shifted = SampleInfo(id: SampleID("shifted"), name: "Loop B02", fileName: "s.wav", frames: 24_000,
                                 sampleRate: 48_000, channels: 2)
        c.applyProcessed(t, new: shifted, label: "Pitch shift")
        let after = trims(c)
        #expect(after[1].sampleID == shifted.id && after[1].start == 0 && after[1].end == nil)
        #expect(after[0] == before[0] && after[2] == before[2])
        #expect(c.project.sample(info.id)?.archived == false) // the others still use it
        #expect(Set(c.visibleSamples.map(\.id)) == [info.id, shifted.id])
    }

    @Test func timeStretchingASliceDoesNotResetTheOthers() throws {
        let (c, _) = sliced()
        let before = trims(c)
        let t = try #require(c.processTarget(pad: 0))
        let stretched = SampleInfo(id: SampleID("long"), name: "Loop A01", fileName: "l.wav", frames: 36_000,
                                   sampleRate: 48_000, channels: 2)
        c.applyProcessed(t, new: stretched, label: "Time stretch")
        let after = trims(c)
        #expect(after[0].sampleID == stretched.id && after[0].start == 0 && after[0].end == nil)
        #expect(after[1] == before[1] && after[2] == before[2])
        #expect(after[2].start == 48_000 && after[1].end == 48_000)
    }

    @Test func undoingASliceProcessRestoresEveryPad() throws {
        let (c, _) = sliced()
        let before = trims(c)
        let t = try #require(c.processTarget(pad: 2))
        c.updatePad(2) { $0.layers[0].tune = 5 } // per-pad settings survive the process
        let new = SampleInfo(id: SampleID("rev"), name: "Loop A03", fileName: "r.wav", frames: 48_000,
                             sampleRate: 48_000, channels: 2)
        c.applyProcessed(try #require(c.processTarget(pad: 2)), new: new, label: "Reverse")
        #expect(c.project.program.pads[2].layers[0].tune == 5)
        #expect(t.slice == 48_000..<96_000)
        c.undo()
        #expect(c.project.program.pads[2].layers[0].sampleID == before[2].sampleID)
        #expect(c.project.program.pads[2].layers[0].start == 48_000)
        #expect(c.project.program.pads[2].layers[0].tune == 5) // one step: only the process undone
        c.undo()
        #expect(trims(c) == before)
        c.redo(); c.redo()
        #expect(c.project.program.pads[2].layers[0].sampleID == new.id)
    }

    @Test func wholeSampleAndUnsharedPadsStillReplaceEverywhere() throws {
        let (c, info) = make()
        c.assign(info.id, to: 0)
        c.assign(info.id, to: 1)
        let whole = try #require(c.processTarget(pad: 0))
        #expect(whole.slice == nil && whole.trim == 0..<96_000)
        let v2 = SampleInfo(id: SampleID("v2"), name: "Loop", fileName: "v2.wav", frames: 48_000, sampleRate: 48_000, channels: 2)
        c.applyProcessed(whole, new: v2, label: "Time stretch")
        #expect(c.project.program.pads[0].layers[0].sampleID == v2.id && c.project.program.pads[1].layers[0].sampleID == v2.id)
        #expect(c.project.sample(info.id)?.archived == true)

        // A trimmed pad that is the sample's only user: the whole sample, as before.
        let (d, solo) = make()
        d.assignSlices([1_000..<20_000], of: solo.id)
        let t = try #require(d.processTarget(pad: 0))
        #expect(t.slice == nil && t.trim == 1_000..<20_000)
        let v3 = SampleInfo(id: SampleID("v3"), name: "Loop", fileName: "v3.wav", frames: 96_000, sampleRate: 48_000, channels: 2)
        d.applyProcessed(t, new: v3, label: "Gain")
        #expect(d.project.program.pads[0].layers[0].sampleID == v3.id)
        #expect(d.project.program.pads[0].layers[0].start == 1_000) // same length: trim kept
    }

    @Test func aSliceSharedWithAKeygroupIsStillASlice() throws {
        let (c, info) = make()
        c.assignSlices([0..<10_000], of: info.id)
        var k = KeygroupProgram(name: "Loop")
        k.zones = [KeygroupZone(lowNote: 0, highNote: 127, rootNote: 60, sample: info.id)]
        _ = c.addKeygroup(k)
        #expect(try #require(c.processTarget(pad: 0)).slice == 0..<10_000)
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
