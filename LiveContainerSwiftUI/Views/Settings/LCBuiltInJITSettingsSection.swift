//
//  LCBuiltInJITSettingsSection.swift
//  LiveContainerSwiftUI
//
//  Settings for the "Built-in (StikJIT)" JIT enabler. Shown only while it is selected.
//

import SwiftUI
import UniformTypeIdentifiers

struct LCBuiltInJITSettingsSection: View {
    @State private var pairingText = ""
    @State private var prepareStatus = "Not checked"
    @State private var preparing = false
    @State private var importerShown = false
    @State private var alertText = ""
    @State private var alertShown = false

    // StikJIT calls block, and must not overlap
    private static let workQueue = DispatchQueue(label: "com.kdt.livecontainer.builtin-jit.settings")

    var body: some View {
        Section {
            HStack {
                Text("Pairing File")
                Spacer()
                Text(pairingText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Import Pairing File") {
                importerShown = true
            }
            .fileImporter(isPresented: $importerShown, allowedContentTypes: [.item]) { result in
                importPairingFile(result)
            }
            if LCBuiltInJIT.pairingSource == .imported {
                Button("Remove Imported Pairing File", role: .destructive) {
                    LCBuiltInJIT.removeImportedPairingFile()
                    prepareStatus = "Not checked"
                    refreshPairing()
                }
            }
            Button {
                prepare()
            } label: {
                HStack {
                    Text("Prepare JIT")
                    Spacer()
                    if preparing {
                        ProgressView()
                    }
                    Text(prepareStatus)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .disabled(preparing)
            HStack {
                Text("TXM")
                Spacer()
                Text(LCBuiltInJIT.txmDescription)
                    .foregroundStyle(.secondary)
            }
            Button("Reset Developer Disk Image") {
                resetDDI()
            }
            .disabled(preparing)
            NavigationLink("Last JIT Log") {
                LCBuiltInJITLogView()
            }
        } header: {
            Text("Built-in JIT")
        } footer: {
            Text("LiveContainer enables JIT by itself, without StikDebug. LocalDevVPN must be connected. Turn on “Launch with JIT” in an app's settings, or long-press an app and choose Launch with JIT. Apps use StikDebug's universal script unless you pick a script in the app's settings.\n\nThis is a modified build, not an official LiveContainer release.")
        }
        .onAppear {
            refreshPairing()
        }
        .alert("Built-in JIT", isPresented: $alertShown) {
            Button("OK") {}
        } message: {
            Text(alertText)
        }
    }

    private func refreshPairing() {
        switch LCBuiltInJIT.pairingSource {
        case .imported:
            pairingText = "Imported"
        case .sideStore:
            pairingText = "Using SideStore's"
        case .missing:
            pairingText = "Missing"
        }
        if LCBuiltInJIT.pairingFileIsOldFormat {
            pairingText += " (old format)"
        }
    }

    private func importPairingFile(_ result: Result<URL, Error>) {
        do {
            try LCBuiltInJIT.importPairingFile(from: try result.get())
            prepareStatus = "Not checked"
            refreshPairing()
        } catch {
            show(error.localizedDescription)
        }
    }

    private func prepare() {
        preparing = true
        prepareStatus = "Starting"
        Self.workQueue.async {
            let result = LCBuiltInJIT.prepareDevice { stage in
                DispatchQueue.main.async {
                    prepareStatus = stage
                }
            }
            DispatchQueue.main.async {
                preparing = false
                prepareStatus = result.message
            }
        }
    }

    private func resetDDI() {
        Self.workQueue.async {
            var failure: String?
            do {
                try LCBuiltInJIT.resetCachedDDI()
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                prepareStatus = "Not checked"
                show(failure ?? "The cached Developer Disk Image was removed. It is downloaded again the next time it is needed.")
            }
        }
    }

    private func show(_ text: String) {
        alertText = text
        alertShown = true
    }
}

struct LCBuiltInJITLogView: View {
    @State private var log = ""

    var body: some View {
        ScrollView {
            Text(log.isEmpty ? "No JIT launch has been logged yet." : log)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Last JIT Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Copy") {
                UIPasteboard.general.string = log
            }
            .disabled(log.isEmpty)
        }
        .onAppear {
            log = LCBuiltInJIT.lastLog
        }
    }
}
