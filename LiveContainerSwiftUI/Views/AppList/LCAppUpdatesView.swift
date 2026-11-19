//
//  LCAppUpdatesView.swift
//  LiveContainerSwiftUI
//
//  The apps that have a newer version on the App Store, and the ways to install it:
//  from one of the sources that has it, or from a decrypted IPA. Either one replaces
//  the installed app and keeps its data and settings.
//

import Foundation
import SwiftUI
import UIKit

enum LCAppUpdateAction {
    case download(URL, LCAppModel)
    case chooseIPA(LCAppModel)
}

// A build of an app that one of the sources offers.
struct LCSourceBuild: Hashable {
    let sourceName: String
    let version: String
    let downloadURL: URL
}

struct LCAppUpdatesView: View {
    let apps: [LCAppModel]
    let onAction: (LCAppUpdateAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var checker = LCAppStoreUpdateChecker.shared

    @AppStorage(LCAppStoreUpdateChecker.enabledKey) private var checkEnabled = true
    @AppStorage(LCAppStoreUpdateChecker.regionKey) private var region = ""
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    // Keyed by lowercased bundle ID.
    @State private var sourceBuilds: [String: [LCSourceBuild]] = [:]
    @State private var isLoadingSources = false
    @State private var sourcesLoaded = false
    @State private var expandedNotes: Set<ObjectIdentifier> = []

    init(apps: [LCAppModel], onAction: @escaping (LCAppUpdateAction) -> Void) {
        self.apps = apps
        self.onAction = onAction
    }

    private static let regionCodes: [String] = Locale.isoRegionCodes.sorted {
        LCAppUpdatesView.regionName($0).localizedStandardCompare(LCAppUpdatesView.regionName($1)) == .orderedAscending
    }

    private static func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code.uppercased()
    }

