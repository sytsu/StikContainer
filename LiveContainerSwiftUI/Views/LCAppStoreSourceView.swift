//
//  LCAppStoreSourceView.swift
//  LiveContainerSwiftUI
//
//  The built-in App Store source at the top of the Sources page: search the App Store,
//  see an app's latest version, what's new and its screenshots, and install or update it.
//
//  Apple only gets what is typed into the search. Whether an app is installed, and which
//  of the added sources has a build of it, is worked out on the device. The App Store's
//  own downloads are encrypted and can't run in LiveContainer, so Install and Update use
//  a source's build, or a decrypted IPA when no source has one.
//

import Foundation
import SwiftUI
import UIKit

// The App Store's entry on the Sources page.
struct LCAppStoreSourceCard: View {
    // What is typed into the Sources page's search, if anything.
    let query: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bag.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue))
            VStack(alignment: .leading, spacing: 2) {
                Text("lc.appStore.title".loc)
                    .font(.system(.title2).bold())
                Text(query.map { "lc.appStore.searchFor %@".localizeWithFormat($0) } ?? "lc.appStore.cardSubtitle".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: UIColor.secondarySystemBackground))
        )
        .contentShape(Rectangle())
    }
}

// Asked when no source has a build to install: a decrypted IPA has to be chosen.
struct LCAppStoreIPAPrompt: Identifiable {
    let id = UUID()
    let app: LCAppStoreApp
    let replacing: LCAppModel?
}

enum LCAppStoreActions {
    // Install or Update: a source's build if there is one, otherwise ask for a decrypted IPA.
    static func run(_ plan: LCAppStoreInstallPlan, for app: LCAppStoreApp, prompt: Binding<LCAppStoreIPAPrompt?>) {
        guard !plan.isUpToDate else {
            return
        }
        if let build = plan.build {
            LCAppStoreInstaller.install(build, replacing: plan.replacing)
        } else {
            prompt.wrappedValue = LCAppStoreIPAPrompt(app: app, replacing: plan.replacing)
        }
    }

    // A line about the installed copy and where the build comes from.
    static func status(_ plan: LCAppStoreInstallPlan) -> String? {
        if let installed = plan.installed {
            if plan.isUpToDate {
                return "lc.appStore.status.installed %@".localizeWithFormat(installed.version)
            }
            if let build = plan.build {
                return "lc.appStore.status.updateFromSource %@ %@ %@".localizeWithFormat(installed.version, build.version, build.sourceName)
            }
            return "lc.appStore.status.updateNoSource %@".localizeWithFormat(installed.version)
        }
        if let build = plan.build {
            return "lc.appStore.status.onSource %@ %@".localizeWithFormat(build.version, build.sourceName)
        }
        return nil
    }
}

extension View {
    func appStoreIPAPrompt(_ prompt: Binding<LCAppStoreIPAPrompt?>) -> some View {
        confirmationDialog(
            "lc.appStore.noBuild.title %@".localizeWithFormat(prompt.wrappedValue?.app.name ?? ""),
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: prompt.wrappedValue
        ) { item in
            Button("lc.appStore.chooseIpa".loc) {
                LCAppStoreInstaller.chooseIPA(replacing: item.replacing)
            }
            if let storeURL = item.app.storeURL {
                Button("lc.appStore.openInAppStore".loc) {
                    UIApplication.shared.open(storeURL)
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: { item in
            Text("lc.appStore.noBuild.message %@".localizeWithFormat(item.app.version))
        }
    }
}

struct LCAppStoreIconView: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image("DefaultIcon").resizable().scaledToFill()
            }
        }
    }
}

struct LCAppStoreInstallButton: View {
    let plan: LCAppStoreInstallPlan
    let action: () -> Void

    private var title: String {
        if plan.isUpToDate {
            return "lc.appStore.installed".loc
        }
        return plan.isUpdate ? "lc.appStore.update".loc : "lc.common.install".loc
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .bold()
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 16)
                .frame(minWidth: 70)
                .frame(height: 32)
                .background(Capsule().fill(plan.isUpToDate ? Color.gray : Color("FontColor")))
        }
        .buttonStyle(BasicButtonStyle())
        .disabled(plan.isUpToDate)
    }
}

struct LCAppStoreAppRow: View {
    let app: LCAppStoreApp
    let plan: LCAppStoreInstallPlan
    let onOpen: () -> Void
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    LCAppStoreIconView(url: app.iconURL)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 16))
                            .bold()
                            .lineLimit(1)
                        Text("\(app.version) • \(app.developer ?? app.bundleIdentifier)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let status = LCAppStoreActions.status(plan) {
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            LCAppStoreInstallButton(plan: plan, action: onInstall)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color("AppBannerBG"))
        )
    }
}

