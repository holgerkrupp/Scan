import AppKit
import SwiftUI

struct ContentView: View {
    @State private var viewModel = ScannerWorkspaceViewModel.shared
    /// Thumbnail width chosen with the slider next to "Reveal in Finder".
    @AppStorage("scan.thumbnailSize") private var thumbnailSize = 170.0
    @State private var gridWidth = 0.0
    @FocusState private var pagesFocused: Bool
    private let gridSpacing = 14.0
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
        // Must fit the widest sidebar (380) plus preview (420) and inspector (370); otherwise the split view overflows and is centred, clipping the sidebar.
        .frame(minWidth: 1180, minHeight: 760)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Scanners", systemImage: "scanner").font(.headline); Spacer(); Button { Task { await viewModel.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }.disabled(viewModel.isRefreshing) }
            Text("Legacy ScanSnap and fi-series USB (S300 experimental) plus Image Capture").font(.caption).foregroundStyle(.secondary)
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
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Pages").font(.title2.weight(.semibold))
                Spacer()
                if viewModel.pendingProcessingCount > 0 { ProgressView().controlSize(.small); Text("Processing \(viewModel.pendingProcessingCount)…").foregroundStyle(.secondary) }
                Text("\(viewModel.pages.count) page\(viewModel.pages.count == 1 ? "" : "s")\(viewModel.hiddenBlankPageCount > 0 ? " · \(viewModel.hiddenBlankPageCount) blank hidden" : "")").foregroundStyle(.secondary)
            }
            if viewModel.pages.isEmpty {
                if viewModel.pendingProcessingCount > 0 {
                    ContentUnavailableView("Processing pages…", systemImage: "doc.viewfinder")
                } else if viewModel.hiddenBlankPageCount > 0 {
                    ContentUnavailableView("Only blank pages", systemImage: "doc", description: Text("Every scanned page was found blank. Turn off blank-page removal to see them."))
                } else {
                    ContentUnavailableView("No pages yet", systemImage: "doc.viewfinder", description: Text("Scan a document to review pages before exporting."))
                }
            } else {
                pageGrid
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
                thumbnailSizeSlider
                Spacer()
                statusView
            }
        }.padding(22).frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
    }

    private var thumbnailSizeSlider: some View {
        Slider(value: $thumbnailSize, in: 110...360) {
            Text("Thumbnail size")
        } minimumValueLabel: {
            Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 170)
        .help("Thumbnail size")
        .accessibilityLabel("Thumbnail size")
    }

    /// Focuses the page area after a click. Writing `true` into the focus
    /// state while it is already focused makes SwiftUI resign and re-acquire
    /// focus, which flashes the focus ring, so the write is skipped then.
    private func focusPages() {
        if !pagesFocused { pagesFocused = true }
    }

    /// The columns the adaptive grid currently shows, needed for up/down navigation.
    private var gridColumns: Int {
        PageGridNavigation.columnCount(forWidth: gridWidth, minimumItemWidth: thumbnailSize, spacing: gridSpacing)
    }

    /// The page grid is a focusable area like the Finder's icon view: Tab
    /// reaches it when keyboard navigation is on, clicking a page focuses it,
    /// the arrow keys, Home and End move the selection, Space toggles the
    /// Quick Look panel (which previews the selection and forwards these keys
    /// back here while open), and a click on empty space clears the selection.
    private var pageGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.5), spacing: gridSpacing)], spacing: gridSpacing) {
                    ForEach(viewModel.pages) { page in
                        PageThumbnail(page: page, selected: page.id == viewModel.selectedPageID, size: thumbnailSize)
                            .id(page.id)
                            .onTapGesture { viewModel.selectedPageID = page.id; focusPages() }
                            .contextMenu {
                                Button("Quick Look") { viewModel.selectedPageID = page.id; viewModel.toggleQuickLook() }
                                Button("Rotate 90°") { Task { viewModel.selectedPageID = page.id; await viewModel.rotateSelectedPage() } }
                                Button("Delete", role: .destructive) { Task { viewModel.selectedPageID = page.id; await viewModel.deleteSelectedPage() } }
                            }
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { gridWidth = $0 }
                // Empty space below the last row also belongs to the area.
                .frame(maxWidth: .infinity, minHeight: 0, alignment: .top)
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.selectedPageID = nil; focusPages() }
            .focusable()
            .focused($pagesFocused)
            // Arrow keys are taken with onKeyPress rather than onMoveCommand:
            // the scroll view would otherwise consume them for scrolling.
            .onKeyPress(.leftArrow) { viewModel.selectPage(moving: .left, columns: gridColumns); return .handled }
            .onKeyPress(.rightArrow) { viewModel.selectPage(moving: .right, columns: gridColumns); return .handled }
            .onKeyPress(.upArrow) { viewModel.selectPage(moving: .up, columns: gridColumns); return .handled }
            .onKeyPress(.downArrow) { viewModel.selectPage(moving: .down, columns: gridColumns); return .handled }
            .onKeyPress(.home) { viewModel.selectPage(moving: .first, columns: gridColumns); return .handled }
            .onKeyPress(.end) { viewModel.selectPage(moving: .last, columns: gridColumns); return .handled }
            .onKeyPress(.space) { viewModel.toggleQuickLook(); return .handled }
            .onChange(of: viewModel.selectedPageID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .onChange(of: gridColumns, initial: true) { _, columns in viewModel.gridColumns = columns }
        }
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
                capabilityToggle("Scanner buffering", value: profile(\.options.acquisition.scannerBuffering), supported: viewModel.capabilities?.supportsScannerBuffering ?? false, reason: "This scanner does not expose ADF read-ahead buffering.")
                capabilityToggle("Hardware JPEG compression", value: profile(\.options.acquisition.hardwareCompression), supported: viewModel.capabilities?.supportsHardwareCompression ?? false, reason: "This scanner cannot compress pages itself.")
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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Whiten paper", isOn: profile(\.options.processing.whitenPaper))
                    Text("Measures each page's paper tone and stretches it to white, as ScanSnap Home does; black stays black.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("Paper cleanup") {
                        Text(paperCleanupLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: profile(\.options.processing.paperCleanup), in: 0...1, step: 0.05) {
                        Text("Paper cleanup")
                    } minimumValueLabel: {
                        Text("Off")
                    } maximumValueLabel: {
                        Text("Strong")
                    }
                    Text("Increase to suppress faint shadows from creases and paper texture; reduce it to retain light pencil marks and subtle details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                capabilityToggle("Remove blank pages", value: profile(\.options.processing.removeBlankPages), supported: viewModel.capabilities?.supportsBlankPageRemoval ?? false, reason: "The selected backend does not expose blank-page processing.")
                VStack(alignment: .leading, spacing: 4) {
                    capabilityToggle("Deskew and crop to page", value: profile(\.options.processing.deskew), supported: viewModel.capabilities?.supportsDeskew ?? false, reason: "Software deskew is unavailable for this backend.")
                    Text("Straightens skewed sheets and crops away the paper edges, like ScanSnap Home. Also available as Edit > Auto-Align Page.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    capabilityToggle("Crop to content", value: profile(\.options.processing.autoCrop), supported: viewModel.capabilities?.supportsAutoCrop ?? false, reason: "Software crop is unavailable for this backend.")
                    Text("Trims the paper margins down to the printed content, for receipts and clippings.").font(.caption).foregroundStyle(.secondary)
                }
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
    private var paperCleanupLabel: String {
        let amount = viewModel.selectedProfile.options.processing.paperCleanup
        return amount == 0 ? "Off" : "\(Int((amount * 100).rounded()))%"
    }
    private var statusColor: Color { switch viewModel.status { case .error: .red; case .scanning: .accentColor; case .idle: .green; case .disconnected: .secondary } }
}

private struct PageThumbnail: View {
    let page: StoredPage
    let selected: Bool
    /// Minimum width of the grid cell; the image height follows it.
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(contentsOf: page.fileURL) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: size, maxHeight: size * 1.6)
                    .background(.white)
            } else {
                Image(systemName: "photo").frame(maxWidth: .infinity, minHeight: size * 1.25)
            }
            Text("Page \(page.pageIndex) · \(page.side.rawValue)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview { ContentView() }
