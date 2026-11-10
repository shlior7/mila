import CryptoKit
import Foundation
import MilaKit
import os

private let syncLog = Logger(subsystem: "io.island.mila.pad", category: "Sync")

/// The iPad's side of the Mac's `SharedFolderSync`: a folder both devices
/// sync (iCloud Drive, picked in Files), holding one `<id>.milashare` per
/// recording. Same rules as the Mac, so the Mac needs nothing new — link a
/// Mila folder to the same directory with "Share with Team…":
///   * Out: each own, transcribed recording is published as
///     `<id>.milashare`, rewritten when it changes, removed when deleted.
///   * In: everyone else's bundles are imported; deleting one here keeps it
///     from coming back. Edits never flow back to a recording's author.
///
/// Picking the folder through Files gives a security-scoped bookmark, which
/// works with a free Apple ID — no iCloud entitlement or container needed.
@MainActor
final class PadSync: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published var lastError: String?
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: Keys.deviceName) }
    }

    private let library: PadLibrary
    private var syncRequested = false
    /// Recording id → fingerprint of what was last published.
    private var published: [String: String] {
        didSet { UserDefaults.standard.set(published, forKey: Keys.published) }
    }
    /// Recording id → modification date of the bundle last imported. An id
    /// here with no local recording was deleted by the user: never re-imported.
    private var imported: [String: Date] {
        didSet { UserDefaults.standard.set(imported, forKey: Keys.imported) }
    }

    init(library: PadLibrary) {
        self.library = library
        let d = UserDefaults.standard
        deviceName = d.string(forKey: Keys.deviceName) ?? "iPad"
        published = d.dictionary(forKey: Keys.published) as? [String: String] ?? [:]
        imported = d.dictionary(forKey: Keys.imported) as? [String: Date] ?? [:]
        folderName = resolveFolder()?.lastPathComponent
    }

    // MARK: - Folder

    func link(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            UserDefaults.standard.set(try url.bookmarkData(), forKey: Keys.bookmark)
            // Another folder: start its bookkeeping fresh.
            published = [:]
            imported = [:]
            folderName = url.lastPathComponent
            lastError = nil
            Task { await sync() }
        } catch {
            lastError = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    func unlink() {
        UserDefaults.standard.removeObject(forKey: Keys.bookmark)
        folderName = nil
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Keys.bookmark) }
        return url
    }

    // MARK: - Sync

    /// One pass at a time; a request during a pass runs one more.
    func sync() async {
        guard let dir = resolveFolder() else { return }
        if isSyncing { syncRequested = true; return }
        isSyncing = true
        defer { isSyncing = false }
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        repeat {
            syncRequested = false
            lastError = nil
            await publish(to: dir)
            await importOthers(from: dir)
        } while syncRequested
        lastSync = Date()
    }

    private func publish(to dir: URL) async {
        let mine = library.items.filter { $0.isMine && $0.transcribed }
        for item in mine {
            let print = Self.fingerprint(item.recording)
            let bundle = Self.bundleURL(for: item.id, in: dir)
            if published[item.id.uuidString] == print, FileManager.default.fileExists(atPath: bundle.path) { continue }
            let audio = library.audioURL(for: item)
            let name = deviceName
            do {
                try await Task.detached(priority: .utility) {
                    let built = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString).\(ShareBundle.fileExtension)")
                    defer { try? FileManager.default.removeItem(at: built) }
                    try ShareBundle.pack(item.recording, audio: audio, exportedBy: name, to: built)
                    try Self.coordinatedReplace(bundle, with: built)
                }.value
                published[item.id.uuidString] = print
                syncLog.log("published \(item.id, privacy: .public)")
            } catch {
                lastError = "Couldn't publish \(item.recording.title): \(error.localizedDescription)"
            }
        }
        // Published here before, gone from the library now: take it back out.
        let keep = Set(mine.map(\.id.uuidString))
        for id in published.keys where !keep.contains(id) {
            guard let uuid = UUID(uuidString: id) else { continue }
            let url = Self.bundleURL(for: uuid, in: dir)
            try? await Task.detached { try Self.coordinatedDelete(url) }.value
            published[id] = nil
        }
    }

    private func importOthers(from dir: URL) async {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            // Not downloaded yet: iCloud lists `.<name>.icloud`. Ask for it
            // and pick it up on a later pass.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                if Self.bundleID(fromFileName: real) != nil {
                    try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(real))
                }
                continue
            }
            guard let id = Self.bundleID(fromFileName: name) else { continue }
            let url = dir.appendingPathComponent(name)
            let local = library.items.first { $0.id == id }
            if published[id.uuidString] != nil || local?.isMine == true { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let last = imported[id.uuidString] {
                guard local != nil, modified > last else { continue }
            }
            let staging = library.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            do {
                let unpacked = try await Task.detached(priority: .utility) {
                    try Self.coordinatedRead(url) { try ShareBundle.unpack($0, into: staging) }
                }.value
                guard unpacked.manifest.recording.id == id else {
                    throw ShareBundle.Failure.malformed("its name and its recording id disagree")
                }
                try library.adoptSynced(unpacked, staging: staging)
                imported[id.uuidString] = modified
                syncLog.log("imported \(id, privacy: .public)")
            } catch {
                // Not marked imported, so the next pass retries — a bundle
                // still syncing down fails its checks until it has arrived.
                try? fm.removeItem(at: staging)
                syncLog.error("import \(id, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    // MARK: - Files

    static func bundleURL(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id.uuidString).\(ShareBundle.fileExtension)")
    }

    static func bundleID(fromFileName name: String) -> UUID? {
        guard (name as NSString).pathExtension == ShareBundle.fileExtension else { return nil }
        return UUID(uuidString: (name as NSString).deletingPathExtension)
    }

    static func fingerprint(_ recording: ShareBundle.Recording) -> String {
        let data = (try? ShareBundle.encoder().encode(recording)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Coordinated so the iCloud File Provider downloads the file first and
    /// never hands over a half-synced one.
    nonisolated static func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    /// Swap `built` in under `destination` in one step, so the Mac never
    /// picks up a half-written bundle under the final name.
    nonisolated static func coordinatedReplace(_ destination: URL, with built: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
                                       error: &coordinationError) { destination in
            let fm = FileManager.default
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).partial")
            do {
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: built, to: staged)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: destination)
                }
            } catch {
                try? fm.removeItem(at: staged)
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
    }

    nonisolated static func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) {
            try? FileManager.default.removeItem(at: $0)
        }
        if let coordinationError { throw coordinationError }
    }

    private enum Keys {
        static let bookmark = "sync.folderBookmark"
        static let published = "sync.published"
        static let imported = "sync.imported"
        /// Same key the Mac uses for its exporter name.
        static let deviceName = "sharing.exporterName"
    }
}
