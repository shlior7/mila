import AVFoundation
import Foundation
import MilaKit
import TranscriptionCore
import UIKit

/// One recording on this iPad — made here (`sharedBy == nil`) or synced in
/// from a Mac (`sharedBy` = the Mac's exporter name).
struct PadItem: Codable, Identifiable, Equatable, Sendable {
    var recording: ShareBundle.Recording
    /// `audio.m4a` or `audio.wav`, inside the item's directory.
    var audioFileName: String
    var sharedBy: String?
    /// Own recordings: false until whisper has run.
    var transcribed: Bool

    var id: UUID { recording.id }
    var isMine: Bool { sharedBy == nil }
}

/// The iPad's recordings, one directory each under Application Support:
/// `Recordings/<id>/item.json` plus the audio (and, for synced ones, the
/// bundle's `transcript.txt`). No index file — the directories are the
/// library, so a crash can't leave the two disagreeing.
@MainActor
final class PadLibrary: ObservableObject {
    @Published private(set) var items: [PadItem] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var transcribingID: UUID?
    @Published private(set) var progress: Float = 0
    @Published var lastError: String?

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "recording.language") }
    }

    let root: URL
    private let models: PadModels
    private let engine = WhisperEngine()
    private var recorder: AVAudioRecorder?
    private var pendingID: UUID?
    /// Called after anything a sync would publish changed.
    var onChange: (() -> Void)?

    init(models: PadModels) {
        self.models = models
        root = URL.applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        language = UserDefaults.standard.string(forKey: "recording.language") ?? "he"
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(for item: PadItem) -> URL { directory(for: item.id).appendingPathComponent(item.audioFileName) }

    /// The transcript to show: from segments, else a synced bundle's
    /// `transcript.txt` (a Mac recording can carry text without segments).
    func transcriptText(for item: PadItem) -> String {
        let text = item.recording.text
        if !text.isEmpty { return text }
        let url = directory(for: item.id).appendingPathComponent(ShareBundle.transcriptName)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("item.json")) else { return nil }
            return try? ShareBundle.decoder().decode(PadItem.self, from: data)
        }
        .sorted { $0.recording.createdAt > $1.recording.createdAt }
    }

    private func save(_ item: PadItem) {
        do {
            try ShareBundle.encoder().encode(item)
                .write(to: directory(for: item.id).appendingPathComponent("item.json"), options: .atomic)
        } catch {
            lastError = "Couldn't save the recording: \(error.localizedDescription)"
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else {
            items.append(item)
            items.sort { $0.recording.createdAt > $1.recording.createdAt }
        }
    }

    func rename(_ id: UUID, to title: String) {
        guard var item = items.first(where: { $0.id == id }), item.isMine else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.recording.title else { return }
        item.recording.title = trimmed
        save(item)
        onChange?()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        items.removeAll { $0.id == id }
        onChange?()
    }

    // MARK: - Recording

    var isRecording: Bool { recordingStartedAt != nil }

    func startRecording() async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Mila needs microphone access. Turn it on in Settings → Privacy → Microphone."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let id = UUID()
            try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
            // 16 kHz mono AAC: what whisper resamples to anyway, and about
            // 15 MB an hour to sync instead of 115 MB of WAV.
            let recorder = try AVAudioRecorder(
                url: directory(for: id).appendingPathComponent("audio.m4a"),
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                           AVSampleRateKey: 16_000,
                           AVNumberOfChannelsKey: 1,
                           AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            pendingID = id
            recordingStartedAt = Date()
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let recorder, let id = pendingID, let started = recordingStartedAt else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        pendingID = nil
        recordingStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let title = "Recording " + started.formatted(date: .abbreviated, time: .shortened)
        let item = PadItem(recording: .init(id: id, title: title, createdAt: started,
                                            duration: duration, language: language),
                           audioFileName: "audio.m4a", sharedBy: nil, transcribed: false)
        save(item)
        Task { await transcribe(id) }
    }

    // MARK: - Import

    /// Copy an audio file in (`.m4a` / `.wav` as-is, anything else
    /// re-encoded to a 16 kHz WAV) and transcribe it.
    func importAudio(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let dir = directory(for: id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = url.pathExtension.lowercased()
            let (fileName, duration) = try await Task.detached(priority: .userInitiated) {
                () throws -> (String, Double) in
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                if ext == "m4a" || ext == "wav" {
                    try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("audio.\(ext)"))
                    return ("audio.\(ext)", duration)
                }
                try AudioConvert.writeWhisperWAV(samples: try PadAudio.whisperSamples(of: url),
                                                 to: dir.appendingPathComponent("audio.wav"))
                return ("audio.wav", duration)
            }.value
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            save(PadItem(recording: .init(id: id, title: url.deletingPathExtension().lastPathComponent,
                                          createdAt: created, duration: duration, language: language),
                         audioFileName: fileName, sharedBy: nil, transcribed: false))
            await transcribe(id)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            lastError = "Couldn't import that file: \(error.localizedDescription)"
        }
    }

    // MARK: - Transcription

    /// Transcribe an own recording with the selected model, or on the remote
    /// server when that is on. One at a time; the screen is kept awake
    /// because iOS suspends GPU work (and soon networking) in the background.
    func transcribe(_ id: UUID) async {
        guard transcribingID == nil, var item = items.first(where: { $0.id == id }), item.isMine else { return }
        let remote = models.remoteConfig
        if models.useRemote && remote == nil {
            lastError = "Enter the server's URL in Settings, or turn Remote server off."
            return
        }
        let local = models.selectedURL.flatMap { url in models.selected.map { (url, $0) } }
        guard remote != nil || local != nil else {
            lastError = "Download a model in Settings, then tap Transcribe."
            return
        }
        transcribingID = id
        progress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            transcribingID = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let engine: any TranscribingEngine
        let modelName: String
        if let remote {
            let remoteEngine = RemoteWhisperEngine()
            await remoteEngine.configure(remote)
            engine = remoteEngine
            modelName = remote.model
        } else {
            engine = self.engine
            modelName = local!.1.name
        }
        do {
            let audio = audioURL(for: item)
            let samples = try await Task.detached(priority: .userInitiated) {
                try PadAudio.whisperSamples(of: audio)
            }.value
            try await engine.loadIfNeeded(modelURL: local?.0 ?? audio, displayName: modelName)
            let segments = try await engine.transcribe(
                samples: samples, language: item.recording.language, audioCtx: 0,
                progress: { [weak self] p in Task { @MainActor in self?.progress = p } }, isCancelled: nil)
            // Release the model: an idle 0.5–1.6 GB in memory is what gets a
            // backgrounded, recording app killed.
            await engine.shutdown()
            item.recording.segments = segments.map {
                ShareBundle.Segment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
            }
            item.recording.modelName = modelName
            item.transcribed = true
            save(item)
            onChange?()
        } catch {
            await engine.shutdown()
            lastError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Sync

    /// Take in a bundle `PadSync` unpacked into `staging` (a directory under
    /// `root`, so this is a rename, not a copy), replacing any earlier copy.
    func adoptSynced(_ unpacked: ShareBundle.Unpacked, staging: URL) throws {
        let id = unpacked.manifest.recording.id
        let fm = FileManager.default
        try? fm.removeItem(at: staging.appendingPathComponent(ShareBundle.manifestName))
        try? fm.removeItem(at: directory(for: id))
        try fm.moveItem(at: staging, to: directory(for: id))
        save(PadItem(recording: unpacked.manifest.recording,
                     audioFileName: unpacked.manifest.audio.fileName,
                     sharedBy: unpacked.manifest.exportedBy.name, transcribed: true))
    }
}

enum PadAudio {
    /// Whole file as whisper samples, decoded in chunks through one
    /// converter — `AudioConvert.loadAsWhisperSamples` reads the file at its
    /// native rate in one buffer, over a gigabyte for an hour of 48 kHz stereo.
    static func whisperSamples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let converter = StreamingWhisperConverter(inputFormat: file.processingFormat)
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * 16_000))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(file.length - file.framePosition)))
            let converted = try converter?.convert(buffer) ?? AudioConvert.toWhisperFormat(buffer)
            samples += AudioConvert.samples(from: converted)
        }
        return samples
    }
}
