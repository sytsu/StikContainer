//
//  LCAltStoreSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15.
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

struct AltStoreSourceAppVersion: Identifiable, Hashable {
    let id = UUID()
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
}

struct AltStoreSourceApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let tintColor: Color?
    let screenshots: [URL]
    let versions: [AltStoreSourceAppVersion]
    let latestVersion: AltStoreSourceAppVersion?
    let isBeta: Bool
}

struct AltStoreSource: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let headerURL: URL?
    let tintColor: Color?
    let website: URL?
    let apps: [AltStoreSourceApp]
}

private struct AltStoreSourceResponse: Decodable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let tintColor: String?
    let website: String?
    let apps: [AltStoreSourceAppResponse]?
}

private struct AltStoreSourceAppResponse: Decodable {
    let beta: Bool?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let screenshotURLs: [String]?
    let versions: [AltStoreSourceAppVersionResponse]?
    
    enum CodingKeys: String, CodingKey {
        case beta
        case name
        case bundleIdentifier
        case developerName
        case subtitle
        case version
        case versionDate
        case versionDescription
        case downloadURL
        case localizedDescription
        case iconURL
        case tintColor
        case screenshotURLs
        case versions
    }
}

private struct AltStoreSourceAppVersionResponse: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    
    enum CodingKeys: String, CodingKey {
        case version
        case buildVersion = "buildNumber"
        case date
        case localizedDescription
        case downloadURL
        case size
    }
}

@MainActor
final class AltStoreSourcesViewModel: ObservableObject {
    struct SourceItem: Identifiable, Hashable {
        let id: URL
        let url: URL
        var source: AltStoreSource?
        var isLoading: Bool
        var error: String?
        
        init(url: URL, isLoading: Bool = false, source: AltStoreSource? = nil, error: String? = nil) {
            self.url = url
            self.id = url
            self.isLoading = isLoading
            self.source = source
            self.error = error
        }
        
        var displayName: String {
            if let source {
                return source.name
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
            return url.absoluteString
        }
        
        var primaryIconURL: URL? {
            if let icon = source?.iconURL {
                return icon
            }
            if let appIcon = source?.apps.first(where: { $0.iconURL != nil })?.iconURL {
                return appIcon
            }
            return nil
        }
    }
    
    @Published private(set) var sources: [SourceItem] = []
    @Published var isRefreshingAll = false
    private let defaultsKey = "LCAltStoreSourceURLs"

    private let cacheDirectoryName = "AltStoreSourceCache"
    
    init() {
        loadStoredSources()
        Task {
            await refreshAllSources()
        }
    }
    
    func addSource(from rawValue: String) async -> String? {
        guard let normalizedURL = normalizeSourceURL(from: rawValue) else {
            return "lc.sources.error.invalidUrl".loc
        }
        
        if sources.contains(where: { $0.url == normalizedURL }) {
            return "lc.sources.error.duplicate".loc
        }
        
        sources.append(SourceItem(url: normalizedURL, isLoading: true))
        persistSources()
        await refreshSource(url: normalizedURL)
        return nil
    }
    
    func removeSource(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        persistSources()
        removeCache(for: item.url)
    }
    
    func refreshSource(_ item: SourceItem) async {
        await refreshSource(url: item.url)
    }
    
    func refreshAllSources() async {
        guard !sources.isEmpty else {
            return
        }
        isRefreshingAll = true
        for url in sources.map({ $0.url }) {
            await refreshSource(url: url)
        }
        isRefreshingAll = false
    }
    
    private func refreshSource(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else {
            return
        }
        sources[index].isLoading = true
        sources[index].error = nil
        let previousData = cachedData(for: url)
        do {
            let (source, data) = try await AltStoreSourceLoader.load(from: url)
            guard let sourceIndex = sources.firstIndex(where: { $0.url == url }) else {
                return
            }
            if let previousData, previousData == data {
                sources[sourceIndex].isLoading = false
                return
            }
            sources[sourceIndex].source = source
            sources[sourceIndex].isLoading = false
            storeCache(data, for: url)
        } catch {
            if let sourceIndex = sources.firstIndex(where: { $0.url == url }) {
                sources[sourceIndex].error = error.localizedDescription
                sources[sourceIndex].isLoading = false
            }
        }
    }
    
