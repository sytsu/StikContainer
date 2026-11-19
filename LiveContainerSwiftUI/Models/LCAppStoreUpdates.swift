//
//  LCAppStoreUpdates.swift
//  LiveContainerSwiftUI
//
//  Looks up the installed apps on the App Store (Apple's public lookup service,
//  by bundle ID) and says which ones have a newer version there.
//
//  The App Store's own downloads are FairPlay-encrypted, and LiveContainer can't
//  run encrypted apps, so this only finds updates. The new version is installed
//  from one of the sources or from a decrypted IPA, over the installed app.
//

import Foundation
import Combine

struct LCAppStoreRelease: Codable, Equatable {
    let bundleIdentifier: String
    let trackId: Int
    let name: String
    let version: String
    let releaseNotes: String?
    let releaseDate: Date?
    let storeURL: URL?
    let fileSize: Int64?
    let region: String
}

struct LCAppStoreUpdate: Identifiable {
    let app: LCAppModel
    let release: LCAppStoreRelease

    var id: ObjectIdentifier { ObjectIdentifier(app) }
}

enum LCAppVersion {
    // The numbers in a version, so "1.10.2" is [1, 10, 2] and "2.0b3" is [2, 0, 3].
    static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).compactMap { Int($0) }
    }

    // Compares number by number, so 1.10 is newer than 1.9 and 2.3.0 is the same as 2.3.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parts(lhs)
        let right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard !parts(candidate).isEmpty, !parts(installed).isEmpty else {
            return false
        }
        return compare(candidate, installed) == .orderedDescending
    }
}

enum LCAppStoreLookupError: LocalizedError {
    case throttled
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .throttled:
            return "lc.appUpdates.error.throttled".loc
        case .http(let status):
            return "HTTP \(status)"
        }
    }
}

final class LCAppStoreUpdateChecker: ObservableObject {
    static let shared = LCAppStoreUpdateChecker()

    // Settings, also read with @AppStorage. Both live in UserDefaults.standard.
    static let enabledKey = "LCAppStoreUpdateCheck"
    static let regionKey = "LCAppStoreRegion"

    private static let releasesKey = "LCAppStoreReleases"
    private static let lastCheckKey = "LCAppStoreLastCheck"
    private static let checkedKey = "LCAppStoreCheckedBundleIDs"
    private static let skippedKey = "LCAppStoreSkippedVersions"
    private static let ignoredKey = "LCAppStoreIgnoredBundleIDs"
    private static let batchLookupKey = "LCAppStoreBatchLookupWorks"

    // How often the app list checks on its own, while LiveContainer is open.
    static let checkInterval: TimeInterval = 6 * 60 * 60
    // After a check that failed, how long the app list waits before trying again on its own.
    private static let retryInterval: TimeInterval = 10 * 60
    private static let batchSize = 25

    // Keyed by lowercased bundle ID.
    @Published private(set) var releases: [String: LCAppStoreRelease] = [:]
    @Published private(set) var skippedVersions: [String: String] = [:]
    @Published private(set) var ignoredBundleIDs: Set<String> = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?

