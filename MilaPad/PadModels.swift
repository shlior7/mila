import CryptoKit
import Foundation

/// A whisper model the iPad can run. Pinned by SHA-256 like the Mac's
/// `WhisperModel`, so a swapped file never reaches whisper.cpp's loader.
///
/// The Mac's defaults (full ivrit.ai large-v3 at 3 GB, and fp16 turbo with
/// a CoreML encoder) don't fit a 4 GB iPad next to the audio, so the iPad
/// offers the quantized turbo and the ivrit.ai turbo finetune instead.
struct PadModel: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let displayName: String
    let note: String
    let url: URL
    let sizeBytes: Int64
    let sha256: String

    static let turboQ5 = PadModel(
        name: "ggml-large-v3-turbo-q5_0",
        displayName: "Whisper large-v3-turbo (q5)",
        note: "English and Hebrew. 574 MB, lightest on memory.",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        sizeBytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")

    static let ivritTurbo = PadModel(
        name: "ivrit-ai-whisper-large-v3-turbo",
        displayName: "ivrit.ai large-v3-turbo (Hebrew)",
        note: "Best Hebrew. 1.6 GB; may run out of memory on a 4 GB iPad.",
        url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin")!,
        sizeBytes: 1_624_555_275,
        sha256: "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1")

    static let all: [PadModel] = [.turboQ5, .ivritTurbo]
}

@MainActor
final class PadModels: ObservableObject {
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloads: [String: Double] = [:]
    @Published var lastError: String?
    @Published var selectedName: String {
        didSet { UserDefaults.standard.set(selectedName, forKey: "model.selected") }
    }

    let directory: URL
    private var observations: [String: NSKeyValueObservation] = [:]

    init() {
        directory = URL.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        selectedName = UserDefaults.standard.string(forKey: "model.selected") ?? PadModel.turboQ5.name
        installed = Set(PadModel.all.map(\.name).filter {
            FileManager.default.fileExists(atPath: fileURL(for: $0).path)
        })
    }

    var selected: PadModel? { PadModel.all.first { $0.name == selectedName } }

    /// The selected model's file, when it is downloaded.
    var selectedURL: URL? {
        installed.contains(selectedName) ? fileURL(for: selectedName) : nil
    }

    func fileURL(for name: String) -> URL { directory.appendingPathComponent("\(name).bin") }

    func download(_ model: PadModel) {
        guard downloads[model.name] == nil else { return }
        lastError = nil
        downloads[model.name] = 0
        let partial = directory.appendingPathComponent("\(model.name).partial")
        let destination = fileURL(for: model.name)
        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] tmp, _, error in
            // `tmp` is deleted when this handler returns: move it first.
            var failure = error?.localizedDescription
            if let tmp {
                try? FileManager.default.removeItem(at: partial)
                do { try FileManager.default.moveItem(at: tmp, to: partial) } catch { failure = error.localizedDescription }
            }
            let downloadFailure = failure
            Task.detached(priority: .utility) {
                var failure = downloadFailure
                if failure == nil {
                    do {
                        let digest = try Self.sha256Hex(of: partial)
                        if digest == model.sha256 {
                            try? FileManager.default.removeItem(at: destination)
                            try FileManager.default.moveItem(at: partial, to: destination)
                        } else {
                            failure = "The downloaded model didn't match its checksum."
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                try? FileManager.default.removeItem(at: partial)
                let outcome = failure
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloads[model.name] = nil
                    self.observations[model.name] = nil
                    if let outcome { self.lastError = "Couldn't download \(model.displayName): \(outcome)" }
                    else { self.installed.insert(model.name) }
                }
            }
        }
        observations[model.name] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                // Whole percents only: KVO fires per chunk, and every publish
                // re-evaluates the App body.
                guard let self, let shown = self.downloads[model.name], fraction - shown >= 0.01 else { return }
                self.downloads[model.name] = fraction
            }
        }
        task.resume()
    }

    func delete(_ model: PadModel) {
        try? FileManager.default.removeItem(at: fileURL(for: model.name))
        installed.remove(model.name)
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
