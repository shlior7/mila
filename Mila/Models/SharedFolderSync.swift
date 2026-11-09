import Combine
import CryptoKit
import Foundation
import MilaKit
import os

private let syncLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "SharedFolders")

/// Folders shared with teammates through a directory everyone already syncs
/// — a Google Drive shared drive (Drive for desktop), Dropbox, a network
/// share. No server: the directory is the shared state, and who can see it
/// is whoever the drive folder is shared with.
///
/// A linked Mila folder keeps two things in that directory per recording
/// the user made (`sharedBy == nil`):
///   * `<id>.milashare` — the full bundle (`RecordingShareExporter`), which
///     teammates' Mila imports; rewritten whenever the recording changes.
///   * `<title> <id8>.md` — a readable note (summary, action items,
///     attendees, transcript), for teammates without Mila and for anything
///     that can read the drive but not open a zip — a Claude session on the
///     web reading Google Drive, say.
/// Teammates' bundles in the directory are imported into the folder
/// silently (`RecordingShareImporter.importAutomatically`).
///
/// What deliberately does NOT sync:
///   * Edits to a TEAMMATE's recording stay local and are overwritten by
///     that teammate's next update — only the author publishes.
///   * Deletes. Deleting your recording (or moving it out of the folder)
///     removes your files from the directory, but teammates who imported it
///     keep their copy; deleting a teammate's recording removes only yours
///     and it is not re-imported.
///   * Voice profiles — only the interactive import sheet may write those.
@MainActor
final class SharedFolderSync: ObservableObject {
    /// Mila folder name → linked directory path.
    @Published private(set) var links: [String: String]

    private let store: RecordingStore
    private let importer: RecordingShareImporter
    private let defaults: UserDefaults
    private var watchers: [String: DirectoryWatcher] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var rescanTimer: Timer?
    private var syncInFlight = false
    private var syncRequested = false

    /// Recording id → fingerprint of what was last published (see `fingerprint`).
    private var published: [String: String] {
        didSet { defaults.set(published, forKey: Keys.published) }
    }
    /// Recording id → modification date of the teammate bundle last imported.
    /// An id here whose recording is gone was deleted by the user: never
    /// re-imported.
    private var imported: [String: Date] {
        didSet { defaults.set(imported, forKey: Keys.imported) }
    }

    init(store: RecordingStore, importer: RecordingShareImporter, defaults: UserDefaults = .standard) {
        self.store = store
        self.importer = importer
        self.defaults = defaults
        links = defaults.dictionary(forKey: Keys.links) as? [String: String] ?? [:]
        published = defaults.dictionary(forKey: Keys.published) as? [String: String] ?? [:]
        imported = defaults.dictionary(forKey: Keys.imported) as? [String: Date] ?? [:]
    }

