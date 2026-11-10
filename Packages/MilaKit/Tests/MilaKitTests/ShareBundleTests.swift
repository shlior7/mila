import Foundation
import XCTest
@testable import MilaKit

final class ShareBundleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShareBundleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleRecording() -> ShareBundle.Recording {
        ShareBundle.Recording(title: "Standup", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                              duration: 12, language: "he", modelName: "turbo",
                              segments: [.init(start: 0, end: 2, text: " שלום"),
                                         .init(start: 2, end: 4, text: " team")])
    }

    private func audioFile(bytes: Int = 300_000) throws -> URL {
        let url = dir.appendingPathComponent("rec.m4a")
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        return url
    }

    func test_pack_then_unpack_round_trips() throws {
        let archive = dir.appendingPathComponent("a.milashare")
        try ShareBundle.pack(sampleRecording(), audio: try audioFile(), exportedBy: "iPad", to: archive)

        let out = try ShareBundle.unpack(archive, into: dir.appendingPathComponent("out"))
        XCTAssertEqual(out.manifest.recording, sampleRecording().withID(out.manifest.recording.id))
        XCTAssertEqual(out.manifest.exportedBy.name, "iPad")
        XCTAssertEqual(out.transcript, "שלום team")
        XCTAssertEqual(try Data(contentsOf: out.audio), try Data(contentsOf: try audioFile()))
    }

    func test_tampered_audio_fails_integrity() throws {
        let archive = dir.appendingPathComponent("a.milashare")
        try ShareBundle.pack(sampleRecording(), audio: try audioFile(), exportedBy: "iPad", to: archive)
        // Flip a byte inside the stored audio, then fix the zip CRC so only
        // the manifest's SHA-256 can catch it: rebuild with the same manifest.
        let staged = dir.appendingPathComponent("staged")
        _ = try ShareBundle.unpack(archive, into: staged)
        var audio = try Data(contentsOf: staged.appendingPathComponent("audio.m4a"))
        audio[1000] ^= 0xFF
        try audio.write(to: staged.appendingPathComponent("audio.m4a"))
        let forged = dir.appendingPathComponent("forged.milashare")
        try ShareZip.write(["manifest.json", "transcript.txt", "audio.m4a"].map {
            ($0, staged.appendingPathComponent($0))
        }, to: forged)

        XCTAssertThrowsError(try ShareBundle.unpack(forged, into: dir.appendingPathComponent("out"))) {
            XCTAssertEqual($0 as? ShareBundle.Failure, .integrity("audio doesn't match its checksum"))
        }
    }

    func test_unexpected_entry_is_refused_before_extraction() throws {
        let extra = dir.appendingPathComponent("evil.sh")
        try Data("x".utf8).write(to: extra)
        let archive = dir.appendingPathComponent("a.milashare")
        try ShareZip.write([("manifest.json", extra), ("audio.wav", extra), ("../evil.sh", extra)], to: archive)

        let out = dir.appendingPathComponent("out")
        XCTAssertThrowsError(try ShareBundle.unpack(archive, into: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    #if os(macOS)
    /// What the Mac sends: `ditto -c -k` deflates. The reader must inflate it.
    func test_reads_a_deflated_ditto_archive() throws {
        let payload = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let text = String(repeating: "hello mila ", count: 20_000)
        try Data(text.utf8).write(to: payload.appendingPathComponent("transcript.txt"))
        let archive = dir.appendingPathComponent("d.zip")
        try ditto(["-c", "-k", "--norsrc", payload.path, archive.path])

        let entry = try XCTUnwrap(ShareZip.entries(of: archive).first { $0.name == "transcript.txt" })
        XCTAssertEqual(entry.method, 8, "ditto should have deflated this")
        let out = dir.appendingPathComponent("t.txt")
        try ShareZip.extract(entry, from: archive, to: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), text)
    }

    /// A central directory that understates an entry's size is caught while
    /// inflating, and nothing is left behind.
    func test_inflating_past_the_declared_size_is_refused() throws {
        let payload = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 5_000_000).utf8).write(to: payload.appendingPathComponent("transcript.txt"))
        let archive = dir.appendingPathComponent("d.zip")
        try ditto(["-c", "-k", "--norsrc", payload.path, archive.path])

        let real = try XCTUnwrap(ShareZip.entries(of: archive).first)
        let lie = ShareZip.Entry(name: real.name, method: real.method, crc32: real.crc32,
                                 compressedSize: real.compressedSize, uncompressedSize: 1000,
                                 localHeaderOffset: real.localHeaderOffset, isRegularFile: true)
        let out = dir.appendingPathComponent("t.txt")
        XCTAssertThrowsError(try ShareZip.extract(lie, from: archive, to: out)) {
            XCTAssertEqual($0 as? ShareZip.Failure, ShareZip.Failure("entry larger than declared"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    private func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
    #endif
}

private extension ShareBundle.Recording {
    func withID(_ id: UUID) -> Self { var c = self; c.id = id; return c }
}