    private func loadStoredSources() {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: defaultsKey) as? [String] ?? []
        let urls = stored.compactMap { URL(string: $0) }
        self.sources = urls.map { SourceItem(url: $0, isLoading: false) }
        for index in sources.indices {
            let url = sources[index].url
            if let data = cachedData(for: url),
               let cachedSource = try? AltStoreSourceLoader.decode(from: data, baseURL: url) {
                sources[index].source = cachedSource
            }
        }
    }
    
    private func persistSources() {
        let urls = sources.map { $0.url.absoluteString }
        UserDefaults.standard.set(urls, forKey: defaultsKey)
    }
    
    private func normalizeSourceURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        if let httpsURL = URL(string: "https://\(trimmed)") {
            return httpsURL
        }
        return nil
    }
}

private extension AltStoreSourcesViewModel {
    func cachedData(for url: URL) -> Data? {
        guard let fileURL = cacheFileURL(for: url) else { return nil }
        return try? Data(contentsOf: fileURL)
    }
    
    func storeCache(_ data: Data, for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore cache write errors
        }
    }
    
    func cacheFileURL(for url: URL) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let fileName = cacheFileName(for: url)
        return directory.appendingPathComponent(fileName)
    }
    
    func ensureCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
    
    func cacheFileName(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }
    
    func removeCache(for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Ignore cache removal errors
        }
    }
}

enum AltStoreSourceLoader {
    static func load(from url: URL) async throws -> (AltStoreSource, Data) {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "AltStoreSource", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }
        let source = try decode(from: data, baseURL: url)
        return (source, data)
    }
    
    static func decode(from data: Data, baseURL: URL) throws -> AltStoreSource {
        try decodeSource(from: data, baseURL: baseURL)
    }
    
    private static func decodeSource(from data: Data, baseURL: URL) throws -> AltStoreSource {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let isoDate = ISO8601DateFormatter().date(from: rawValue) {
                return isoDate
            }
            let shortFormatter = DateFormatter()
            shortFormatter.dateFormat = "yyyy-MM-dd"
            if let shortDate = shortFormatter.date(from: rawValue) {
                return shortDate
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(rawValue)")
        })
        
        let response = try decoder.decode(AltStoreSourceResponse.self, from: data)
        guard let name = response.name else {
            throw NSError(domain: "AltStoreSource", code: 0, userInfo: [NSLocalizedDescriptionKey: "lc.sources.error.malformed".loc])
        }
        let apps = (response.apps ?? []).compactMap { appResponse in
            buildApp(from: appResponse, baseURL: baseURL, fallbackTint: response.tintColor)
        }
        return AltStoreSource(
            name: name,
            identifier: response.identifier,
            subtitle: response.subtitle,
            description: response.description,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            headerURL: url(for: response.headerURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor),
            website: url(for: response.website, baseURL: baseURL),
            apps: apps
        )
    }
    
    private static func buildApp(from response: AltStoreSourceAppResponse, baseURL: URL, fallbackTint: String?) -> AltStoreSourceApp? {
        guard let name = response.name,
              let bundleIdentifier = response.bundleIdentifier else {
            return nil
        }
        
        let versions = buildVersions(from: response, baseURL: baseURL)
        let latest = versions.first ?? buildLegacyVersion(from: response, baseURL: baseURL)
        
        return AltStoreSourceApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            developerName: response.developerName,
            subtitle: response.subtitle,
            description: response.localizedDescription ?? response.versionDescription,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor ?? fallbackTint),
            screenshots: (response.screenshotURLs ?? []).compactMap { url(for: $0, baseURL: baseURL) },
            versions: versions,
            latestVersion: latest,
            isBeta: response.beta ?? false
        )
    }
    
    private static func buildVersions(from response: AltStoreSourceAppResponse, baseURL: URL) -> [AltStoreSourceAppVersion] {
        guard let versions = response.versions else { return [] }
        return versions.compactMap { version in
            guard let versionString = version.version,
                  let downloadURLString = version.downloadURL,
                  let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
                return nil
            }
            return AltStoreSourceAppVersion(
                version: versionString,
                buildVersion: version.buildVersion,
                releaseDate: parseDate(version.date),
                localizedDescription: version.localizedDescription,
                downloadURL: downloadURL,
                size: version.size
            )
        }
    }
    
    private static func buildLegacyVersion(from response: AltStoreSourceAppResponse, baseURL: URL) -> AltStoreSourceAppVersion? {
        guard let versionString = response.version,
              let downloadURLString = response.downloadURL,
              let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
            return nil
        }
        return AltStoreSourceAppVersion(
            version: versionString,
            buildVersion: nil,
            releaseDate: parseDate(response.versionDate),
            localizedDescription: response.versionDescription ?? response.localizedDescription,
            downloadURL: downloadURL,
            size: nil
        )
    }
    
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let isoDate = ISO8601DateFormatter().date(from: value) {
            return isoDate
        }
        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "yyyy-MM-dd"
        return shortFormatter.date(from: value)
    }
    
    private static func url(for string: String?, baseURL: URL) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        if let absoluteURL = URL(string: string), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }
    
    private static func color(from hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        return Color(hexString: hex)
    }
}