struct LCAppStoreSourceView: View {
    @ObservedObject var sources: AltStoreSourcesViewModel
    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage(LCAppStoreSearch.regionKey) private var region = ""

    @State private var query: String
    @State private var results: [LCAppStoreApp] = []
    @State private var searchedQuery: String?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var detailApp: LCAppStoreApp?
    @State private var isDetailActive = false
    @State private var ipaPrompt: LCAppStoreIPAPrompt?
    @FocusState private var isSearchFocused: Bool

    init(sources: AltStoreSourcesViewModel, initialQuery: String) {
        _sources = ObservedObject(wrappedValue: sources)
        _query = State(initialValue: initialQuery)
    }

    static let regionCodes: [String] = Locale.isoRegionCodes.sorted {
        LCAppStoreSourceView.regionName($0).localizedStandardCompare(LCAppStoreSourceView.regionName($1)) == .orderedAscending
    }

    static func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Hidden apps count only while they're unlocked.
    private var installedApps: [LCAppModel] {
        sharedModel.isHiddenAppUnlocked ? sharedModel.apps + sharedModel.hiddenApps : sharedModel.apps
    }

    private func plan(for app: LCAppStoreApp) -> LCAppStoreInstallPlan {
        LCAppStoreInstaller.plan(for: app, sources: sources.sources.compactMap { $0.source }, installedApps: installedApps)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                searchField

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if results.isEmpty {
                    placeholder
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(results) { app in
                            let appPlan = plan(for: app)
                            LCAppStoreAppRow(
                                app: app,
                                plan: appPlan,
                                onOpen: {
                                    detailApp = app
                                    isDetailActive = true
                                },
                                onInstall: {
                                    LCAppStoreActions.run(appPlan, for: app, prompt: $ipaPrompt)
                                }
                            )
                        }
                    }
                }

