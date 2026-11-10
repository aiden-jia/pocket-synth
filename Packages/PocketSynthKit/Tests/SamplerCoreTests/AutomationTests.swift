import Foundation
import Testing
@testable import SamplerCore

@Suite("Automation lanes")
struct AutomationLaneTests {
    @Test func interpolatesAndHolds() {
        var l = AutomationLane(param: .samplerLevel)
        l.write(0, at: 0, from: nil)
        l.write(1, at: 960, from: nil)
        #expect(l.value(at: -10) == 0 && l.value(at: 480) == 0.5 && l.value(at: 2000) == 1)
    }

    @Test func writingSweepsOverOldPoints() {
        var l = AutomationLane(param: .xyX)
        for t in stride(from: 0, through: 960, by: 120) { l.write(0.2, at: t, from: nil) }
        l.write(0.9, at: 480, from: 100)   // the knob swept 100…480
        #expect(l.points.map(\.tick) == [0, 480, 600, 720, 840, 960])
        #expect(l.value(at: 480) == 0.9)
    }
}

@MainActor
@Suite("Automation and Q-Links in the controller")
struct AutomationControllerTests {
    final class Sink { var commands: [SamplerCommand] = [] }

    func make() -> (SamplerController, Sink) {
        let sink = Sink()
        let c = SamplerController(send: { sink.commands.append($0) })
        var t = 0.0
        c.now = { t += 10; return t }
        return (c, sink)
    }

    @Test func writeRecordsWhilePlayingAndReadPlaysBack() {
        let (c, _) = make()
        c.automationMode = .write
        c.play()
        c.poll(hits: [], position: 0, enginePlaying: true)
        c.setParam(.samplerLevel, 0.2)
        c.poll(hits: [], position: 960, enginePlaying: true)
        c.setParam(.samplerLevel, 1.0)
        c.endParam(.samplerLevel)
        let lane = c.track.automation.first { $0.param == .samplerLevel }
        #expect(lane?.points.map(\.tick) == [0, 960])
        // Played back: half way is 0.6.
        c.automationMode = .read
        c.poll(hits: [], position: 480, enginePlaying: true)
        #expect(abs(c.project.mixer.samplerLevel - 0.6) < 1e-9)
    }

    @Test func aTouchedKnobIsntOverridden() {
        let (c, _) = make()
        c.automationMode = .write
        c.play()
        c.poll(hits: [], position: 0, enginePlaying: true)
        c.setParam(.xyY, 0.1)
        c.endParam(.xyY)
        c.automationMode = .read
        c.setParam(.xyY, 0.8)               // held by hand
        c.poll(hits: [], position: 500, enginePlaying: true)
        #expect(c.project.mixer.xy.y == 0.8)
        c.endParam(.xyY)
        c.poll(hits: [], position: 600, enginePlaying: true)
        #expect(c.project.mixer.xy.y == 0.1)
    }

    @Test func knobGesturesAreOneUndoStep() {
        let (c, _) = make()
        for v in [0.9, 0.7, 0.5] { c.setParam(.padLevel(0), v) }
        c.endParam(.padLevel(0))
        #expect(c.project.program.pads[0].level == 0.5)
        c.undo()
        #expect(c.project.program.pads[0].level == 1)
    }

    @Test func qlinkPagesFollowTheSelection() {
        let (c, _) = make()
        c.selectedPad = 7
        #expect(c.qlinks.first == .padLevel(7))
        c.qlinkPage = .returns
        #expect(c.qlinks == [.returnLevel(0), .returnLevel(1), .returnLevel(2), .returnLevel(3)])
        #expect(c.value(of: .returnLevel(1)) == 1)
    }

    @Test func xyMovesDontAddUndoSteps() {
        let (c, sink) = make()
        c.setXY { $0.active = true; $0.x = 0.3 }
        #expect(!c.history.canUndo)
        #expect(sink.commands.last == .xy(c.project.mixer.xy))
    }

    @Test func oldMixerDecodesWithDefaults() throws {
        let m = try JSONDecoder().decode(SamplerMixer.self, from: Data(#"{"synthLevel":0.5,"samplerLevel":1,"masterLevel":1}"#.utf8))
        #expect(m.synthLevel == 0.5 && m.submixes.count == 8 && m.returns[1].type == .hall)
        let pad = try JSONDecoder().decode(Pad.self, from: Data(#"{"level":0.4}"#.utf8))
        #expect(pad.level == 0.4 && pad.output == 0 && pad.sends == [0, 0, 0, 0])
    }
}
