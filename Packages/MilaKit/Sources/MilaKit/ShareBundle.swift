import CryptoKit
import Foundation

/// A `.milashare` bundle as the iPad app reads and writes it.
///
/// The Mac app's `ShareManifest` (Mila/Models/ShareManifest.swift) is the
/// format's owner; this is a lean mirror of the subset another device needs
/// to show a recording and to publish one of its own, so the iPad does not
/// pull in the Mac app's `Recording`. It stays in step with the Mac's through
/// `ShareBundleCompatibilityTests` in MilaTests, which round-trips manifests
/// and archives in both directions. Unknown keys are ignored on decode
/// (voice profiles, action items, …), so a fuller Mac bundle still opens.
///
/// Container rules are the Mac importer's: exactly `manifest.json`, one
/// `audio.wav|m4a` and an optional `transcript.txt`, each a regular file,
/// checked from the central directory before anything is extracted; then the
/// audio's size and SHA-256 against the manifest.
public enum ShareBundle {
    public static let fileExtension = "milashare"
    public static let manifestName = "manifest.json"
    public static let transcriptName = "transcript.txt"
    public static let audioNames: Set<String> = ["audio.wav", "audio.m4a"]
    public static let currentVersion = 1
    /// Same ceilings as `RecordingShareImporter` on the Mac.
    public static let maxBytes: UInt64 = 4 << 30
    public static let maxTextBytes: UInt64 = 16 << 20
    /// `ShareManifest.maxTimeSeconds`: time values past this would trap the
    /// `Int` conversions that render them.
    public static let maxTimeSeconds: Double = 7 * 24 * 60 * 60

    public struct Manifest: Codable, Equatable, Sendable {
        public var version: Int
        public var bundleID: UUID
        public var exportedAt: Date
        public var exportedBy: Exporter
        public var recording: Recording
        public var audio: Audio
        public var transcript: Transcript?

        public struct Exporter: Codable, Equatable, Sendable { public var name: String }
        public struct Transcript: Codable, Equatable, Sendable { public var fileName: String }
        public struct Audio: Codable, Equatable, Sendable {
            public var fileName: String
            public var format: String
            public var byteCount: Int64
            public var sha256: String
        }
    }

    /// `ShareManifest.RecordingPayload`, minus action items and the summary
    /// language (shown nowhere on the iPad, and never re-published from it).
    public struct Recording: Codable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var duration: Double
        /// Raw `RecordingSource` — the iPad writes `microphone`.
        public var source: String
        public var language: String
        public var modelName: String?
        public var segments: [Segment]
        public var speakerNames: [String: String]
        public var summary: String?