private extension Color {
    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")
        
        if cleaned.count == 3 {
            var expanded = ""
            for character in cleaned {
                expanded.append(character)
                expanded.append(character)
            }
            cleaned = expanded
        }
        
        if cleaned.count == 6 {
            cleaned.append("FF")
        }
        
        guard cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        
        let red = Double((value & 0xFF00_0000) >> 24) / 255.0
        let green = Double((value & 0x00FF_0000) >> 16) / 255.0
        let blue = Double((value & 0x0000_FF00) >> 8) / 255.0
        let alpha = Double(value & 0x0000_00FF) / 255.0
        
        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Finds AltStore sources from whatever the user has: a source link, an `altstore://` style
/// link, a web page or list that mentions sources, a GitHub repository, or just words.
/// There is no central directory of sources, so words are looked up on GitHub and in a
/// community-kept list, and every candidate is loaded and checked before it is shown.
enum AltStoreSourceFinder {
    struct Found: Identifiable, Hashable {
        let url: URL
        let source: AltStoreSource
        var id: URL { url }
        var iconURL: URL? {
            source.iconURL ?? source.apps.first(where: { $0.iconURL != nil })?.iconURL
        }
        /// The same source is often reachable at more than one address (a branch name and
        /// HEAD, a mirror): two finds with the same fingerprint are one source.
        var fingerprint: String {
            "\(source.identifier ?? source.name)|\(source.apps.count)|\(source.apps.first?.bundleIdentifier ?? "")"
        }
    }
    
    /// A community-kept list of sources, used when the query is words (or empty).
    private static let communityListURL = URL(string: "https://raw.githubusercontent.com/victordedomenico/awesome-altstore/main/README.md")!
    /// File names sources commonly have at the top of a repository.
    private static let commonFileNames = ["apps.json", "repo.json", "source.json", "altstore.json", "sidestore.json", "altsource.json", "AltStore.json", "app-repo.json"]
    private static let maxCandidates = 60
    
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()
    
    /// Calls `onFound` for each source as soon as it has been checked.
    static func find(_ rawQuery: String, onFound: @escaping (Found) async -> Void) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var urls: [URL] = []
        var words = ""
        
