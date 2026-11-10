import MilaKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MilaPadApp: App {
    @StateObject private var models: PadModels
    @StateObject private var library: PadLibrary
    @StateObject private var sync: PadSync
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let models = PadModels()
        let library = PadLibrary(models: models)
        let sync = PadSync(library: library)
        library.onChange = { Task { await sync.sync() } }
        _models = StateObject(wrappedValue: models)
        _library = StateObject(wrappedValue: library)
        _sync = StateObject(wrappedValue: sync)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(models)
                .environmentObject(library)
                .environmentObject(sync)
                // iCloud changes raise no event here: sync on foreground and
                // once a minute while open, like the Mac's rescan.
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await sync.sync()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: PadLibrary
    @EnvironmentObject private var sync: PadSync
    @EnvironmentObject private var models: PadModels
    @State private var selection: UUID?
    @State private var showSettings = false
    @State private var importing = false
    /// Record lives in the sidebar, so keep it showing in portrait too.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                if let started = library.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Label("Recording · \(Self.duration(context.date.timeIntervalSince(started)))",
                              systemImage: "record.circle")
                            .foregroundStyle(.red)
                    }
                }
                ForEach(library.items) { item in
                    ItemRow(item: item).tag(item.id)
                }
                .onDelete { offsets in
                    offsets.map { library.items[$0].id }.forEach(library.delete)
                }
            }
            .overlay {
                if library.items.isEmpty && !library.isRecording {
                    ContentUnavailableView("No recordings", systemImage: "waveform",
                                           description: Text("Tap Record, or import an audio file."))
                }
            }
            .refreshable { await sync.sync() }
            .navigationTitle("Mila")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .disabled(library.isRecording)
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if library.isRecording { library.stopRecording() } else { Task { await library.startRecording() } }
                    } label: {
                        Label(library.isRecording ? "Stop" : "Record",
                              systemImage: library.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result { Task { await library.importAudio(from: url) } }
            }
        } detail: {
            if let item = library.items.first(where: { $0.id == selection }) {
                ItemDetail(item: item)
            } else {
                ContentUnavailableView("Select a recording", systemImage: "text.alignleft")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Mila", isPresented: errorShown, presenting: library.lastError ?? models.lastError) { _ in
            Button("OK") { library.lastError = nil; models.lastError = nil }
        } message: { Text($0) }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { library.lastError != nil || models.lastError != nil },
                set: { if !$0 { library.lastError = nil; models.lastError = nil } })
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0)
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

struct ItemRow: View {
    @EnvironmentObject private var library: PadLibrary
    let item: PadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.recording.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(item.recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(LibraryView.duration(item.recording.duration))
                if let from = item.sharedBy {
                    Text("·")
                    Label(from, systemImage: "desktopcomputer").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if library.transcribingID == item.id {
                ProgressView(value: library.progress) { Text("Transcribing…").font(.caption) }
            } else if !item.transcribed {
                Text("Not transcribed").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct ItemDetail: View {
    @EnvironmentObject private var library: PadLibrary
    let item: PadItem
    @State private var title = ""

    var body: some View {
        let text = library.transcriptText(for: item)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if item.isMine {
                    TextField("Title", text: $title)
                        .font(.title2.bold())
                        .onSubmit { library.rename(item.id, to: title) }
                } else {
                    Text(item.recording.title).font(.title2.bold())
                    Text("Shared from \(item.sharedBy ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                if let summary = item.recording.summary, !summary.isEmpty {
                    GroupBox("Summary") { Text(summary).frame(maxWidth: .infinity, alignment: .leading) }
                }
                if text.isEmpty {
                    Text(item.transcribed ? "Nothing was said." : "Not transcribed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(text).textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { title = item.recording.title }
        .onChange(of: item.id) { previous, _ in
            library.rename(previous, to: title)
            title = item.recording.title
        }
        .onDisappear { if item.isMine { library.rename(item.id, to: title) } }
        .toolbar {
            if item.isMine {
                Button(item.transcribed ? "Re-transcribe" : "Transcribe") {
                    Task { await library.transcribe(item.id) }
                }
                .disabled(library.transcribingID != nil)
            }
            if !text.isEmpty {
                ShareLink(item: text, subject: Text(item.recording.title))
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: PadLibrary
    @EnvironmentObject private var models: PadModels
    @EnvironmentObject private var sync: PadSync
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Recording") {
                    Picker("Language", selection: $library.language) {
                        Text("Hebrew").tag("he")
                        Text("English").tag("en")
                    }
                }
                Section {
                    ForEach(PadModel.all) { model in
                        modelRow(model)
                    }
                } header: { Text("Model") } footer: {
                    Text("Models run on this iPad. Keep Mila open while it transcribes.")
                }
                Section {
                    LabeledContent("Folder", value: sync.folderName ?? "Not linked")
                    Button(sync.folderName == nil ? "Choose Folder…" : "Change Folder…") { pickingFolder = true }
                    if sync.folderName != nil {
                        Button("Sync Now") { Task { await sync.sync() } }.disabled(sync.isSyncing)
                        if let last = sync.lastSync {
                            LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                        }
                        Button("Stop Syncing", role: .destructive) { sync.unlink() }
                    }
                    TextField("This device's name", text: $sync.deviceName)
                    if let error = sync.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                } header: { Text("Sync with Mila on your Mac") } footer: {
                    Text("Pick a folder in iCloud Drive. On the Mac, right-click a folder in Mila's sidebar → Share with Team… and choose the same folder. Recordings made on either side then show up on both.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { sync.link(url) }
            }
        }
    }

    @ViewBuilder private func modelRow(_ model: PadModel) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName)
                Text(model.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let fraction = models.downloads[model.name] {
                ProgressView(value: fraction).frame(width: 80)
            } else if models.installed.contains(model.name) {
                if models.selectedName == model.name {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                } else {
                    Button("Use") { models.selectedName = model.name }
                }
            } else {
                Button("Download") { models.download(model) }
            }
        }
        .swipeActions {
            if models.installed.contains(model.name) {
                Button("Delete", role: .destructive) { models.delete(model) }
            }
        }
    }
}