    private var checkedBundleIDs: Set<String> = []
    private var lastAttempt: Date?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.releasesKey),
           let stored = try? JSONDecoder().decode([String: LCAppStoreRelease].self, from: data) {
            releases = stored
        }
        skippedVersions = defaults.dictionary(forKey: Self.skippedKey) as? [String: String] ?? [:]
        ignoredBundleIDs = Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
        checkedBundleIDs = Set(defaults.stringArray(forKey: Self.checkedKey) ?? [])
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var deviceRegion: String {
        (Locale.current.regionCode ?? "US").lowercased()
    }

    // The App Store region that is looked up: the one chosen, or the device's.
    static var region: String {
        let chosen = UserDefaults.standard.string(forKey: regionKey) ?? ""
        return chosen.isEmpty ? deviceRegion : chosen.lowercased()
    }

    static func key(_ bundleIdentifier: String) -> String {
        bundleIdentifier.lowercased()
    }

    // The newer App Store version of this app, unless it was skipped or the app isn't checked.
    func update(for app: LCAppModel) -> LCAppStoreRelease? {
        guard Self.isEnabled else {
            return nil
        }
        let key = Self.key(app.bundleIdentifier)
        guard !ignoredBundleIDs.contains(key),
              let release = releases[key],
              skippedVersions[key] != release.version,
              LCAppVersion.isNewer(release.version, than: app.version) else {
            return nil
        }
        return release
    }

    func updates(for apps: [LCAppModel]) -> [LCAppStoreUpdate] {
        apps.compactMap { app in
            update(for: app).map { LCAppStoreUpdate(app: app, release: $0) }
        }
        .sorted { $0.app.displayName.localizedStandardCompare($1.app.displayName) == .orderedAscending }
    }

    func skip(_ release: LCAppStoreRelease) {
        skippedVersions[Self.key(release.bundleIdentifier)] = release.version
        UserDefaults.standard.set(skippedVersions, forKey: Self.skippedKey)
    }

    func ignore(bundleIdentifier: String) {
        ignoredBundleIDs.insert(Self.key(bundleIdentifier))
        UserDefaults.standard.set(Array(ignoredBundleIDs), forKey: Self.ignoredKey)
    }

    func unignore(bundleIdentifier: String) {
        ignoredBundleIDs.remove(Self.key(bundleIdentifier))
        UserDefaults.standard.set(Array(ignoredBundleIDs), forKey: Self.ignoredKey)
    }

    // Tells the views that something they show changed, like the setting that turns checking on.
    func refreshViews() {
        objectWillChange.send()
    }

    // Checks when the last check is old enough, or when an app has been installed since.
    @MainActor
    func checkIfDue(bundleIdentifiers: [String]) async {
        guard Self.isEnabled, !isChecking else {
            return
        }
        if lastError != nil, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.retryInterval {
            return
        }
        let ids = Self.checkable(bundleIdentifiers, ignoring: ignoredBundleIDs)
        let isNewApp = ids.contains { !checkedBundleIDs.contains(Self.key($0)) }
        if let lastCheck, !isNewApp, Date().timeIntervalSince(lastCheck) < Self.checkInterval {
            return
        }
        await check(bundleIdentifiers: bundleIdentifiers)
    }

    @MainActor
    func check(bundleIdentifiers: [String]) async {
        guard !isChecking else {
            return
        }
        let ids = Self.checkable(bundleIdentifiers, ignoring: ignoredBundleIDs)
        guard !ids.isEmpty else {
            lastError = nil
            return
        }

        isChecking = true
        lastError = nil
        lastAttempt = Date()
        let region = Self.region
        let defaults = UserDefaults.standard
        let batchWorks = defaults.object(forKey: Self.batchLookupKey) as? Bool
        // Apps found on the App Store before go first, so the first request has two of them and
        // shows whether several bundle IDs can be asked for at once.
        let known = ids.filter { releases[Self.key($0)] != nil }
        let unknown = ids.filter { releases[Self.key($0)] == nil }
        let outcome = await Self.lookup(known + unknown, region: region, batchWorks: batchWorks)

        var newReleases = releases
        for key in outcome.checked {
            newReleases[key] = outcome.found[key]
        }
        releases = newReleases
        if let data = try? JSONEncoder().encode(newReleases) {
            defaults.set(data, forKey: Self.releasesKey)
        }
        if let works = outcome.batchWorks {
            defaults.set(works, forKey: Self.batchLookupKey)
        }

        if let error = outcome.error {
            if error is LCAppStoreLookupError {
                lastError = error.localizedDescription
            } else {
                lastError = "lc.appUpdates.error.failed %@".localizeWithFormat(error.localizedDescription)
            }
        } else {
            checkedBundleIDs = Set(ids.map { Self.key($0) })
            defaults.set(Array(checkedBundleIDs), forKey: Self.checkedKey)
            lastCheck = Date()
            defaults.set(lastCheck, forKey: Self.lastCheckKey)
        }
        isChecking = false
    }

    // Each bundle ID once, without placeholders for apps with a broken Info.plist.
    private static func checkable(_ bundleIdentifiers: [String], ignoring ignored: Set<String>) -> [String] {
        var seen = Set<String>()
        return bundleIdentifiers.filter { id in
            let key = Self.key(id)
            guard !id.isEmpty, id != "?", id != "Unknown", !ignored.contains(key) else {
                return false
            }
            return seen.insert(key).inserted
        }
    }

    private struct LookupOutcome {
        var found: [String: LCAppStoreRelease] = [:]
        var checked: Set<String> = []
        var batchWorks: Bool?
        var error: Error?
    }

    // Several bundle IDs are asked for in one request. If an answer can't show that this works
    // (it names no app but the first), the others are asked for one at a time, and what that
    // finds is remembered so later checks ask the right way straight away.
    private static func lookup(_ ids: [String], region: String, batchWorks: Bool?) async -> LookupOutcome {
        var outcome = LookupOutcome(batchWorks: batchWorks)
        let size = batchWorks == false ? 1 : batchSize
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + size, ids.count)])
            start += chunk.count
            do {
                var results = try await request(chunk, region: region)
                if chunk.count > 1 {
                    let first = key(chunk[0])
                    if results.keys.contains(where: { $0 != first }) {
                        outcome.batchWorks = true
                    } else if outcome.batchWorks != true {
                        for id in chunk.dropFirst() {
                            try await Task.sleep(nanoseconds: 500_000_000)
                            let single = try await request([id], region: region)
                            if !single.isEmpty {
                                outcome.batchWorks = false
                            }
                            results.merge(single) { current, _ in current }
                        }
                    }
                }
                outcome.found.merge(results) { current, _ in current }
                outcome.checked.formUnion(chunk.map { key($0) })
            } catch {
                outcome.error = error
                break
            }
            if size == 1 && start < ids.count {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return outcome
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]?
    }

    private struct LookupResult: Decodable {
        let bundleId: String?
        let trackId: Int?
        let trackName: String?
        let version: String?
        let releaseNotes: String?
        let currentVersionReleaseDate: String?
        let trackViewUrl: String?
        let fileSizeBytes: String?
    }

    private static func request(_ ids: [String], region: String) async throws -> [String: LCAppStoreRelease] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: ids.joined(separator: ",")),
            URLQueryItem(name: "country", value: region),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw LCAppStoreLookupError.throttled
            }
            if !(200...299).contains(http.statusCode) {
                throw LCAppStoreLookupError.http(http.statusCode)
            }
        }

        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        let wanted = Set(ids.map { key($0) })
        let dateFormatter = ISO8601DateFormatter()
        var releases: [String: LCAppStoreRelease] = [:]
        for result in decoded.results ?? [] {
            guard let bundleId = result.bundleId,
                  let version = result.version,
                  let trackId = result.trackId else {
                continue
            }
            let resultKey = key(bundleId)
            guard wanted.contains(resultKey), releases[resultKey] == nil else {
                continue
            }
            releases[resultKey] = LCAppStoreRelease(
                bundleIdentifier: bundleId,
                trackId: trackId,
                name: result.trackName ?? bundleId,
                version: version,
                releaseNotes: result.releaseNotes,
                releaseDate: result.currentVersionReleaseDate.flatMap { dateFormatter.date(from: $0) },
                storeURL: result.trackViewUrl.flatMap { URL(string: $0) },
                fileSize: result.fileSizeBytes.flatMap { Int64($0) },
                region: region
            )
        }
        return releases
    }

    // Whether the app's main executable is encrypted. An update from the App Store itself is,
    // and installing it over a working app would leave an app that can't be opened.
    static func isExecutableEncrypted(appBundle: URL) -> Bool {
        guard let infoPlist = NSDictionary(contentsOf: appBundle.appendingPathComponent("Info.plist")),
              let executable = infoPlist["CFBundleExecutable"] as? String else {
            return false
        }
        let path = appBundle.appendingPathComponent(executable).path
        var encrypted = false
        _ = LCParseMachO((path as NSString).utf8String, true) { _, header, _, _ in
            if let header = header {
                encrypted = encrypted || LCIsMachOEncrypted(header)
            }
        }
        return encrypted
    }
}
