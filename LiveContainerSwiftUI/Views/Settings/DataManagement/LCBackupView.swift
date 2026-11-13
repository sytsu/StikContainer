//
//  LCBackupView.swift
//  LiveContainerSwiftUI
//
//  Backups of everything LiveContainer holds, in the manner of Aidoku's backups: one file per
//  backup, a choice of what goes in, and a list to restore, share, rename or delete from.
//

import AppleArchive
import SwiftUI
import System
import UniformTypeIdentifiers

// MARK: - What a backup is

/// What a backup contains. Stored in the backup as `Backup/manifest.json`.
struct LCBackupManifest: Codable {
    var formatVersion = 1
    var name: String
    var date: Date
    var appVersion: String
    var includesApps: Bool
    var includesAppData: Bool
    var includesTweaks: Bool
    var includesSettings: Bool
    var includesSideStore: Bool?
    var appCount: Int
    var containerCount: Int
}

struct LCBackupOptions {
    var apps = true
    var appData = true
    var tweaks = true
    /// LiveContainer's own settings: every preference, the sources list, and the signing
    /// certificate with its password if one was imported.
    var settings = true
    /// The built-in SideStore's own data.
    var sideStore = true

    var isEmpty: Bool { !(apps || appData || tweaks || settings || sideStore) }
}

struct LCBackupFile: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum LCBackupError: LocalizedError {
    case archive(String)
    case notABackup
    case newerFormat

    var errorDescription: String? {
        switch self {
        case .archive(let what): return what
        case .notABackup: return "lc.backup.error.notABackup".loc
        case .newerFormat: return "lc.backup.error.newerFormat".loc
        }
    }
}

// MARK: - Making and restoring

/// A backup is one Apple Archive (LZFSE) file. Inside, paths keep the names of the places they
/// came from, so nothing has to be copied to a staging folder first:
///   Backup/…          manifest and preferences
///   Documents/…       the app's own storage (Applications, Data, Tweaks)
///   LiveContainer/…   the shared storage in the app group, when there is one
enum LCBackupManager {
    static let fileExtension = "lcbackup"
    static var directory: URL { LCPath.docPath.appendingPathComponent("Backups") }

    private static let metaFolder = "Backup"
    private static let fields = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")!
    /// Preferences that describe this launch, not the user's setup: never carried over.
    private static let transientKeys: Set<String> = ["selected", "selectedContainer", "LCLastLanguages"]

