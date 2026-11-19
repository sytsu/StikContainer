//
//  LCAppStoreSearch.swift
//  LiveContainerSwiftUI
//
//  The built-in App Store source: searches Apple's public App Store search service
//  for what is typed (a name, a bundle ID or an App Store link) and nothing else.
//  Which apps are installed is only compared here, on the device.
//
//  The App Store's own downloads are FairPlay-encrypted, and LiveContainer can't run
//  encrypted apps, so an app found here is installed from one of the added sources
//  that has it, or from a decrypted IPA.
//

import Foundation

struct LCAppStoreApp: Identifiable, Hashable {
    let trackId: Int
    let bundleIdentifier: String
    let name: String
    let developer: String?
    let version: String
    let releaseNotes: String?
    let releaseDate: Date?
    let description: String?
    let iconURL: URL?
    let screenshotURLs: [URL]
    let storeURL: URL?
    let fileSize: Int64?
    let minimumOSVersion: String?
    let price: String?
    let averageRating: Double?
    let ratingCount: Int?
    let genre: String?
    let contentRating: String?

    var id: Int { trackId }
}

enum LCAppStoreSearchError: LocalizedError {
    case throttled
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .throttled:
            return "lc.appStore.error.throttled".loc
        case .http(let status):
            return "lc.appStore.error.http %lld".localizeWithFormat(status)
        }
    }
}

enum LCAppStoreSearch {
    // The App Store region searched, in UserDefaults.standard. Empty means the device's region.
    static let regionKey = "LCAppStoreRegion"

    static var deviceRegion: String {
        (Locale.current.regionCode ?? "US").lowercased()
    }

    static var region: String {
        let chosen = UserDefaults.standard.string(forKey: regionKey) ?? ""
        return chosen.isEmpty ? deviceRegion : chosen.lowercased()
    }

