import Foundation

/// Saves the sampler project as `project.json` next to a `Samples/` folder.
/// (Phase 2 keeps one project; named projects and `.psproj` packages come later.)
public struct ProjectStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `Documents/PocketSynth`, visible in the Files app.
    public static func defaultStore() -> ProjectStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ProjectStore(directory: docs.appendingPathComponent("PocketSynth", isDirectory: true))
    }

    public var projectURL: URL { directory.appendingPathComponent("project.json") }
    public var samplesDirectory: URL { directory.appendingPathComponent("Samples", isDirectory: true) }

    public func url(for sample: SampleInfo) -> URL { samplesDirectory.appendingPathComponent(sample.fileName) }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: samplesDirectory, withIntermediateDirectories: true)
    }

    public func load() -> SamplerProject? {
        guard let data = try? Data(contentsOf: projectURL) else { return nil }
        return try? JSONDecoder().decode(SamplerProject.self, from: data)
    }

    public func save(_ project: SamplerProject) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: projectURL, options: .atomic)
    }

    /// Copies an external audio file into `Samples/` under a fresh unique name.
    public func importFile(_ source: URL, id: SampleID) throws -> URL {
        try prepare()
        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension.lowercased()
        let dest = samplesDirectory.appendingPathComponent("\(id.rawValue).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    public func deleteFile(for sample: SampleInfo) {
        try? FileManager.default.removeItem(at: url(for: sample))
    }
}
