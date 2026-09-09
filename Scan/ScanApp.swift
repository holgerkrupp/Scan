//
//  ScanApp.swift
//  Scan
//
//  Created by Holger Krupp on 05.06.26.
//

import SwiftUI

@main
struct ScanApp: App {
    private let workspace = ScannerWorkspaceViewModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandMenu("Scan") {
                if workspace.isScanning {
                    Button("Cancel Scan") {
                        Task { await workspace.cancelScan() }
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button("Scan Document") {
                        Task { await workspace.startScan() }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(workspace.selectedIdentity == nil)
                }

                Button("Export Pages") {
                    Task { await workspace.saveExport() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace.pages.isEmpty || workspace.isScanning)

                Divider()

                Button("Refresh Scanners") {
                    Task { await workspace.refreshDevices() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace.isRefreshing)

                Button("Reveal Last Export in Finder") {
                    workspace.revealInFinder()
                }
                .disabled(workspace.lastOutputs.isEmpty)
            }

            // Scan has no document model, printing, import/export, or undo
            // support. Its file actions live in the focused Scan menu above.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .importExport) { }
            CommandGroup(replacing: .printItem) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .toolbar) { }
            CommandGroup(replacing: .help) { }
        }
    }
}
