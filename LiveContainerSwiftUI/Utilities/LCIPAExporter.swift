//
//  LCIPAExporter.swift
//  LiveContainerSwiftUI
//
//  Exports an installed app as an .ipa that can be signed and installed again, here or with
//  another installer: LiveContainer's own files are left out, the original bundle ID is put
//  back, and the executables LiveContainer patched to load as dylibs are executables again.
//

import Foundation

struct LCIPAExportSource {
    let bundlePath: String
    // The app's real bundle ID (LCAppInfo.bundleIdentifier, which "Use LC Bundle ID" doesn't change).
    let bundleIdentifier: String?
    let displayName: String
    let version: String?

    init(appInfo: LCAppInfo) {
        bundlePath = appInfo.bundlePath() ?? ""
        bundleIdentifier = appInfo.bundleIdentifier()
        displayName = appInfo.displayName() ?? ""
        version = appInfo.version()
    }
}

enum LCIPAExporter {
    // Builds the .ipa in `directory` and returns it. Runs for a while with a big app, so call it
    // off the main thread; cancelling `progress` stops it.
    static func export(_ source: LCIPAExportSource, to directory: URL, progress: Progress) throws -> URL {
        let fm = FileManager.default
        let bundleURL = URL(fileURLWithPath: source.bundlePath)
        guard !source.bundlePath.isEmpty,
              let infoPlist = NSMutableDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }
        let executable = infoPlist["CFBundleExecutable"] as? String ?? bundleURL.deletingPathExtension().lastPathComponent

        let staging = directory.appendingPathComponent("Staging", isDirectory: true)
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: staging)
        }

        // A clone of the bundle: instant, and it takes no space until a file in it changes.
        let appURL = payload.appendingPathComponent("\(executable).app", isDirectory: true)
        try fm.copyItem(at: bundleURL, to: appURL)

        // LiveContainer's own files.
        removeIfPresent(appURL.appendingPathComponent("LCAppInfo.plist"))
        removeIfPresent(appURL.appendingPathComponent("\(executable)_LiveContainerPatchBackUp"))

        // "Use LC Bundle ID" puts LiveContainer's bundle ID in Info.plist.
        if let bundleIdentifier = source.bundleIdentifier, bundleIdentifier != "Unknown",
           infoPlist["CFBundleIdentifier"] as? String != bundleIdentifier {
            infoPlist["CFBundleIdentifier"] = bundleIdentifier
            let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .binary, options: 0)
            try data.write(to: appURL.appendingPathComponent("Info.plist"), options: .atomic)
        }

        if let error = LCUnpatchExecutable(appURL.appendingPathComponent(executable).path) {
            throw error
        }

        // App extensions are patched the same way.
        let plugIns = appURL.appendingPathComponent("PlugIns", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: plugIns.path)) ?? [] where name.hasSuffix(".appex") {
            let appex = plugIns.appendingPathComponent(name, isDirectory: true)
            removeIfPresent(appex.appendingPathComponent("LCAppExtension.plist"))
            guard let appexInfo = NSDictionary(contentsOf: appex.appendingPathComponent("Info.plist")),
                  let appexExecutable = appexInfo["CFBundleExecutable"] as? String else {
                continue
            }
            removeIfPresent(appex.appendingPathComponent("\(appexExecutable).lcpatch"))
            let appexExecutablePath = appex.appendingPathComponent(appexExecutable).path
            if fm.fileExists(atPath: appexExecutablePath), let error = LCUnpatchExecutable(appexExecutablePath) {
                throw error
            }
        }

        var name = source.displayName.isEmpty ? executable : source.displayName
        if let version = source.version, version != "Unknown", !version.isEmpty {
            name += " \(version)"
        }
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let ipaURL = directory.appendingPathComponent("\(name).ipa")
        if let error = LCWriteZipArchive(staging.path, ipaURL.path, progress) {
            throw error
        }
        return ipaURL
    }

    private static func removeIfPresent(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
