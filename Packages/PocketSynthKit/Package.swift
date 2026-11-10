// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketSynthKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChordTheory", targets: ["ChordTheory"]),
        .library(name: "SynthCore", targets: ["SynthCore"]),
        .library(name: "SamplerCore", targets: ["SamplerCore"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "DSPKit", targets: ["DSPKit"]),
        .library(name: "PocketUI", targets: ["PocketUI"]),
    ],
    targets: [
        // Pure music theory: scales, chord types, joystick modifier tables, voicer.
        .target(name: "ChordTheory"),
        // Synth panel brain: control events, gesture/menu state machine, session state.
        .target(name: "SynthCore", dependencies: ["ChordTheory"]),
        // Sampler panel brain: drum program model, pad/bank logic, project persistence.
        .target(name: "SamplerCore"),
        // Real-time DSP core (C++ with a C API so Swift imports it without interop flags).
        .target(name: "SynthDSP"),
        // Offline audio work: onset/BPM detection, time-stretch, pitch-shift, processes.
        .target(name: "DSPKit"),
        // Swift side of the engine: command bridge + AVAudioEngine host.
        .target(name: "AudioEngine", dependencies: ["SynthDSP", "SynthCore", "SamplerCore"]),
        // SwiftUI panels and the multitouch play surface.
        .target(name: "PocketUI", dependencies: ["SynthCore", "SamplerCore", "AudioEngine", "DSPKit", "SynthDSP"]),

        .testTarget(name: "ChordTheoryTests", dependencies: ["ChordTheory"]),
        .testTarget(name: "SynthCoreTests", dependencies: ["SynthCore"]),
        .testTarget(name: "SamplerCoreTests", dependencies: ["SamplerCore"]),
        .testTarget(name: "SynthDSPTests", dependencies: ["SynthDSP"]),
        .testTarget(name: "DSPKitTests", dependencies: ["DSPKit"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "ChordTheory", "SynthCore", "SamplerCore", "SynthDSP"]),
    ],
    cxxLanguageStandard: .cxx20
)
