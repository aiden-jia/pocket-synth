import AVFoundation
import SynthDSP

/// Owns the audio session and AVAudioEngine, and pulls audio from the C engine.
///
/// The engine renders through an AVAudioSourceNode (DESIGN §10, phase 2 notes).
@MainActor
public final class AudioHost {
    private let avEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    public private(set) var sampleRate: Double = 48_000

    public init() {}

    /// The IO buffer we ask for: 64 frames (1.3 ms at 48 kHz), the smallest iOS grants on
    /// the built-in speaker. It is the biggest part of touch-to-sound delay we control.
    /// (Bluetooth outputs ignore it and use their own, much longer, buffers.)
    nonisolated static let preferredBufferSeconds = 64.0 / 48_000.0

    /// The IO buffer the system actually granted, in frames.
    public var ioBufferFrames: Int {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        return Int((s.ioBufferDuration * s.sampleRate).rounded())
        #else
        return 0
        #endif
    }

    /// Configures the session and returns the hardware sample rate to build the engine with.
    @discardableResult
    public func prepareSession() -> Double {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(Self.preferredBufferSeconds)
            try session.setActive(true)
        } catch {
            print("AudioHost: session setup failed: \(error)")
        }
        sampleRate = session.sampleRate
        print("AudioHost: \(Int(sampleRate)) Hz, IO buffer \(ioBufferFrames) frames, output latency \(Int(session.outputLatency * 1000)) ms")
        #else
        sampleRate = avEngine.outputNode.outputFormat(forBus: 0).sampleRate
        #endif
        return sampleRate
    }

    public func start(rendering engine: OpaquePointer) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = Self.makeSourceNode(engine: engine, format: format)
        avEngine.attach(node)
        avEngine.connect(node, to: avEngine.mainMixerNode, format: format)
        sourceNode = node
        try avEngine.start()
        observeInterruptions()
    }

    /// Built outside the main actor on purpose: the render block runs on the audio thread
    /// and must not inherit main-actor isolation (Swift 6 would trap on the isolation check).
    nonisolated private static func makeSourceNode(engine: OpaquePointer,
                                                   format: AVAudioFormat) -> AVAudioSourceNode {
        nonisolated(unsafe) let engine = engine
        return AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            // The host time lets the engine timestamp MIDI in step with this buffer.
            let ts = timestamp.pointee
            if ts.mFlags.contains(.hostTimeValid) {
                ps_engine_render_at(engine, left, right, Int32(frameCount), ts.mHostTime)
            } else {
                ps_engine_render(engine, left, right, Int32(frameCount))
            }
            return noErr
        }
    }

    /// Stops rendering. Do this before the engine it renders is destroyed.
    public func stop() {
        avEngine.stop()
    }

    /// Output latency (seconds): audio rendered now is heard this much later.
    public var outputLatency: Double {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        return s.outputLatency + s.ioBufferDuration
        #else
        return 0.01
        #endif
    }

    /// Input latency (seconds): how late recorded audio arrives.
    public var inputLatency: Double {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        return inputEnabled ? s.inputLatency : 0
        #else
        return 0
        #endif
    }

    // MARK: Input (sampling)

    public private(set) var inputEnabled = false
    /// The input's own rate (mic takes are tagged with it so they play at the right pitch).
    public private(set) var inputSampleRate = 48_000.0

    /// Asks for the microphone, switches the session to play-and-record and streams input
    /// to `push` (called on the tap's thread). Returns false when access is denied.
    public func enableInput(push: @escaping @Sendable (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) async -> Bool {
        if inputEnabled { return true }
        #if os(iOS)
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(Self.preferredBufferSeconds)
            try session.setActive(true)
        } catch {
            return false
        }
        #endif
        let input = avEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return false }
        inputSampleRate = format.sampleRate
        Self.installTap(on: input, format: format, push: push)
        if !avEngine.isRunning { try? avEngine.start() }
        inputEnabled = true
        return true
    }

    public func disableInput() {
        guard inputEnabled else { return }
        avEngine.inputNode.removeTap(onBus: 0)
        inputEnabled = false
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredIOBufferDuration(Self.preferredBufferSeconds)
        #endif
        if !avEngine.isRunning { try? avEngine.start() }
    }

    /// Outside the main actor: the tap block runs on an audio thread.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               push: @escaping @Sendable (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let right = buffer.format.channelCount > 1 ? data[1] : data[0]
            push(data[0], right, n)
        }
    }

    private func observeInterruptions() {
        #if os(iOS)
        let center = NotificationCenter.default
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.avEngine.isRunning else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.avEngine.start()
            }
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main, using: restart))
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main, using: restart))
        // Switching to play-and-record (sampling) reconfigures the engine and stops it.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: avEngine, queue: .main, using: restart))
        #endif
    }
}
