import Foundation
import Testing
@testable import DSPKit

@Suite("Tuner and Mic-mode helpers")
struct MicToolTests {
    func tone(_ hz: Double, seconds: Double, amp: Float = 0.5, sr: Double = 48_000) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }
    }

    @Test func tunerFindsThePitchOfAShortFrame() {
        let hz = PitchDetect.tunerHz(Array(tone(196, seconds: 0.1).prefix(4096)), sampleRate: 48_000)
        #expect(abs((hz ?? 0) - 196) < 1, "\(String(describing: hz))")
        #expect(PitchDetect.tunerHz(Array(tone(196, seconds: 0.1, amp: 0.001).prefix(4096)), sampleRate: 48_000) == nil)
    }

    @Test func micTakeKeepsOneSecondFromTheOnset() {
        let sr = 48_000.0
        let x = [Float](repeating: 0, count: Int(0.7 * sr)) + tone(330, seconds: 2)
        let clip = PitchDetect.micTake(AudioData(mono: x, sampleRate: sr))!
        #expect(clip.frames == Int(sr))           // 10 ms before the onset + 990 ms of tone
        #expect(abs(clip.channels[0][0]) < 1e-6)  // starts in the silence, faded in
        #expect(abs(PitchDetect.midiPitch(PitchDetect.hz(clip)!) - 64) < 0.1) // E4
        #expect(PitchDetect.micTake(AudioData(mono: [Float](repeating: 0.001, count: 48_000), sampleRate: sr)) == nil)
    }
}