    static func list() -> [LCBackupFile] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == fileExtension }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LCBackupFile(url: url, date: values?.contentModificationDate ?? .distantPast, size: Int64(values?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    /// The shared storage, when it is a different place from the app's own.
    private static var sharedRoot: URL? {
        let shared = LCPath.lcGroupDocPath.standardizedFileURL
        return shared.path == LCPath.docPath.standardizedFileURL.path ? nil : shared
    }

    private static func count(_ folder: URL, suffix: String? = nil) -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.filter { !$0.hasPrefix(".") && (suffix == nil || $0.hasSuffix(suffix!)) }.count
    }

    // MARK: Create

    static func create(name: String, options: LCBackupOptions) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let fileName = (cleanName.isEmpty ? "Backup " + formatter.string(from: date) : cleanName) + "." + fileExtension
        var destination = directory.appendingPathComponent(fileName)
        if fm.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent((cleanName.isEmpty ? "Backup" : cleanName) + " " + formatter.string(from: date) + "." + fileExtension)
        }
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)

        // Manifest and preferences go through a small folder of their own.
        let staging = fm.temporaryDirectory.appendingPathComponent("lcbackup-" + UUID().uuidString)
        let meta = staging.appendingPathComponent(metaFolder)
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let shared = sharedRoot
        let manifest = LCBackupManifest(
            name: cleanName,
            date: date,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            includesApps: options.apps,
            includesAppData: options.appData,
            includesTweaks: options.tweaks,
            includesSettings: options.settings,
            includesSideStore: options.sideStore,
            appCount: options.apps ? count(LCPath.bundlePath, suffix: ".app") + (shared.map { count($0.appendingPathComponent("Applications"), suffix: ".app") } ?? 0) : 0,
            containerCount: options.appData ? count(LCPath.dataPath) + (shared.map { count($0.appendingPathComponent("Data/Application")) } ?? 0) : 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: meta.appendingPathComponent("manifest.json"))

        if options.settings {
            try writePreferences(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:],
                                 to: meta.appendingPathComponent("Preferences.plist"))
            if let group = LCSharedUtils.appGroupID(), let domain = UserDefaults.standard.persistentDomain(forName: group) {
                try writePreferences(domain, to: meta.appendingPathComponent("GroupPreferences.plist"))
            }
        }

        do {
            guard let file = ArchiveByteStream.fileStream(path: FilePath(partial.path), mode: .writeOnly, options: [.create, .truncate],
                                                          permissions: FilePermissions(rawValue: 0o644)),
                  let compress = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
                  let encode = ArchiveStream.encodeStream(writingTo: compress) else {
                throw LCBackupError.archive("lc.backup.error.cannotWrite".loc)
            }
            defer {
                try? encode.close()
                try? compress.close()
                try? file.close()
            }

            // The manifest first, then each place that was asked for and exists.
            try encode.writeDirectoryContents(archiveFrom: FilePath(staging.path), path: FilePath(metaFolder), keySet: fields)

            var folders: [String] = []
            if options.apps { folders.append("Applications") }
            if options.appData { folders += ["Data/Application", "Data/AppGroup"] }
            if options.tweaks { folders.append("Tweaks") }

            // Kept in the app's own storage only: the JIT pairing file that was imported, and SideStore.
            var ownFolders = folders
            if options.settings { ownFolders.append("StikJIT") }
            if options.sideStore { ownFolders.append("SideStore") }

            let documents = LCPath.docPath.standardizedFileURL
            for folder in ownFolders where fm.fileExists(atPath: documents.appendingPathComponent(folder).path) {
                try encode.writeDirectoryContents(archiveFrom: FilePath(documents.deletingLastPathComponent().path),
                                                  path: FilePath(documents.lastPathComponent + "/" + folder), keySet: fields)
            }
            if let shared {
                for folder in folders where fm.fileExists(atPath: shared.appendingPathComponent(folder).path) {
                    try encode.writeDirectoryContents(archiveFrom: FilePath(shared.deletingLastPathComponent().path),
                                                      path: FilePath(shared.lastPathComponent + "/" + folder), keySet: fields)
                }
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        try fm.moveItem(at: partial, to: destination)
        return destination
    }

    private static func writePreferences(_ domain: [String: Any], to url: URL) throws {
        let kept = domain.filter { !transientKeys.contains($0.key) }
        let data = try PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0)
        try data.write(to: url)
    }

    // MARK: Restore

    /// Unpacks the backup next to the live data, then moves each app, data container and tweak
    /// into place, replacing what has the same name and leaving everything else alone.
    static func restore(from backup: URL) throws -> LCBackupManifest {
        let fm = FileManager.default
        let staging = LCPath.docPath.appendingPathComponent(".lcbackup-restore-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        guard let file = ArchiveByteStream.fileStream(path: FilePath(backup.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress),
              let extract = ArchiveStream.extractStream(extractingTo: FilePath(staging.path), flags: [.ignoreOperationNotPermitted]) else {
            throw LCBackupError.notABackup
        }
        do {
            defer {
                try? extract.close()
                try? decode.close()
                try? decompress.close()
                try? file.close()
            }
            _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
        } catch {
            throw LCBackupError.notABackup
        }

        let meta = staging.appendingPathComponent(metaFolder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: meta.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(LCBackupManifest.self, from: data) else {
            throw LCBackupError.notABackup
        }
        guard manifest.formatVersion <= 1 else { throw LCBackupError.newerFormat }

        let folders = ["Applications", "Data/Application", "Data/AppGroup", "Tweaks"]
        // The app's own storage is "Documents" in every install; the shared one is "LiveContainer".
        try merge(folders + ["StikJIT", "SideStore"], from: staging.appendingPathComponent(LCPath.docPath.lastPathComponent), into: LCPath.docPath)
        let sharedBackup = staging.appendingPathComponent("LiveContainer")
        if fm.fileExists(atPath: sharedBackup.path) {
            // Without an app group on this install, shared apps become private ones rather than being lost.
            try merge(folders, from: sharedBackup, into: sharedRoot ?? LCPath.docPath)
        }

        if manifest.includesSettings {
            readPreferences(meta.appendingPathComponent("Preferences.plist"), into: UserDefaults.standard)
            if let group = LCSharedUtils.appGroupID(), let defaults = UserDefaults(suiteName: group) {
                readPreferences(meta.appendingPathComponent("GroupPreferences.plist"), into: defaults)
            }
        }
        return manifest
    }

    private static func merge(_ folders: [String], from source: URL, into destination: URL) throws {
        let fm = FileManager.default
        for folder in folders {
            let from = source.appendingPathComponent(folder)
            guard let items = try? fm.contentsOfDirectory(atPath: from.path) else { continue }
            let to = destination.appendingPathComponent(folder)
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for item in items {
                let target = to.appendingPathComponent(item)
                if fm.fileExists(atPath: target.path) || (try? target.checkResourceIsReachable()) == true {
                    try fm.removeItem(at: target)
                }
                try fm.moveItem(at: from.appendingPathComponent(item), to: target)
            }
        }
    }

    private static func readPreferences(_ url: URL, into defaults: UserDefaults) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for (key, value) in plist where !transientKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        defaults.synchronize()
    }

    // MARK: Files

    static func importBackup(from url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var name = url.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(name + "." + fileExtension)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            name = url.deletingPathExtension().lastPathComponent + " \(n)"
            destination = directory.appendingPathComponent(name + "." + fileExtension)
            n += 1
        }
        try fm.copyItem(at: url, to: destination)
        return destination
    }

    static func rename(_ backup: LCBackupFile, to newName: String) throws {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != backup.name else { return }
        try FileManager.default.moveItem(at: backup.url, to: directory.appendingPathComponent(clean + "." + fileExtension))
    }

    static func delete(_ backup: LCBackupFile) {
        try? FileManager.default.removeItem(at: backup.url)
    }
}