    // An App Store link or ID looks that app up, a bundle ID looks up that bundle ID
    // (and falls back to searching for it as words), anything else is searched for.
    static func search(_ rawQuery: String, region: String) async throws -> [LCAppStoreApp] {
        let text = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return []
        }
        if let link = appStoreLink(in: text) {
            return try await request(path: "/lookup", query: [
                "id": link.id,
                "country": link.region ?? region
            ])
        }
        if looksLikeBundleIdentifier(text) {
            let found = try await request(path: "/lookup", query: [
                "bundleId": text,
                "country": region
            ])
            if !found.isEmpty {
                return found
            }
        }
        return try await request(path: "/search", query: [
            "term": text,
            "country": region,
            "entity": "software",
            "limit": "50"
        ])
    }

    // "https://apps.apple.com/jp/app/name/id1234567890", "id1234567890" or "1234567890".
    private static func appStoreLink(in text: String) -> (id: String, region: String?)? {
        let lower = text.lowercased()
        let isDigits: (Substring) -> Bool = { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
        if lower.count >= 6 && isDigits(Substring(lower)) {
            return (lower, nil)
        }
        if lower.hasPrefix("id") && isDigits(lower.dropFirst(2)) {
            return (String(lower.dropFirst(2)), nil)
        }
        guard lower.contains("apple.com") || lower.hasPrefix("itms-apps:"),
              let range = lower.range(of: "/id[0-9]+", options: .regularExpression) else {
            return nil
        }
        let id = String(lower[range].dropFirst(3))
        var linkRegion: String? = nil
        if let url = URL(string: text), url.pathComponents.count > 1 {
            let first = url.pathComponents[1].lowercased()
            if first.count == 2 && first.allSatisfy({ $0.isASCII && $0.isLetter }) {
                linkRegion = first
            }
        }
        return (id, linkRegion)
    }

    private static func looksLikeBundleIdentifier(_ text: String) -> Bool {
        let allowed = text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" }
        return allowed && text.split(separator: ".").count >= 2
    }

    private static func request(path: String, query: [String: String]) async throws -> [LCAppStoreApp] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw LCAppStoreSearchError.throttled
            }
            if !(200...299).contains(http.statusCode) {
                throw LCAppStoreSearchError.http(http.statusCode)
            }
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let dateFormatter = ISO8601DateFormatter()
        var seen = Set<Int>()
        var apps: [LCAppStoreApp] = []
        for result in decoded.results {
            guard let trackId = result.trackId,
                  let bundleId = result.bundleId,
                  let version = result.version,
                  result.kind == nil || result.kind == "software",
                  seen.insert(trackId).inserted else {
                continue
            }
            let screenshots = result.screenshotUrls.isEmpty ? result.ipadScreenshotUrls : result.screenshotUrls
            apps.append(LCAppStoreApp(
                trackId: trackId,
                bundleIdentifier: bundleId,
                name: result.trackName ?? bundleId,
                developer: result.artistName ?? result.sellerName,
                version: version,
                releaseNotes: result.releaseNotes,
                releaseDate: result.currentVersionReleaseDate.flatMap { dateFormatter.date(from: $0) },
                description: result.description,
                iconURL: (result.artworkUrl512 ?? result.artworkUrl100).flatMap { URL(string: $0) },
                screenshotURLs: screenshots.compactMap { URL(string: $0) },
                storeURL: result.trackViewUrl.flatMap { URL(string: $0) },
                fileSize: result.fileSizeBytes,
                minimumOSVersion: result.minimumOsVersion,
                price: result.formattedPrice,
                averageRating: result.averageUserRating,
                ratingCount: result.userRatingCount,
                genre: result.primaryGenreName,
                contentRating: result.trackContentRating
            ))
        }
        return apps
    }

    private struct SearchResponse: Decodable {
        let results: [SearchResult]

        enum CodingKeys: String, CodingKey {
            case results
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            results = (try? container.decodeIfPresent([SearchResult].self, forKey: .results)) ?? []
        }
    }

    // Every field is optional and a field of an unexpected type is dropped, so one odd
    // value doesn't lose the whole answer.
    private struct SearchResult: Decodable {
        let kind: String?
        let trackId: Int?
        let bundleId: String?
        let trackName: String?
        let artistName: String?
        let sellerName: String?
        let version: String?
        let releaseNotes: String?
        let currentVersionReleaseDate: String?
        let description: String?
        let artworkUrl100: String?
        let artworkUrl512: String?
        let screenshotUrls: [String]
        let ipadScreenshotUrls: [String]
        let trackViewUrl: String?
        let fileSizeBytes: Int64?
        let minimumOsVersion: String?
        let formattedPrice: String?
        let averageUserRating: Double?
        let userRatingCount: Int?
        let primaryGenreName: String?
        let trackContentRating: String?

        enum CodingKeys: String, CodingKey {
            case kind, trackId, bundleId, trackName, artistName, sellerName, version, releaseNotes
            case currentVersionReleaseDate, description, artworkUrl100, artworkUrl512, screenshotUrls
            case ipadScreenshotUrls, trackViewUrl, fileSizeBytes, minimumOsVersion, formattedPrice
            case averageUserRating, userRatingCount, primaryGenreName, trackContentRating
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            trackId = try? c.decodeIfPresent(Int.self, forKey: .trackId)
            bundleId = try? c.decodeIfPresent(String.self, forKey: .bundleId)
            trackName = try? c.decodeIfPresent(String.self, forKey: .trackName)
            artistName = try? c.decodeIfPresent(String.self, forKey: .artistName)
            sellerName = try? c.decodeIfPresent(String.self, forKey: .sellerName)
            version = try? c.decodeIfPresent(String.self, forKey: .version)
            releaseNotes = try? c.decodeIfPresent(String.self, forKey: .releaseNotes)
            currentVersionReleaseDate = try? c.decodeIfPresent(String.self, forKey: .currentVersionReleaseDate)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            artworkUrl100 = try? c.decodeIfPresent(String.self, forKey: .artworkUrl100)
            artworkUrl512 = try? c.decodeIfPresent(String.self, forKey: .artworkUrl512)
            screenshotUrls = (try? c.decodeIfPresent([String].self, forKey: .screenshotUrls)) ?? []
            ipadScreenshotUrls = (try? c.decodeIfPresent([String].self, forKey: .ipadScreenshotUrls)) ?? []
            trackViewUrl = try? c.decodeIfPresent(String.self, forKey: .trackViewUrl)
            // A string of digits in Apple's answers; a number is taken too.
            if let text = try? c.decodeIfPresent(String.self, forKey: .fileSizeBytes) {
                fileSizeBytes = Int64(text)
            } else if let number = try? c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes) {
                fileSizeBytes = number
            } else {
                fileSizeBytes = nil
            }
            minimumOsVersion = try? c.decodeIfPresent(String.self, forKey: .minimumOsVersion)
            formattedPrice = try? c.decodeIfPresent(String.self, forKey: .formattedPrice)
            averageUserRating = try? c.decodeIfPresent(Double.self, forKey: .averageUserRating)
            userRatingCount = try? c.decodeIfPresent(Int.self, forKey: .userRatingCount)
            primaryGenreName = try? c.decodeIfPresent(String.self, forKey: .primaryGenreName)
            trackContentRating = try? c.decodeIfPresent(String.self, forKey: .trackContentRating)
        }
    }
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

