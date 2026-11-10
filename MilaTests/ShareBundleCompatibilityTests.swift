import MilaKit
import TranscriptionCore
import XCTest
@testable import Mila

/// The iPad writes and reads `.milashare` through MilaKit's `ShareBundle` /
/// `ShareZip`, not the Mac's `ShareManifest` / `ditto`. These pin that the
/// two implementations agree, in both directions, through the Mac's real
/// exporter and importer.
@MainActor
final class ShareBundleCompatibilityTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "ShareBundleCompatibilityTests")
        scratch = TestSupport.makeTempRoot(label: "ShareBundleCompatibilityTests-scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: root)
    }

    override func tearDown() async throws {
        for url in [root, scratch] { try? FileManager.default.removeItem(at: url!) }
        try await super.tearDown()
    }

    func test_an_iPad_bundle_imports_into_the_Mac_library() async throws {
        let audio = scratch.appendingPathComponent("audio.wav")
        try TestSupport.writeSineWav(at: audio, durationSeconds: 0.2)
        let recording = ShareBundle.Recording(
            title: "On the train", createdAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 0.2,
            language: "he", modelName: "ggml-large-v3-turbo-q5_0",
            segments: [.init(start: 0, end: 0.1, text: " שלום"), .init(start: 0.1, end: 0.2, text: " לכולם")])
        let bundle = scratch.appendingPathComponent("\(recording.id.uuidString).milashare")
        try ShareBundle.pack(recording, audio: audio, exportedBy: "Lior's iPad", to: bundle)

        let importer = RecordingShareImporter(
            store: store, storageSettings: nil, profileStore: nil, voiceRecognition: nil,
            similarityThreshold: { 0.55 }, speakerDirectory: SpeakerDirectory(directory: root),
            isRecordingBusy: { _ in false }, compressImportedWAV: false,
            copyAudio: { try await RecordingShareImporter.copyFile($0, to: $1) })
        let id = try await importer.importAutomatically(bundle, folder: "iPad")

        let imported = try XCTUnwrap(store.recordings.first { $0.id == id })
        XCTAssertEqual(id, recording.id)
        XCTAssertEqual(imported.title, "On the train")
        XCTAssertEqual(imported.createdAt, recording.createdAt)
        XCTAssertEqual(imported.language, "he")
        XCTAssertEqual(imported.segments.map(\.text), [" שלום", " לכולם"])
        XCTAssertEqual(imported.sharedBy, "Lior's iPad")
        XCTAssertEqual(imported.folder, "iPad")
        XCTAssertEqual(imported.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: imported).path))
    }

    func test_a_Mac_bundle_opens_on_the_iPad() async throws {
        let audioURL = store.freshAudioURL(suggestedName: "Weekly sync")
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 0.2)
        let recording = Recording(
            title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 0.2,
            source: .meeting, audioFileName: audioURL.lastPathComponent, status: .completed, language: "en",
            segments: [TranscriptSegment(start: 0, end: 0.1, text: "hello", speaker: "SPEAKER_00"),
                       TranscriptSegment(start: 0.1, end: 0.2, text: "hi", speaker: "SPEAKER_01")],
            fullText: "Daniel: hello\nAda: hi", summary: "Short.",
            speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        store.add(recording)
        let built = try await RecordingShareExporter.buildBundle(for: recording, store: store,
                                                                 exportedBy: "Lior's Mac")
        defer { try? FileManager.default.removeItem(at: built.deletingLastPathComponent()) }

        let out = try ShareBundle.unpack(built, into: scratch.appendingPathComponent("out"))
        let r = out.manifest.recording
        XCTAssertEqual(r.id, recording.id)
        XCTAssertEqual(r.title, "Weekly sync")
        XCTAssertEqual(r.createdAt, recording.createdAt)
        XCTAssertEqual(r.source, "meeting")
        XCTAssertEqual(r.summary, "Short.")
        XCTAssertEqual(r.speakerNames, recording.speakerNames)
        XCTAssertEqual(r.text, "Daniel: hello\nAda: hi")
        XCTAssertEqual(out.manifest.exportedBy.name, "Lior's Mac")
        XCTAssertEqual(out.transcript, "Daniel: hello\nAda: hi")
        XCTAssertEqual(try Data(contentsOf: out.audio), try Data(contentsOf: audioURL))
    }
}
