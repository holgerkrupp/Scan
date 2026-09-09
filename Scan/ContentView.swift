import AppKit
import SwiftUI

struct ContentView: View {
    @State private var viewModel = ScannerWorkspaceViewModel.shared
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            HStack(spacing: 0) {
                preview
                Divider()
                inspector
            }
        }
        .task { await viewModel.refreshDevices() }
        .frame(minWidth: 1180, minHeight: 760)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Scanners", systemImage: "scanner").font(.headline); Spacer(); Button { Task { await viewModel.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }.disabled(viewModel.isRefreshing) }
            Text("Legacy ScanSnap USB (S300 experimental) plus Image Capture").font(.caption).foregroundStyle(.secondary)
            List(selection: Binding(get: { viewModel.selectedIdentity }, set: { viewModel.selectedIdentity = $0 })) {
                ForEach(viewModel.discoveredIdentities) { identity in
                    let capabilities = viewModel.capabilities(for: identity)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(identity.name).font(.subheadline.weight(.medium))
                            Spacer()
                            if capabilities == nil { Image(systemName: "questionmark.circle").foregroundStyle(.orange) }
                            else if capabilities?.unsupportedReason != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow) }
                        }
                        Text(capabilities?.unsupportedReason ?? (capabilities == nil ? "Discovered, unsupported" : identity.subtitle))
                            .font(.caption)
                            .foregroundStyle(capabilities == nil ? .orange : .secondary)
                    }.tag(identity)
                }
            }.listStyle(.sidebar)
        }.padding().navigationSplitViewColumnWidth(min: 270, ideal: 300)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Pages").font(.title2.weight(.semibold)); Spacer(); Text("\(viewModel.pages.count) page\(viewModel.pages.count == 1 ? "" : "s")").foregroundStyle(.secondary) }
            if viewModel.pages.isEmpty {
                ContentUnavailableView("No pages yet", systemImage: "doc.viewfinder", description: Text("Scan a document to review pages before exporting."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], spacing: 14) {
                        ForEach(viewModel.pages) { page in
                            PageThumbnail(page: page, selected: page.id == viewModel.selectedPageID)
                                .onTapGesture { viewModel.selectedPageID = page.id }
                                .contextMenu { Button("Rotate 90°") { Task { viewModel.selectedPageID = page.id; await viewModel.rotateSelectedPage() } }; Button("Delete", role: .destructive) { Task { viewModel.selectedPageID = page.id; await viewModel.deleteSelectedPage() } } }
                        }
                    }.padding(.vertical, 4)
                }
            }
            HStack {
                Button { Task { await viewModel.rotateSelectedPage() } } label: { Label("Rotate", systemImage: "rotate.right") }.disabled(viewModel.selectedPageID == nil)
                Button(role: .destructive) { Task { await viewModel.deleteSelectedPage() } } label: { Label("Delete", systemImage: "trash") }.disabled(viewModel.selectedPageID == nil)
                Spacer()
                Button { Task { await viewModel.clearPages() } } label: { Label("Clear", systemImage: "xmark.circle") }.disabled(viewModel.pages.isEmpty && viewModel.lastOutputs.isEmpty)
            }
            Divider()
            HStack(spacing: 10) {
                if viewModel.isScanning { Button(role: .cancel) { Task { await viewModel.cancelScan() } } label: { Label("Cancel", systemImage: "xmark.circle") } }
                else {
                    Button { Task { await viewModel.startScan() } } label: {
                        Label("Scan", systemImage: "scanner")
                            .font(.title3.weight(.semibold))
                            .frame(minWidth: 150, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(viewModel.selectedIdentity == nil)
                }
                Button { Task { await viewModel.saveExport() } } label: { Label("Save/Export", systemImage: "square.and.arrow.down") }.disabled(viewModel.pages.isEmpty || viewModel.isScanning)
                Button { viewModel.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }.disabled(viewModel.lastOutputs.isEmpty)
                Spacer()
                statusView
            }
        }.padding(22).frame(minWidth: 560)
    }

    private var statusView: some View {
        HStack(spacing: 8) {
            switch viewModel.status { case let .scanning(progress, _): if let progress { ProgressView(value: progress).frame(width: 130) } else { ProgressView().controlSize(.small) }; default: EmptyView() }
            Text(viewModel.status.displayText).font(.caption).foregroundStyle(statusColor).lineLimit(1)
        }
    }

    private var inspector: some View {
        ScrollView { Form {
            Section("Profile") { Picker("Profile", selection: Binding(get: { viewModel.selectedProfile.id }, set: { id in viewModel.selectProfile(id: id) })) { ForEach(viewModel.profiles) { Text($0.name).tag($0.id) } }; TextField("Profile name", text: profileString(\.name)); Button("Duplicate profile") { viewModel.duplicateSelectedProfile() } }
            Section("Source") {
                Picker("Source", selection: profile(\.options.acquisition.source)) { ForEach(ScanSource.allCases) { Text($0.rawValue).tag($0).disabled(!viewModel.isSupported($0)) } }.pickerStyle(.menu)
                Picker("Color mode", selection: profile(\.options.acquisition.colorMode)) { ForEach(ScanColorMode.allCases) { Text($0.rawValue).tag($0).disabled(!viewModel.isSupported($0)) } }
                Picker("DPI", selection: profile(\.options.acquisition.resolutionDPI)) { ForEach([75, 100, 150, 200, 300, 400, 600], id: \.self) { Text("\($0) dpi").tag($0).disabled(!viewModel.isSupported($0)) } }
                if let capabilities = viewModel.capabilities { Text("Supported: \(capabilities.resolutions(for: viewModel.selectedProfile.options.source).map(String.init).joined(separator: ", ")) dpi").font(.caption).foregroundStyle(.secondary) }
                else if viewModel.selectedIdentity?.connectionKind == .imageCapture { Text("Device capabilities are read when the Image Capture session opens.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Image") {
                Picker("Output", selection: profile(\.options.export.outputFormat)) { ForEach(ScanOutputFormat.allCases) { Text($0.rawValue).tag($0).disabled(!viewModel.isSupported($0)) } }
                Picker("File size", selection: profile(\.options.export.sizePreset)) { ForEach(ScanFileSizePreset.allCases) { Text($0.rawValue).tag($0) } }.onChange(of: viewModel.selectedProfile.options.export.sizePreset) { _, preset in var p = viewModel.selectedProfile; p.options.applyPreset(preset); viewModel.updateProfile(p) }
                if viewModel.selectedProfile.options.export.sizePreset == .custom { Slider(value: profile(\.options.export.jpegQuality), in: 0.4...1.0) { Text("JPEG quality") }; Stepper("Output DPI \(viewModel.selectedProfile.options.export.outputDPI)", value: profile(\.options.export.outputDPI), in: 75...1200, step: 25) }
                Picker("Export", selection: profile(\.options.export.exportMode)) { ForEach(ScanExportMode.allCases) { Text($0.rawValue).tag($0) } }.disabled(viewModel.selectedProfile.options.export.outputFormat != .pdf && viewModel.selectedProfile.options.export.outputFormat != .searchablePDF)
                if viewModel.selectedProfile.options.export.outputFormat == .searchablePDF {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OCR languages")
                        ForEach(["en-US", "de-DE", "fr-FR", "es-ES"], id: \.self) { language in
                            Toggle(language, isOn: Binding(get: { viewModel.selectedProfile.options.export.ocrLanguages.contains(language) }, set: { enabled in var p = viewModel.selectedProfile; if enabled { if !p.options.export.ocrLanguages.contains(language) { p.options.export.ocrLanguages.append(language) } } else { p.options.export.ocrLanguages.removeAll { $0 == language } }; viewModel.updateProfile(p) }))
                        }
                    }
                }
                TextField("Filename template", text: profileString(\.options.export.filenameTemplate)); Text("Tokens: {date}, {time}, {page}, {side}").font(.caption).foregroundStyle(.secondary)
                Toggle("Automatically save after scanning", isOn: profile(\.options.export.automaticallySaveAfterScanning))
            }
            Section("Processing") {
                capabilityToggle("Remove blank pages", value: profile(\.options.processing.removeBlankPages), supported: viewModel.capabilities?.supportsBlankPageRemoval ?? false, reason: "The selected backend does not expose blank-page processing.")
                capabilityToggle("Auto-crop", value: profile(\.options.processing.autoCrop), supported: viewModel.capabilities?.supportsAutoCrop ?? false, reason: "Software crop is unavailable for this backend.")
                capabilityToggle("Deskew", value: profile(\.options.processing.deskew), supported: viewModel.capabilities?.supportsDeskew ?? false, reason: "Software deskew is unavailable for this backend.")
                capabilityToggle("Automatic orientation", value: profile(\.options.processing.autoRotate), supported: viewModel.capabilities?.supportsAutoRotate ?? false, reason: "Automatic orientation is unavailable for this backend.")
            }
            Section("Diagnostics") {
                if viewModel.selectedScannerUsesS300Protocol {
                    VStack(alignment: .leading, spacing: 5) {
                        Button("Choose S300 firmware…") { viewModel.chooseS300Firmware() }
                        Text(viewModel.s300FirmwareFilename.map { "S300 firmware: \($0)" } ?? "S300 firmware is not selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Activity log", isExpanded: $viewModel.diagnosticsExpanded) { Button("Copy log") { viewModel.copyActivityLog() }; ScrollView { Text(viewModel.activityLog.reversed().joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 100, maxHeight: 220) }
                if !viewModel.lastOutputs.isEmpty { Text("Last export: \(ByteCountFormatter.string(fromByteCount: viewModel.lastOutputByteCount, countStyle: .file))").font(.caption) }
            }
        }.formStyle(.grouped).padding(.horizontal, 8) }.frame(width: 370)
    }

    private func profile<T>(_ keyPath: WritableKeyPath<ScanProfile, T>) -> Binding<T> { Binding(get: { viewModel.selectedProfile[keyPath: keyPath] }, set: { var p = viewModel.selectedProfile; p[keyPath: keyPath] = $0; viewModel.updateProfile(p) }) }
    private func profileString(_ keyPath: WritableKeyPath<ScanProfile, String>) -> Binding<String> { profile(keyPath) }
    private func capabilityToggle(_ title: String, value: Binding<Bool>, supported: Bool, reason: String) -> some View { Toggle(title, isOn: value).disabled(!supported).help(supported ? "" : reason) }
    private var statusColor: Color { switch viewModel.status { case .error: .red; case .scanning: .accentColor; case .idle: .green; case .disconnected: .secondary } }
}

private struct PageThumbnail: View {
    let page: StoredPage; let selected: Bool
    var body: some View { VStack(alignment: .leading, spacing: 6) { if let image = NSImage(contentsOf: page.fileURL) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, minHeight: 150, maxHeight: 250).background(.white) } else { Image(systemName: "photo").frame(maxWidth: .infinity, minHeight: 190) }; Text("Page \(page.pageIndex) · \(page.side.rawValue)").font(.caption).foregroundStyle(.secondary) }.padding(6).background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2)).clipShape(RoundedRectangle(cornerRadius: 8)) }
}

#Preview { ContentView() }