// A build of an app that one of the added sources offers.
struct LCSourceBuild: Hashable {
    let sourceName: String
    let version: String
    let downloadURL: URL
}

// What Install or Update does for an app found on the App Store.
struct LCAppStoreInstallPlan {
    // The newest installed copy of the app, if any.
    let installed: LCAppModel?
    // Installed, and not older than the App Store's version.
    let isUpToDate: Bool
    // The newest build the sources have (newer than the installed copy, for an update).
    // Without one, a decrypted IPA has to be chosen.
    let build: LCSourceBuild?
    // The installed app an update replaces, when only one copy is installed.
    // With several, installing asks which one to replace.
    let replacing: LCAppModel?

    var isUpdate: Bool {
        installed != nil && !isUpToDate
    }
}

extension NSNotification {
    // Asks the app list to pick an IPA to install; object ["replacing": LCAppModel] to update that app.
    static let LCChooseIPANotification = Notification.Name("LCChooseIPANotification")
}

enum LCAppStoreInstaller {
    static func plan(for app: LCAppStoreApp, sources: [AltStoreSource], installedApps: [LCAppModel]) -> LCAppStoreInstallPlan {
        let key = app.bundleIdentifier.lowercased()
        let installed = installedApps.filter { $0.bundleIdentifier.lowercased() == key }
        let newestInstalled = installed.max { LCAppVersion.compare($0.version, $1.version) == .orderedAscending }
        let isUpToDate = newestInstalled.map { !LCAppVersion.isNewer(app.version, than: $0.version) } ?? false

        var builds = sourceBuilds(bundleKey: key, in: sources)
        if let newestInstalled {
            builds = builds.filter { LCAppVersion.isNewer($0.version, than: newestInstalled.version) }
        }
        let build = builds.max { LCAppVersion.compare($0.version, $1.version) == .orderedAscending }

        return LCAppStoreInstallPlan(
            installed: newestInstalled,
            isUpToDate: isUpToDate,
            build: build,
            replacing: installed.count == 1 ? installed.first : nil
        )
    }

    private static func sourceBuilds(bundleKey: String, in sources: [AltStoreSource]) -> [LCSourceBuild] {
        var builds: [LCSourceBuild] = []
        for source in sources {
            for app in source.apps where app.bundleIdentifier.lowercased() == bundleKey {
                var versions = app.versions
                if versions.isEmpty, let latest = app.latestVersion {
                    versions = [latest]
                }
                for version in versions {
                    builds.append(LCSourceBuild(sourceName: source.name, version: version.version, downloadURL: version.downloadURL))
                }
            }
        }
        return builds
    }

    // Downloads the build and installs it in the Apps tab, over `replacing` without asking.
    static func install(_ build: LCSourceBuild, replacing: LCAppModel?) {
        var payload: [String: Any] = ["url": build.downloadURL]
        if let replacing {
            payload["replacing"] = replacing
        }
        post(NSNotification.InstallAppNotification, payload: payload)
    }

    // Lets the Apps tab pick a decrypted IPA, which replaces `replacing` without asking.
    static func chooseIPA(replacing: LCAppModel?) {
        var payload: [String: Any] = [:]
        if let replacing {
            payload["replacing"] = replacing
        }
        post(NSNotification.LCChooseIPANotification, payload: payload)
    }

    private static func post(_ name: Notification.Name, payload: [String: Any]) {
        DataManager.shared.model.selectedTab = .apps
        // The Apps tab shows the install's progress once it's on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: name, object: payload)
        }
    }

    // Whether the app's main executable is encrypted, as the App Store's own downloads are.
    // Installing one over a working app would leave an app that can't be opened.
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