        public init(id: UUID = UUID(), title: String, createdAt: Date, duration: Double,
                    source: String = "microphone", language: String, modelName: String? = nil,
                    segments: [Segment] = [], speakerNames: [String: String] = [:], summary: String? = nil) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.duration = duration
            self.source = source
            self.language = language
            self.modelName = modelName
            self.segments = segments
            self.speakerNames = speakerNames
            self.summary = summary
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, createdAt, duration, source, language, modelName, segments, speakerNames, summary
        }

        /// Lenient like `RecordingPayload`: only `id` and `createdAt` are required.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? "microphone"
            language = try c.decodeIfPresent(String.self, forKey: .language) ?? "he"
            modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
            segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
            speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
        }

        /// The transcript as text, speaker names resolved.
        public var text: String {
            TranscriptFormatter.plainText(segments: segments,
                                          fallback: TranscriptFormatter.joinedFullText(segments: segments),
                                          names: speakerNames)
        }
    }

    public struct Segment: Codable, Equatable, Sendable, SpeakerTextSegment {
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: String?

        public init(start: Double, end: Double, text: String, speaker: String? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }

        var isSound: Bool {
            start.isFinite && end.isFinite && start >= 0 && end >= start && end <= ShareBundle.maxTimeSeconds
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case malformed(String)
        case unsupportedVersion(Int)
        case integrity(String)

        public var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "Not a valid Mila shared recording: \(detail)"
            case .unsupportedVersion(let v): return "This shared recording needs a newer Mila (format v\(v))."
            case .integrity(let detail): return "The shared recording appears to be damaged: \(detail)"
            }
        }
    }

    // MARK: - Pack

    /// Write `recording` with its audio (`.wav` or `.m4a`) and transcript as
    /// a `.milashare` at `archive`. The manifest and transcript are staged in
    /// a temporary directory; the audio is streamed from where it is.
    public static func pack(_ recording: Recording, audio: URL, exportedBy: String,
                            now: Date = Date(), to archive: URL) throws {
        let ext = audio.pathExtension.lowercased()
        let audioName = "audio.\(ext)"
        guard audioNames.contains(audioName) else { throw Failure.malformed("audio must be .wav or .m4a") }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("milashare-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var files: [(name: String, url: URL)] = []
        let text = recording.text
        var transcript: Manifest.Transcript?
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = staging.appendingPathComponent(transcriptName)
            try Data(text.utf8).write(to: url)
            files.append((transcriptName, url))
            transcript = .init(fileName: transcriptName)
        }
        let size = (try fm.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.int64Value ?? 0
        let manifest = Manifest(
            version: currentVersion, bundleID: UUID(), exportedAt: now,
            exportedBy: .init(name: exportedBy), recording: recording,
            audio: .init(fileName: audioName, format: ext, byteCount: size, sha256: try sha256Hex(of: audio)),
            transcript: transcript)
        let manifestURL = staging.appendingPathComponent(manifestName)
        try encoder().encode(manifest).write(to: manifestURL)
        files.insert((manifestName, manifestURL), at: 0)
        files.append((audioName, audio))
        try ShareZip.write(files, to: archive)
    }

    // MARK: - Unpack

    public struct Unpacked: Sendable {
        public let manifest: Manifest
        public let audio: URL
        public let transcript: String?
    }

    /// Verify and extract `archive` into `directory` (created if needed).
    /// Throws without extracting anything when the central directory is not
    /// a bundle's; throws after extracting when the contents disagree with
    /// the manifest. The caller owns `directory` and removes it on failure.
    public static func unpack(_ archive: URL, into directory: URL) throws -> Unpacked {
        let entries = try ShareZip.entries(of: archive)
        var seen = Set<String>()
        var total: UInt64 = 0
        for entry in entries {
            guard entry.isRegularFile else { throw Failure.malformed("an entry isn't an ordinary file") }
            guard seen.insert(entry.name).inserted else { throw Failure.malformed("an entry is listed twice") }
            switch entry.name {
            case manifestName, transcriptName:
                guard entry.uncompressedSize <= maxTextBytes else { throw Failure.malformed("a text entry is too large") }
            case let name where audioNames.contains(name):
                break
            default:
                throw Failure.malformed("unexpected entry")
            }
            total += entry.uncompressedSize
            guard total <= maxBytes else { throw Failure.malformed("too large") }
        }
        guard seen.contains(manifestName) else { throw Failure.malformed("no manifest") }
        guard seen.intersection(audioNames).count == 1 else { throw Failure.malformed("needs exactly one audio entry") }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            try ShareZip.extract(entry, from: archive, to: directory.appendingPathComponent(entry.name))
        }

        var manifest: Manifest
        do {
            manifest = try decoder().decode(Manifest.self,
                                            from: Data(contentsOf: directory.appendingPathComponent(manifestName)))
        } catch {
            throw Failure.malformed("unreadable manifest")
        }
        guard manifest.version >= 1 else { throw Failure.malformed("bad version") }
        guard manifest.version <= currentVersion else { throw Failure.unsupportedVersion(manifest.version) }
        let audio = directory.appendingPathComponent(manifest.audio.fileName)
        guard audioNames.contains(manifest.audio.fileName), seen.contains(manifest.audio.fileName),
              manifest.audio.format == audio.pathExtension else {
            throw Failure.malformed("audio entry doesn't match the manifest")
        }
        let size = (try fm.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == manifest.audio.byteCount, try sha256Hex(of: audio) == manifest.audio.sha256.lowercased() else {
            throw Failure.integrity("audio doesn't match its checksum")
        }
        let r = manifest.recording
        guard r.duration.isFinite, r.duration >= 0, r.duration <= maxTimeSeconds else {
            throw Failure.malformed("bad duration")
        }
        manifest.recording.segments = r.segments.filter(\.isSound)
        if r.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.recording.title = "Shared recording"
        }
        let transcriptURL = directory.appendingPathComponent(transcriptName)
        let transcript = seen.contains(transcriptName)
            ? String(decoding: try Data(contentsOf: transcriptURL), as: UTF8.self) : nil
        return Unpacked(manifest: manifest, audio: audio, transcript: transcript)
    }

    // MARK: - Helpers

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