        let pasted = links(in: query)
        if !pasted.isEmpty {
            // One or more links: each may be a source, a repository, or a page that lists sources.
            for link in pasted {
                urls.append(contentsOf: await candidates(from: link))
            }
        } else if let repo = repositoryPath(in: query) {
            urls = await candidatesFromRepository(repo)
        } else if looksLikeHost(query), let url = URL(string: "https://" + query) {
            urls = await candidates(from: url)
        } else {
            urls = await candidatesFromSearch(query)
            words = query
        }
        
        await check(unique(urls), matching: words, onFound: onFound)
    }
    
    // MARK: Candidates
    
    private static func candidates(from url: URL) async -> [URL] {
        if let inner = embeddedSourceURL(in: url) {
            return [inner]
        }
        if let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com",
           let repo = repositoryPath(in: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), !url.path.contains("/blob/"), !url.path.contains("/raw/") {
            return await candidatesFromRepository(repo)
        }
        // Either a source itself, or text that mentions sources.
        guard let (data, _) = try? await session.data(from: url) else { return [] }
        if (try? AltStoreSourceLoader.decode(from: data, baseURL: url)) != nil {
            return [url]
        }
        guard data.count < 4_000_000, let text = String(data: data, encoding: .utf8) else { return [] }
        return sourceLinks(in: text, relativeTo: url)
    }
    
    private static func candidatesFromRepository(_ repo: String) async -> [URL] {
        var found: [URL] = []
        // The README usually says where the source is.
        for name in ["README.md", "readme.md", "README"] {
            guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(name)"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { continue }
            found.append(contentsOf: sourceLinks(in: text, relativeTo: url))
            break
        }
        for name in commonFileNames {
            if let url = URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(name)") { found.append(url) }
        }
        for name in ["repo.json", "apps.json", "source.json"] {
            if let url = URL(string: "https://github.com/\(repo)/releases/latest/download/\(name)") { found.append(url) }
        }
        return found
    }
    
    private static func candidatesFromSearch(_ query: String) async -> [URL] {
        var found: [URL] = []
        // The community list: every source in it is checked, and kept if it matches the words.
        if let (data, _) = try? await session.data(from: communityListURL), let text = String(data: data, encoding: .utf8) {
            found.append(contentsOf: sourceLinks(in: text, relativeTo: communityListURL))
        }
        guard !query.isEmpty else { return found }
        // GitHub: repositories about the words and AltStore or SideStore.
        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(query) altstore OR sidestore in:name,description,topics,readme"),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "per_page", value: "8"),
        ]
        struct SearchResponse: Decodable {
            struct Repo: Decodable { let full_name: String }
            let items: [Repo]
        }
        if let url = components.url, let (data, _) = try? await session.data(from: url),
           let response = try? JSONDecoder().decode(SearchResponse.self, from: data) {
            await withTaskGroup(of: [URL].self) { group in
                for repo in response.items {
                    group.addTask { await candidatesFromRepository(repo.full_name) }
                }
                for await urls in group { found.append(contentsOf: urls) }
            }
        }
        return found
    }
    
    // MARK: Checking
    
    /// Load every candidate, a few at a time, and report the ones that really are sources.
    /// With words to match, a source is kept when its name, or one of its apps, has them.
    private static func check(_ urls: [URL], matching words: String, onFound: @escaping (Found) async -> Void) async {
        let terms = words.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        let limited = Array(urls.prefix(maxCandidates))
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < limited.count else { return }
                let url = limited[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled,
                          let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
                          let source = try? AltStoreSourceLoader.decode(from: data, baseURL: url),
                          !source.apps.isEmpty, matches(source, url: url, terms: terms) else { return }
                    await onFound(Found(url: url, source: source))
                }
            }
            for _ in 0..<8 { addNext() }
            for await _ in group { addNext() }
        }
    }
    
    private static func matches(_ source: AltStoreSource, url: URL, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        var haystack = source.name.lowercased() + " " + url.absoluteString.lowercased()
        haystack += " " + (source.subtitle ?? "").lowercased() + " " + (source.description ?? "").lowercased()
        return terms.allSatisfy { term in
            haystack.contains(term) || source.apps.contains(where: {
                $0.name.lowercased().contains(term) || $0.bundleIdentifier.lowercased().contains(term)
                    || ($0.developerName?.lowercased().contains(term) ?? false)
            })
        }
    }
    
    // MARK: Parsing
    
    /// `altstore://source?url=…`, `sidestore://source?url=…`, `livecontainer://source?url=…` and the like.
    private static func embeddedSourceURL(in url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https", scheme != "file",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        return URL(string: value)
    }
    
    /// Every link in a piece of text, of any scheme.
    private static func links(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>\)\]]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { range in
                URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;")))
            }
        }
    }
    
    /// Links in a page or a list that could be sources: JSON files, and source links for store apps.
    private static func sourceLinks(in text: String, relativeTo base: URL) -> [URL] {
        var found: [URL] = []
        for link in links(in: text) {
            if let inner = embeddedSourceURL(in: link) {
                found.append(inner)
            } else if let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                let path = link.path.lowercased()
                if path.hasSuffix(".json") || link.absoluteString.lowercased().contains("source?url=") {
                    if let value = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                       let inner = URL(string: value) {
                        found.append(inner)
                    } else {
                        found.append(link)
                    }
                }
            }
        }
        return found
    }
    
    /// "owner/name", as GitHub writes repositories.
    private static func repositoryPath(in text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, !text.contains(" "), !text.contains("://") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts[0].unicodeScalars.allSatisfy(allowed.contains), parts[1].unicodeScalars.allSatisfy(allowed.contains),
              !parts[0].contains(".") else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return parts[0] + "/" + name
    }
    
    private static func looksLikeHost(_ text: String) -> Bool {
        !text.contains(" ") && text.contains(".") && !text.hasPrefix(".") && !text.hasSuffix(".")
    }
    
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}