                Text("lc.appStore.footer".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .padding()
        }
        .background(
            NavigationLink(destination: detailDestination, isActive: $isDetailActive) {
                EmptyView()
            }
            .hidden()
        )
        .navigationTitle("lc.appStore.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                regionMenu
            }
        }
        .appStoreIPAPrompt($ipaPrompt)
        .onChange(of: query) { _ in
            scheduleSearch(delay: 600_000_000)
        }
        .onChange(of: region) { _ in
            scheduleSearch(delay: 0)
        }
        .onAppear {
            if trimmedQuery.isEmpty {
                isSearchFocused = true
            } else if results.isEmpty && searchedQuery == nil {
                scheduleSearch(delay: 0)
            }
        }
    }

    @ViewBuilder
    private var detailDestination: some View {
        if let app = detailApp {
            LCAppStoreAppDetailView(app: app, sources: sources)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("lc.appStore.searchPrompt".loc, text: $query)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit {
                    scheduleSearch(delay: 0)
                }
            if isSearching {
                ProgressView()
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: UIColor.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var placeholder: some View {
        if isSearching {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if let searchedQuery {
            if errorMessage == nil {
                Text("lc.appStore.noResults %@".localizeWithFormat(searchedQuery))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bag")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("lc.appStore.emptyTip".loc)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var regionMenu: some View {
        Menu {
            Picker("lc.appStore.region".loc, selection: $region) {
                Text("lc.appStore.regionAutomatic %@".localizeWithFormat(Self.regionName(LCAppStoreSearch.deviceRegion)))
                    .tag("")
                ForEach(Self.regionCodes, id: \.self) { code in
                    Text(Self.regionName(code)).tag(code.lowercased())
                }
            }
        } label: {
            Label("lc.appStore.region".loc, systemImage: "globe")
        }
    }

    // Searches after a pause in typing, or straight away; a newer search cancels an older one.
    @MainActor
    private func scheduleSearch(delay: UInt64) {
        searchTask?.cancel()
        let text = trimmedQuery
        guard !text.isEmpty else {
            searchTask = nil
            results = []
            searchedQuery = nil
            errorMessage = nil
            isSearching = false
            return
        }
        let searchRegion = LCAppStoreSearch.region
        searchTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else {
                return
            }
            isSearching = true
            do {
                let found = try await LCAppStoreSearch.search(text, region: searchRegion)
                guard !Task.isCancelled else {
                    return
                }
                results = found
                searchedQuery = text
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                errorMessage = "lc.appStore.error.failed %@".localizeWithFormat(error.localizedDescription)
            }
            isSearching = false
        }
    }
}

struct LCAppStoreAppDetailView: View {
    let app: LCAppStoreApp
    @ObservedObject var sources: AltStoreSourcesViewModel
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var ipaPrompt: LCAppStoreIPAPrompt?
    @State private var notesExpanded = false
    @State private var descriptionExpanded = false

    init(app: LCAppStoreApp, sources: AltStoreSourcesViewModel) {
        self.app = app
        _sources = ObservedObject(wrappedValue: sources)
    }

    private struct Fact: Hashable {
        let title: String
        let value: String
    }

    private var installedApps: [LCAppModel] {
        sharedModel.isHiddenAppUnlocked ? sharedModel.apps + sharedModel.hiddenApps : sharedModel.apps
    }

    private var facts: [Fact] {
        var list = [Fact(title: "lc.appStore.fact.version".loc, value: app.version)]
        if let date = app.releaseDate {
            list.append(Fact(title: "lc.appStore.fact.updated".loc, value: DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)))
        }
        if let size = app.fileSize {
            list.append(Fact(title: "lc.appStore.fact.size".loc, value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let rating = app.averageRating, let count = app.ratingCount, count > 0 {
            let stars = String(format: "%.1f", rating)
            list.append(Fact(title: "lc.appStore.fact.rating".loc, value: "★ \(stars) (\(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)))"))
        }
        if let genre = app.genre {
            list.append(Fact(title: "lc.appStore.fact.category".loc, value: genre))
        }
        if let minimumOS = app.minimumOSVersion {
            list.append(Fact(title: "lc.appStore.fact.requires".loc, value: "iOS \(minimumOS)"))
        }
        if let contentRating = app.contentRating {
            list.append(Fact(title: "lc.appStore.fact.ageRating".loc, value: contentRating))
        }
        if let price = app.price {
            list.append(Fact(title: "lc.appStore.fact.price".loc, value: price))
        }
        list.append(Fact(title: "lc.appStore.fact.bundleId".loc, value: app.bundleIdentifier))
        return list
    }

    private static func isLong(_ text: String) -> Bool {
        text.count > 180 || text.filter { $0 == "\n" }.count >= 4
    }

    var body: some View {
        let plan = LCAppStoreInstaller.plan(for: app, sources: sources.sources.compactMap { $0.source }, installedApps: installedApps)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(plan)
                whatsNewSection
                screenshotsSection
                descriptionSection
                informationSection
                Text("lc.appStore.footer".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let storeURL = app.storeURL {
                    Button {
                        UIApplication.shared.open(storeURL)
                    } label: {
                        Label("lc.appStore.openInAppStore".loc, systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        .appStoreIPAPrompt($ipaPrompt)
    }

    private func header(_ plan: LCAppStoreInstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                LCAppStoreIconView(url: app.iconURL)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.title2.bold())
                        .lineLimit(3)
                    if let developer = app.developer {
                        Text(developer)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    LCAppStoreInstallButton(plan: plan) {
                        LCAppStoreActions.run(plan, for: app, prompt: $ipaPrompt)
                    }
                }
            }
            if let status = LCAppStoreActions.status(plan) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whatsNewSection: some View {
        if let notes = app.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("lc.appStore.whatsNew".loc)
                    .font(.title3.bold())
                Text("lc.appStore.versionLine %@".localizeWithFormat(app.version))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(notes)
                    .font(.callout)
                    .lineLimit(notesExpanded ? nil : 4)
                    .textSelection(.enabled)
                if !notesExpanded && Self.isLong(notes) {
                    Button("lc.appStore.more".loc) {
                        notesExpanded = true
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        if !app.screenshotURLs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("lc.appStore.preview".loc)
                    .font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(app.screenshotURLs, id: \.self) { url in
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFit()
                                } else {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color(uiColor: UIColor.secondarySystemBackground))
                                        .frame(width: 166, height: 360)
                                }
                            }
                            .frame(maxWidth: 330, maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let text = app.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("lc.appStore.description".loc)
                    .font(.title3.bold())
                Text(text)
                    .font(.callout)
                    .lineLimit(descriptionExpanded ? nil : 6)
                    .textSelection(.enabled)
                if !descriptionExpanded && Self.isLong(text) {
                    Button("lc.appStore.more".loc) {
                        descriptionExpanded = true
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("lc.appStore.information".loc)
                .font(.title3.bold())
                .padding(.bottom, 6)
            ForEach(facts, id: \.self) { fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(fact.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.callout)
                .padding(.vertical, 8)
                Divider()
            }
        }
    }
}
