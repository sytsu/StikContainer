//
//  LCBuiltInJIT.swift
//  LiveContainerSwiftUI
//
//  Built-in JIT: LiveContainer enables JIT itself with StikJIT, without StikDebug.
//
//  StikJIT must run in a different process from the one that gets JIT, so the actual
//  work happens in a LiveProcess helper (LiveProcess/main.m calls `runHelper`).
//  The helper is started by LCSharedUtils.startBuiltInJIT. Everything else in this
//  file runs in LiveContainer itself.
//

import Foundation
import StikJIT

struct LCBuiltInJITError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@objc(LCBuiltInJIT) public final class LCBuiltInJIT: NSObject {

    // MARK: - LiveContainer side

    /// Whether "Built-in (StikJIT)" is the selected JIT enabler.
    static var isSelected: Bool {
        JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) == .BuiltIn
    }

    /// Asks LCBootstrap.m to enable JIT on the launch into a guest app that is about to happen.
    static func requestForNextLaunch(scriptBase64: String?) {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: "LCBuiltInJITPendingDate")
        if let scriptBase64, !scriptBase64.isEmpty {
            defaults.set(scriptBase64, forKey: "LCBuiltInJITScript")
        } else {
            defaults.removeObject(forKey: "LCBuiltInJITScript")
        }
    }

    enum PairingSource {
        case imported
        case sideStore
        case missing
    }

    static var pairingSource: PairingSource {
        guard let path = LCSharedUtils.builtInJITPairingFilePath() else { return .missing }
        return path == LCSharedUtils.builtInJITImportedPairingFilePath() ? .imported : .sideStore
    }

    /// True for a classic lockdown pairing record, which StikJIT cannot use.
    static var pairingFileIsOldFormat: Bool {
        guard let path = LCSharedUtils.builtInJITPairingFilePath(),
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return plist["HostCertificate"] != nil || plist["HostPrivateKey"] != nil
    }

    static func importPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw LCBuiltInJITError(message: "The selected file is empty.") }
        let destination = URL(fileURLWithPath: LCSharedUtils.builtInJITImportedPairingFilePath())
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    static func removeImportedPairingFile() {
        try? FileManager.default.removeItem(atPath: LCSharedUtils.builtInJITImportedPairingFilePath())
    }

    static var txmDescription: String {
        guard #available(iOS 17.4, *) else { return "Unknown" }
        switch StikJIT.isTXMPresent {
        case .some(true): return "Present"
        case .some(false): return "Not Present"
        case .none: return "Unknown"
        }
    }

    static var lastLog: String {
        (try? String(contentsOfFile: LCSharedUtils.builtInJITLogPath(), encoding: .utf8)) ?? ""
    }

    private static var sharedDDIPaths: DDIPaths {
        DDIPaths.default(in: URL(fileURLWithPath: LCSharedUtils.builtInJITWorkDirectory(), isDirectory: true))
    }

    /// Checks the LocalDevVPN connection and mounts the Developer Disk Image, downloading it first
    /// if needed. Blocks until done, so call it off the main thread.
    static func prepareDevice(progress: @escaping (String) -> Void) -> (ready: Bool, message: String) {
        guard #available(iOS 17.4, *) else { return (false, "Needs iOS 17.4 or later") }
        guard let path = LCSharedUtils.builtInJITPairingFilePath() else { return (false, "No pairing file") }
        let readiness = StikJIT.prepareDevice(pairingFile: URL(fileURLWithPath: path), paths: sharedDDIPaths) { stage in
            progress(describe(stage))
        }
        switch readiness {
        case .ready:
            return (true, "Ready")
        case .unreachable(let reason):
            return (false, "Unreachable: \(reason)")
        case .preparationFailed(let reason):
            return (false, "Not ready: \(reason)")
        @unknown default:
            return (false, "Not ready")
        }
    }

    static func resetCachedDDI() throws {
        guard #available(iOS 17.4, *) else { return }
        try StikJIT.resetCachedDDI(at: sharedDDIPaths)
    }

    private static func describe(_ stage: StikJIT.PreparationStage) -> String {
        switch stage {
        case .checkingReachability:
            return "Checking the connection"
        case .checkingDDI:
            return "Checking the Developer Disk Image"
        case .downloadingDDI(let fraction, _):
            return "Downloading the Developer Disk Image \(Int(fraction * 10) * 10)%"
        case .mountingDDI(let fraction):
            return "Mounting the Developer Disk Image \(Int(fraction * 10) * 10)%"
        case .verifyingDDI:
            return "Verifying the Developer Disk Image"
        case .ready:
            return "Device ready"
        @unknown default:
            return "Working"
        }
    }

    // MARK: - Helper side (runs inside LiveProcess)

    /// Enables JIT for the process named in `request`. Blocks until the JIT script detaches,
    /// which with a script-based app is when the app has finished setting up its JIT memory.
    /// Returns nil on success, or the reason it failed.
    @objc(runHelperWithRequest:) public static func runHelper(request: NSDictionary) -> String? {
        guard #available(iOS 17.4, *) else { return "Built-in JIT needs iOS 17.4 or later." }
        guard let pid = (request["pid"] as? NSNumber)?.int32Value,
              let pairingData = request["pairingData"] as? Data else {
            return "The JIT helper request is incomplete."
        }

        let fileManager = FileManager.default
        // Prefer the directory shared with LiveContainer so the disk image is downloaded once.
        var workDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        if let shared = request["sharedDirectory"] as? String, fileManager.isWritableFile(atPath: shared) {
            workDirectory = URL(fileURLWithPath: shared, isDirectory: true)
        }
        try? fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let log = HelperLog(url: workDirectory.appendingPathComponent("last-jit.log"))

        // The helper cannot read LiveContainer's container, so the pairing file arrives as data.
        let pairingFile = fileManager.temporaryDirectory.appendingPathComponent("lc-jit-\(UUID().uuidString).plist")
        do {
            try pairingData.write(to: pairingFile, options: .atomic)
        } catch {
            return "Could not store the pairing file for the helper: \(error.localizedDescription)"
        }
        defer { try? fileManager.removeItem(at: pairingFile) }

        var script = StikJIT.Script.universal
        if let custom = request["script"] as? String, !custom.isEmpty {
            script = .customBase64(custom)
        }

        // StikJIT refuses to guess when it cannot tell whether TXM is present. The helper's
        // sandbox may hide that, and on iOS 26+ running the script is the safe choice.
        let txm = StikJIT.isTXMPresent
        let forceScript = txm == nil && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        let txmText = txm.map { $0 ? "present" : "not present" } ?? "unknown"
        log.write("target pid \(pid), TXM \(txmText), force script \(forceScript)")

        var lastStage = ""
        do {
            try StikJIT.enableJIT(
                targetPID: pid,
                pairingFile: pairingFile,
                ddiPaths: DDIPaths.default(in: workDirectory),
                script: script,
                forceScript: forceScript,
                preparationProgress: { stage in
                    // download progress reports many times per second
                    let text = describe(stage)
                    if text != lastStage {
                        lastStage = text
                        log.write(text)
                    }
                },
                progress: { log.write($0) }
            )
            log.write("done")
            return nil
        } catch {
            log.write("failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}

/// Appends to the same log file LiveContainer writes to, so one file tells the whole story.
private final class HelperLog {
    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(url: URL) {
        self.url = url
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [helper \(getpid())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