    var body: some View {
        NavigationView {
            List {
                let updates = checkEnabled ? checker.updates(for: apps) : []

                Section {
                    if !checkEnabled {
                        Text("lc.appUpdates.disabledTip".loc)
                            .foregroundStyle(.secondary)
                    } else if updates.isEmpty {
                        HStack {
                            Text(checker.isChecking ? "lc.appUpdates.checking".loc : "lc.appUpdates.noUpdates".loc)
                                .foregroundStyle(.secondary)
                            if checker.isChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    } else {
                        ForEach(updates) { update in
                            updateRow(update)
                        }
                    }
                } header: {
                    Text("lc.appUpdates.availableHeader".loc)
                } footer: {
                    if checkEnabled {
                        statusFooter
                    }
                }

                Section {
                    Toggle("lc.appUpdates.autoCheck".loc, isOn: $checkEnabled)
                    Picker("lc.appUpdates.region".loc, selection: $region) {
                        Text("lc.appUpdates.regionAutomatic %@".localizeWithFormat(Self.regionName(LCAppStoreUpdateChecker.deviceRegion.uppercased())))
                            .tag("")
                        ForEach(Self.regionCodes, id: \.self) { code in
                            Text(Self.regionName(code)).tag(code.lowercased())
                        }
                    }
                    Button {
                        Task { await checkNow() }
                    } label: {
                        Text("lc.appUpdates.checkNow".loc)
                    }
                    .disabled(checker.isChecking || !checkEnabled)
                } header: {
                    Text("lc.appUpdates.settingsHeader".loc)
                } footer: {
                    Text("lc.appUpdates.settingsFooter".loc)
                }

                let ignored = ignoredApps
                if !ignored.isEmpty {
                    Section {
                        ForEach(ignored, id: \.self) { app in
                            HStack {
                                appIcon(app, size: 29)
                                Text(app.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Button("lc.appUpdates.unignore".loc) {
                                    checker.unignore(bundleIdentifier: app.bundleIdentifier)
                                    Task { await checkNow() }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("lc.appUpdates.ignoredHeader".loc)
                    }
                }
            }
            .refreshable {
                await checkNow()
            }
            .navigationTitle("lc.appUpdates.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .task {
            await checker.checkIfDue(bundleIdentifiers: apps.map { $0.bundleIdentifier })
            await loadSourceBuilds()
        }
        .onChange(of: checkEnabled) { enabled in
            checker.refreshViews()
            if enabled {
                Task { await checkNow() }
            }
        }
        .onChange(of: region) { _ in
            Task { await checkNow() }
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = checker.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }
            if let lastCheck = checker.lastCheck {
                Text("lc.appUpdates.lastChecked %@".localizeWithFormat(Self.relativeDate(lastCheck)))
            } else if !checker.isChecking {
                Text("lc.appUpdates.neverChecked".loc)
            }
        }
    }

    private var ignoredApps: [LCAppModel] {
        var seen = Set<String>()
        return apps.filter { app in
            let key = LCAppStoreUpdateChecker.key(app.bundleIdentifier)
            return checker.ignoredBundleIDs.contains(key) && seen.insert(key).inserted
        }
    }

    @ViewBuilder
    private func updateRow(_ update: LCAppStoreUpdate) -> some View {
        let app = update.app
        let release = update.release
        let build = bestSourceBuild(for: update)
        let notesExpanded = expandedNotes.contains(update.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                appIcon(app, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("lc.appUpdates.versionChange %@ %@".localizeWithFormat(app.version, release.version))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let date = release.releaseDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button {
                        checker.skip(release)
                    } label: {
                        Label("lc.appUpdates.skipVersion".loc, systemImage: "forward")
                    }
                    Button {
                        checker.ignore(bundleIdentifier: app.bundleIdentifier)
                    } label: {
                        Label("lc.appUpdates.ignoreApp".loc, systemImage: "bell.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
            }

            if let notes = release.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(notes)
                    .font(.footnote)
                    .lineLimit(notesExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut) {
                            expandedNotes.formSymmetricDifference([update.id])
                        }
                    }
            }

            if let build {
                Button {
                    onAction(.download(build.downloadURL, app))
                } label: {
                    Label("lc.appUpdates.installFromSource %@ %@".localizeWithFormat(build.version, build.sourceName), systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if isLoadingSources {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("lc.appUpdates.searchingSources".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if sourcesLoaded {
                Text("lc.appUpdates.notInSources".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    onAction(.chooseIPA(app))
                } label: {
                    Label("lc.appUpdates.chooseIpa".loc, systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let storeURL = release.storeURL {
                    Button {
                        UIApplication.shared.open(storeURL)
                    } label: {
                        Label("lc.appUpdates.viewInAppStore".loc, systemImage: "bag")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private func appIcon(_ app: LCAppModel, size: CGFloat) -> some View {
        Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon) ?? UIImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }

    // The newest build the sources have that is newer than the installed app.
    private func bestSourceBuild(for update: LCAppStoreUpdate) -> LCSourceBuild? {
        let builds = sourceBuilds[LCAppStoreUpdateChecker.key(update.app.bundleIdentifier)] ?? []
        return builds
            .filter { LCAppVersion.isNewer($0.version, than: update.app.version) }
            .max { LCAppVersion.compare($0.version, $1.version) == .orderedAscending }
    }

    @MainActor
    private func checkNow() async {
        await checker.check(bundleIdentifiers: apps.map { $0.bundleIdentifier })
        await loadSourceBuilds()
    }

    // Looks in the sources (the ones added in the Sources tab) for builds of the apps that have updates.
    @MainActor
    private func loadSourceBuilds() async {
        guard checkEnabled, !isLoadingSources else {
            return
        }
        let wanted = Set(checker.updates(for: apps).map { LCAppStoreUpdateChecker.key($0.app.bundleIdentifier) })
        guard !wanted.isEmpty else {
            return
        }
        let sourceURLs = (UserDefaults.standard.stringArray(forKey: "LCAltStoreSourceURLs") ?? []).compactMap { URL(string: $0) }
        guard !sourceURLs.isEmpty else {
            sourcesLoaded = true
            return
        }

        isLoadingSources = true
        var found: [String: [LCSourceBuild]] = [:]
        for url in sourceURLs {
            guard let loaded = try? await AltStoreSourceLoader.load(from: url) else {
                continue
            }
            let source = loaded.0
            for app in source.apps {
                let key = LCAppStoreUpdateChecker.key(app.bundleIdentifier)
                guard wanted.contains(key) else {
                    continue
                }
                var versions = app.versions
                if versions.isEmpty, let latest = app.latestVersion {
                    versions = [latest]
                }
                for version in versions {
                    found[key, default: []].append(LCSourceBuild(sourceName: source.name, version: version.version, downloadURL: version.downloadURL))
                }
            }
        }
        sourceBuilds = found
        isLoadingSources = false
        sourcesLoaded = true
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