    func start() {
        guard rescanTimer == nil else { return }
        // Publish edits a few seconds after they settle — a transcription
        // finishing, a rename, a summary landing — rather than per keystroke.
        store.$recordings
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.requestSync() }
            .store(in: &cancellables)
        // FSEvents doesn't reliably see changes a cloud drive's File Provider
        // writes, so poll as well.
        // ponytail: fixed 60 s poll; make it adaptive if a big shared folder
        // makes the scan show up in Instruments.
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
        restartWatchers()
        requestSync()
    }

    // MARK: - Links (Sidebar)

    func isShared(_ folder: String) -> Bool { links[folder] != nil }

    func directory(for folder: String) -> URL? {
        links[folder].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func link(_ folder: String, to directory: URL) {
        links[folder] = directory.path
        saveLinks()
    }

    /// Stop syncing. Files already in the directory stay there.
    func unlink(_ folder: String) {
        links[folder] = nil
        saveLinks()
    }

    /// Follow `RecordingStore.renameFolder`.
    func folderRenamed(from oldName: String, to newName: String) {
        guard oldName != newName, let path = links.removeValue(forKey: oldName) else { return }
        links[newName] = path
        saveLinks()
    }

    private func saveLinks() {
        defaults.set(links, forKey: Keys.links)
        restartWatchers()
        requestSync()
    }

    private func restartWatchers() {
        watchers.values.forEach { $0.stop() }
        watchers = links.mapValues { path in
            let watcher = DirectoryWatcher(path: path) { [weak self] in
                Task { @MainActor in self?.requestSync() }
            }
            watcher.start()
            return watcher
        }
    }

    // MARK: - Sync

    /// Coalesce: one pass at a time, and a request during a pass runs one more.
    func requestSync() {
        guard !links.isEmpty else { return }
        if syncInFlight { syncRequested = true; return }
        syncInFlight = true
        Task {
            repeat {
                syncRequested = false
                for (folder, path) in links {
                    let dir = URL(fileURLWithPath: path, isDirectory: true)
                    guard FileManager.default.fileExists(atPath: dir.path) else {
                        syncLog.error("shared folder directory is missing; skipping this pass")
                        continue
                    }
                    await publish(folder: folder, to: dir)
                    await importTeammates(into: folder, from: dir)
                }
            } while syncRequested
            syncInFlight = false
        }
    }

    private func publish(folder: String, to dir: URL) async {
        let fm = FileManager.default
        let mine = store.recordings.filter { $0.sharedBy == nil }
        let keep = mine.filter {
            $0.folder == folder && RecordingShareExporter.canExport($0)
        }
        for recording in keep {
            let print = Self.fingerprint(recording)
            let bundle = Self.bundleURL(for: recording.id, in: dir)
            if published[recording.id.uuidString] == print, fm.fileExists(atPath: bundle.path) { continue }
            do {
                let built = try await RecordingShareExporter.buildBundle(
                    for: recording, store: store,
                    exportedBy: RecordingShareExporter.exporterName())
                defer { try? fm.removeItem(at: built.deletingLastPathComponent()) }
                try Self.replace(bundle, with: built)
                removeNotes(for: recording.id, in: dir)
                try Self.note(for: recording).write(to: Self.noteURL(for: recording, in: dir),
                                                   atomically: true, encoding: .utf8)
                published[recording.id.uuidString] = print
                syncLog.log("published \(recording.id, privacy: .public) to a shared folder")
            } catch {
                syncLog.error("""
                    publishing \(recording.id, privacy: .public) failed: \
                    \(String(describing: error), privacy: .private)
                    """)
            }
        }
        // Mine, published here before, but no longer in this folder (moved,
        // trashed, deleted): take my files back out.
        let keptIDs = Set(keep.map(\.id))
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let id = Self.bundleID(fromFileName: name), !keptIDs.contains(id),
                  published[id.uuidString] != nil else { continue }
            try? fm.removeItem(at: dir.appendingPathComponent(name))
            removeNotes(for: id, in: dir)
            published[id.uuidString] = nil
        }
    }

    private func importTeammates(into folder: String, from dir: URL) async {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let id = Self.bundleID(fromFileName: name) else { continue }
            let url = dir.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let local = store.recordings.first { $0.id == id }
            guard Self.shouldImport(isMine: published[id.uuidString] != nil || (local != nil && local?.sharedBy == nil),
                                    localExists: local != nil,
                                    localTrashed: local?.isTrashed ?? false,
                                    lastImported: imported[id.uuidString],
                                    modified: modified) else { continue }
            do {
                try await importer.importAutomatically(url, folder: folder)
                imported[id.uuidString] = modified
            } catch {
                // Not recorded as imported, so the next pass retries — a
                // bundle still being synced down fails its checks until it
                // has fully arrived.
                syncLog.error("""
                    importing \(id, privacy: .public) from a shared folder failed: \
                    \(String(describing: error), privacy: .private)
                    """)
            }
        }
    }

    /// Whether a teammate's bundle in a linked directory should be imported.
    /// Pure, for the tests.
    static func shouldImport(isMine: Bool, localExists: Bool, localTrashed: Bool,
                             lastImported: Date?, modified: Date) -> Bool {
        if isMine || localTrashed { return false }
        guard let lastImported else { return true }
        // Imported before and gone now: the user deleted it.
        guard localExists else { return false }
        return modified > lastImported
    }

    // MARK: - Files

    static let bundleExtension = ShareManifest.fileExtension

    static func bundleURL(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id.uuidString).\(bundleExtension)")
    }

    static func bundleID(fromFileName name: String) -> UUID? {
        guard (name as NSString).pathExtension == bundleExtension else { return nil }
        return UUID(uuidString: (name as NSString).deletingPathExtension)
    }

    /// `<title> <first 8 of id>.md` — readable in the drive's web UI, unique
    /// per recording, and found again by its id suffix after a retitle.
    static func noteURL(for recording: Recording, in dir: URL) -> URL {
        let stem = ObsidianPathSanitizer.nameFragment(recording.title)
        let suffix = recording.id.uuidString.prefix(8)
        return dir.appendingPathComponent("\(stem.isEmpty ? "Recording" : stem) \(suffix).md")
    }

    private func removeNotes(for id: UUID, in dir: URL) {
        let suffix = " \(id.uuidString.prefix(8)).md"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasSuffix(suffix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Write `built` over `destination` in one step, so a teammate's sync
    /// never picks up a half-written bundle under the final name. Staged
    /// beside the destination first: `built` is in the temporary directory,
    /// usually another volume, and a swap across volumes is not atomic.
    private static func replace(_ destination: URL, with built: URL) throws {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: built, to: staged)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// What a teammate would see change: the shareable payload plus the
    /// calendar event the note shows. Republishing on anything else (status,
    /// local folder bookkeeping) would churn the drive for nothing.
    static func fingerprint(_ recording: Recording) -> String {
        let encoder = ShareManifest.encoder()
        var data = (try? encoder.encode(ShareManifest.RecordingPayload(sharing: recording))) ?? Data()
        data += (try? encoder.encode(recording.calendarEvent)) ?? Data()
        data += Data(recording.fullText.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The readable note: the Obsidian note body (title, summary or
    /// transcript, action items) plus when, who was invited, and — when the
    /// body led with a summary — the full transcript.
    static func note(for recording: Recording) -> String {
        var lines = ObsidianExporter.markdown(for: recording).components(separatedBy: "\n")
        let date = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        var meta = ["", "*\(date) · shared by \(RecordingShareExporter.exporterName())*"]
        let invited = (recording.calendarEvent?.attendees ?? []).compactMap { $0.name ?? $0.email }
        if !invited.isEmpty { meta.append("Attendees: \(invited.joined(separator: ", "))") }
        lines.insert(contentsOf: meta, at: min(1, lines.count))
        var out = lines.joined(separator: "\n")
        if !(recording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = recording.fullText.isEmpty
                ? TranscriptFormatter.joinedFullText(segments: recording.segments)
                : recording.fullText
            out += "\n## Transcript\n\n\(text)\n"
        }
        return out
    }

    private enum Keys {
        static let links = "sharedFolders.links"
        static let published = "sharedFolders.published"
        static let imported = "sharedFolders.imported"
    }
}
