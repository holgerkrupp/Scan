//
//  ScanApp.swift
//  Scan
//
//  Created by Holger Krupp on 05.06.26.
//

import AppKit
import SwiftUI

@main
struct ScanApp: App {
    @NSApplicationDelegateAdaptor(ScanAppDelegate.self) private var appDelegate
    private let workspace = ScannerWorkspaceViewModel.shared

    init() {
        PageQuickLookController.shared.workspace = workspace
    }

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

                Button("Quick Look Selected Page") {
                    workspace.toggleQuickLook()
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(workspace.selectedPageID == nil)

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

                Button("Clear Scanned Pages") {
                    Task { await workspace.clearPages() }
                }
                .disabled(workspace.pages.isEmpty && workspace.lastOutputs.isEmpty)

                Divider()

                Button("Choose Default Saving Location…") {
                    workspace.chooseDestination()
                }

                Button("Show Default Saving Location in Finder") {
                    workspace.openDestinationFolder()
                }
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Auto-Align Page") {
                    Task { await workspace.alignSelectedPage() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(workspace.selectedPageID == nil || workspace.isScanning)
                Button("Rotate Page 90°") {
                    Task { await workspace.rotateSelectedPage() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(workspace.selectedPageID == nil || workspace.isScanning)
            }

            // Scan has no document model, printing, import/export, or undo
            // support. Its file actions live in the focused Scan menu above.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .importExport) { }
            CommandGroup(replacing: .printItem) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .toolbar) { }
            CommandGroup(replacing: .help) {
                Button("Scan Source Code on GitHub") {
                    NSWorkspace.shared.open(ScanProjectLinks.sourceCode)
                }

                Button("Report an Issue…") {
                    NSWorkspace.shared.open(ScanProjectLinks.issueReporter)
                }
            }
        }

        Settings {
            ScanSettingsView(viewModel: workspace)
        }
    }
}
