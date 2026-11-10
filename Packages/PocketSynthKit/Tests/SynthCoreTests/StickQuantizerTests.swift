import ChordTheory
import Foundation
import Testing
@testable import SynthCore

@Suite("Stick quantizer")
struct StickQuantizerTests {
    func at(_ degrees: Double, _ distance: Double = 50) -> (Double, Double) {
        let r = degrees * .pi / 180
        return (distance * cos(r), -distance * sin(r)) // screen y is down
    }

    @Test func eightSectors() {
        let expected: [(Double, StickDirection)] = [
            (0, .right), (45, .upRight), (90, .up), (135, .upLeft),
            (180, .left), (225, .downLeft), (270, .down), (315, .downRight),
        ]
        for (deg, dir) in expected {
            var q = StickQuantizer()
            let (dx, dy) = at(deg)
            #expect(q.update(dx: dx, dy: dy, radius: 60) == dir, "\(deg)°")
        }
    }

    @Test func deadzone() {
        var q = StickQuantizer()
        let (dx, dy) = at(90, 10) // 10 of 60 = inside 30% deadzone
        #expect(q.update(dx: dx, dy: dy, radius: 60) == nil)
    }

    @Test func hysteresisHoldsDirectionNearBoundary() {
        var q = StickQuantizer()
        var (dx, dy) = at(90)
        q.update(dx: dx, dy: dy, radius: 60)
        (dx, dy) = at(90 - 25) // past the 67.5° edge but inside the 6° band
        #expect(q.update(dx: dx, dy: dy, radius: 60) == .up)
        (dx, dy) = at(90 - 32)
        #expect(q.update(dx: dx, dy: dy, radius: 60) == .upRight)
    }
}