// MARK: - The screen

struct LCBackupView: View {
    @State private var backups: [LCBackupFile] = []
    @State private var options = LCBackupOptions()
    @State private var newName = ""
    @State private var isWorking = false
    @State private var workingText = ""
    @State private var errorText: String?
    @State private var pendingRestore: LCBackupFile?
    @State private var restored: LCBackupManifest?
    @State private var sharing: LCBackupFile?
    @State private var renaming: LCBackupFile?
    @State private var renameText = ""
    @State private var isImporting = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle("lc.backup.include.apps".loc, isOn: $options.apps)
                Toggle("lc.backup.include.appData".loc, isOn: $options.appData)
                Toggle("lc.backup.include.tweaks".loc, isOn: $options.tweaks)
                Toggle("lc.backup.include.settings".loc, isOn: $options.settings)
                Toggle("lc.backup.include.sideStore".loc, isOn: $options.sideStore)
                TextField("lc.backup.namePlaceholder".loc, text: $newName)
                    .disableAutocorrection(true)
                Button {
                    create()
                } label: {
                    if isWorking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(workingText)
                        }
                    } else {
                        Text("lc.backup.create".loc)
                    }
                }
                .disabled(isWorking || options.isEmpty)
            } header: {
                Text("lc.backup.newHeader".loc)
            } footer: {
                Text("lc.backup.newFooter".loc)
            }

            Section {
                if backups.isEmpty {
                    Text("lc.backup.none".loc)
                        .foregroundStyle(.secondary)
                }
                ForEach(backups) { backup in
                    Button {
                        pendingRestore = backup
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backup.name)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(Self.dateFormatter.string(from: backup.date) + " · " + ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isWorking)
                    .contextMenu {
                        Button("lc.backup.restore".loc, systemImage: "arrow.counterclockwise") { pendingRestore = backup }
                        Button("lc.backup.share".loc, systemImage: "square.and.arrow.up") { sharing = backup }
                        Button("lc.common.rename".loc, systemImage: "pencil") {
                            renameText = backup.name
                            renaming = backup
                        }
                        Button("lc.common.delete".loc, systemImage: "trash", role: .destructive) {
                            LCBackupManager.delete(backup)
                            reload()
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            LCBackupManager.delete(backup)
                            reload()
                        } label: {
                            Label("lc.common.delete".loc, systemImage: "trash")
                        }
                        Button {
                            sharing = backup
                        } label: {
                            Label("lc.backup.share".loc, systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text("lc.backup.listHeader".loc)
            } footer: {
                Text("lc.backup.listFooter".loc)
            }
        }
        .navigationTitle("lc.backup.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("lc.backup.import".loc, systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .disabled(isWorking)
            }
        }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            do {
                _ = try LCBackupManager.importBackup(from: url)
                reload()
            } catch {
                errorText = error.localizedDescription
            }
        }
        .sheet(item: $sharing) { backup in
            ActivityViewController(activityItems: [backup.url])
        }
        .alert("lc.common.error".loc, isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .alert("lc.backup.restoreConfirm.title".loc, isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("lc.backup.restore".loc, role: .destructive) {
                if let backup = pendingRestore { restore(backup) }
                pendingRestore = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) { pendingRestore = nil }
        } message: {
            Text("lc.backup.restoreConfirm.message %@".localizeWithFormat(pendingRestore?.name ?? ""))
        }
        .alert("lc.backup.restored.title".loc, isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } })) {
            // The app list and settings were read at launch: start again to show what was restored.
            Button("lc.backup.restored.quit".loc) { exit(0) }
        } message: {
            Text("lc.backup.restored.message %lld %lld".localizeWithFormat(restored?.appCount ?? 0, restored?.containerCount ?? 0))
        }
        .alert("lc.common.rename".loc, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("lc.backup.namePlaceholder".loc, text: $renameText)
            Button("lc.common.ok".loc) {
                if let backup = renaming {
                    do {
                        try LCBackupManager.rename(backup, to: renameText)
                    } catch {
                        errorText = error.localizedDescription
                    }
                    reload()
                }
                renaming = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) { renaming = nil }
        }
    }

    private func reload() {
        backups = LCBackupManager.list()
    }

    private func create() {
        let name = newName
        let chosen = options
        isWorking = true
        workingText = "lc.backup.creating".loc
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                _ = try LCBackupManager.create(name: name, options: chosen)
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            await MainActor.run {
                isWorking = false
                errorText = message
                if message == nil { newName = "" }
                reload()
            }
        }
    }

    private func restore(_ backup: LCBackupFile) {
        isWorking = true
        workingText = "lc.backup.restoring".loc
        Task.detached(priority: .userInitiated) {
            var failure: String?
            var manifest: LCBackupManifest?
            do {
                manifest = try LCBackupManager.restore(from: backup.url)
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            let result = manifest
            await MainActor.run {
                isWorking = false
                errorText = message
                restored = result
            }
        }
    }
}