struct LCSourcesView: View {
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @ObservedObject public var searchContext: SearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var isViewAppeared = false
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("lc.sources.empty".loc)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.sources, id: \.id) { item in
                                let apps = filteredApps(for: item)
                                AltStoreSourceSectionView(
                                    item: item,
                                    filteredApps: apps,
                                    isFiltering: isFiltering,
                                    isExpanded: expandedSources.contains(item.id),
                                    onRefresh: { Task { await viewModel.refreshSource(item) } },
                                    onInstall: install(app:),
                                    onRemove: { sourcePendingRemoval = item },
                                    toggleExpanded: { toggleExpansion(for: item.id) }
                                )
                                .padding(.horizontal)
                                .animation(.easeInOut, value: apps.count)
                            }
                            
                            if totalFilteredAppCount == 0 {
                                VStack(spacing: 8) {
                                    Text("lc.sources.section.noApps".loc)
                                        .foregroundStyle(.gray)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 160, alignment: .center)
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("lc.tabView.sources".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.isRefreshingAll {
                        ProgressView()
                    } else {
                        Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshAllSources() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.sources.addSource".loc, systemImage: "plus") {
                        isManagingSources = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("lc.sources.removeConfirmation.title".loc, isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let sourcePendingRemoval {
                    viewModel.removeSource(sourcePendingRemoval)
                }
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: {
            if let name = sourcePendingRemoval?.displayName {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(name))
            } else {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(""))
            }
        }
        .sheet(isPresented: $isManagingSources) {
            if #available(iOS 16.0, *) {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
                .presentationDetents([.large])
            } else {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
            }
        }
        .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))

        .onAppear {
            expandedSources = []
            if !isViewAppeared {
                guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: viewModel.sources) { newSources in
            let newSet = Set(newSources.map { $0.id })
            expandedSources = expandedSources.intersection(newSet)
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }
    
    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }
    
    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source.apps
        }
        return source.apps.filter { app in
            let lower = query.lowercased()
            if app.name.lowercased().contains(lower) {
                return true
            }
            if app.bundleIdentifier.lowercased().contains(lower) {
                return true
            }
            if let developer = app.developerName?.lowercased(), developer.contains(lower) {
                return true
            }
            if let subtitle = app.subtitle?.lowercased(), subtitle.contains(lower) {
                return true
            }
            return false
        }
    }
    
    @MainActor
    private func handleAddSource(_ rawValue: String) async -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let error = await viewModel.addSource(from: trimmed)
        if let error {
            errorMessage = error
            return false
        }
        return true
    }
    
    @MainActor
    private func install(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
        }


    }
    
    private func toggleExpansion(for id: URL) {
        withAnimation(.easeInOut) {
            if expandedSources.contains(id) {
                expandedSources.remove(id)
            } else {
                expandedSources.insert(id)
            }
        }
    }
    
    func handleURL(url : URL) {
        if url.host == "source" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var sourceUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        sourceUrl = installUrl1
                    }
                }
                if let sourceUrl {
                    DataManager.shared.model.selectedTab = .sources
                    Task { await handleAddSource(sourceUrl) }
                }
            }
        }
    }
}

private struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> Bool
    
    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @FocusState private var isManualFieldFocused: Bool
    
    @State private var findQuery = ""
    @State private var findResults: [AltStoreSourceFinder.Found] = []
    @State private var isFinding = false
    @State private var didFind = false
    @State private var findTask: Task<Void, Never>?
    @State private var addingFound: Set<URL> = []
    @FocusState private var isFindFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            HStack(alignment: .top, spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("lc.sources.copyUrl".loc, systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = item.url.absoluteString
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                                Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive) {
                                    sourcePendingRemoval = item
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.manage.current".loc)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($isManualFieldFocused)
                        
                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
                
                Section {
                    HStack(spacing: 8) {
                        TextField("lc.sources.find.placeholder".loc, text: $findQuery)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .submitLabel(.search)
                            .focused($isFindFieldFocused)
                            .onSubmit(startFinding)
                        if isFinding {
                            ProgressView()
                        } else {
                            Button(action: startFinding) {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    ForEach(findResults) { found in
                        HStack(alignment: .center, spacing: 12) {
                            SourceIconView(url: found.iconURL)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(found.source.name)
                                    .bold()
                                    .lineLimit(1)
                                Text("lc.sources.find.appCount %lld".localizeWithFormat(found.source.apps.count) + " · " + (found.url.host ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if viewModel.sources.contains(where: { $0.url == found.url }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if addingFound.contains(found.url) {
                                ProgressView()
                            } else {
                                Button("lc.sources.find.add".loc) {
                                    add(found)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                            }
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("lc.sources.copyUrl".loc, systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = found.url.absoluteString
                            }
                        }
                    }
                    
                    if didFind, !isFinding, findResults.isEmpty {
                        Text("lc.sources.find.none".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("lc.sources.find.header".loc)
                } footer: {
                    Text("lc.sources.find.footer".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func resolvedIconURL(for item: AltStoreSourcesViewModel.SourceItem) -> URL? {
        if let icon = item.primaryIconURL {
            return icon
        }
        if let existing = viewModel.sources.first(where: { $0.url == item.url }) {
            if let icon = existing.primaryIconURL {
                return icon
            }
        }
        return nil
    }
    
    /// Look for sources matching what was typed: a link, a page, a GitHub repository, or words.
    private func startFinding() {
        findTask?.cancel()
        isFindFieldFocused = false
        let query = findQuery
        isFinding = true
        didFind = true
        findResults = []
        findTask = Task {
            await AltStoreSourceFinder.find(query) { found in
                await MainActor.run {
                    if !Task.isCancelled, !findResults.contains(where: { $0.url == found.url || $0.fingerprint == found.fingerprint }) {
                        findResults.append(found)
                    }
                }
            }
            await MainActor.run {
                if !Task.isCancelled { isFinding = false }
            }
        }
    }
    
    private func add(_ found: AltStoreSourceFinder.Found) {
        addingFound.insert(found.url)
        Task {
            _ = await onAdd(found.url.absoluteString)
            addingFound.remove(found.url)
        }
    }
    
    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            let success = await onAdd(trimmed)
            if success {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}

private struct AltStoreSourceSectionView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let isExpanded: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void
    
    /// Apps are added to the list a page at a time as the user scrolls, so a source with
    /// thousands of apps shows all of them without building thousands of rows at once.
    private static let pageSize = 50
    @State private var visibleCount = AltStoreSourceSectionView.pageSize
    
    private func copySourceURL() {
        UIPasteboard.general.string = item.url.absoluteString
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    
    private func showMoreApps() {
        if visibleCount < filteredApps.count {
            visibleCount = min(filteredApps.count, visibleCount + Self.pageSize)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                        SourceIconView(url: item.primaryIconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.source?.name ?? item.displayName)
                            .font(.system(.title2).bold())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Long-press the source's name for its URL.
                .contextMenu {
                    Button("lc.sources.copyUrl".loc, systemImage: "doc.on.doc", action: copySourceURL)
                    Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                    Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                }
                Spacer()
                if item.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button("lc.sources.copyUrl".loc, systemImage: "doc.on.doc", action: copySourceURL)
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                        Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if let error = item.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.sources.section.error".loc)
                        .font(.subheadline)
                        .bold()
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("lc.sources.refresh".loc, action: onRefresh)
                        .font(.footnote)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(uiColor: UIColor.secondarySystemBackground))
                )
            } else if let source = item.source, isExpanded || isFiltering {
                LazyVStack(spacing: 12) {
                    ForEach(filteredApps.prefix(visibleCount)) { app in
                        LCSourceAppBanner(app: app, source: source, installAction: onInstall)
                    }
                    if filteredApps.isEmpty {
                        if source.apps.isEmpty || isFiltering {
                            Text("lc.sources.section.noApps".loc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if visibleCount < filteredApps.count {
                        // Reaching the end of the page brings in the next one.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear(perform: showMoreApps)
                    }
                }
                .onChange(of: filteredApps.count) { _ in
                    visibleCount = Self.pageSize
                }
            } else if item.isLoading {
                ProgressView("lc.sources.loading".loc)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let installAction: (AltStoreSourceApp) -> Void
    
    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    
    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.tintColor ?? source.tintColor ?? Color("FontColor")
    }
    
    private var textColor: Color {
        _ = colorScheme == .dark // trigger refresh
        let color = dynamicColors ? primaryColor : Color("FontColor")
        return color.readableTextColor()
    }
    
    private var backgroundColor: Color {
        dynamicColors ? primaryColor.opacity(0.5) : Color("AppBannerBG")
    }
    
    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        if let build = latest.buildVersion, !build.isEmpty {
            return "\(latest.version) (\(build)) • \(app.bundleIdentifier)"
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }
    
    private var subtitleText: String {
        if let subtitle = app.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let developer = app.developerName, !developer.isEmpty {
            return developer
        }
        return ""
    }
    
    var body: some View {
        HStack {
            HStack(alignment: .center, spacing: 12) {
                SourceIconView(url: app.iconURL)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 16)).bold()
                        if app.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    Text(metadataText)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(false)
            Spacer()
            Button {
                installAction(app)
            } label: {
                Text("lc.common.install".loc)
                    .bold()
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(height: 32)
                    .minimumScaleFactor(0.1)
            }
            .buttonStyle(BasicButtonStyle())
            .padding()
            .frame(idealWidth: 70)
            .frame(height: 32)
            .fixedSize()
            .background(
                Capsule().fill(dynamicColors ? primaryColor : Color("FontColor"))
            )
            .clipShape(Capsule())
        }
        .padding()
        .frame(height: 88)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(backgroundColor)
        }
    }
}

private struct SourceIconView: View {
    let url: URL?
    
    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }
    
    private var placeholder: some View {
        Image("DefaultIcon")
            .resizable()
            .scaledToFill()
    }
}
