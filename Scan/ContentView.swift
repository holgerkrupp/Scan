import AppKit
import SwiftUI

struct ContentView: View {
    @State private var viewModel = ScannerWorkspaceViewModel.shared
    @State private var showingDocumentation = false
    @State private var showingActivityLog = false
    @AppStorage("scan.showsSettingsPanel") private var showsSettingsPanel = true
    /// Scanner whose details sheet is open; set by double-clicking it in the sidebar.
    @State private var scannerDetails: ScannerDetails?
    /// Thumbnail width chosen with the slider next to "Reveal in Finder".
    @AppStorage("scan.thumbnailSize") private var thumbnailSize = 170.0
    @State private var gridWidth = 0.0
    @FocusState private var pagesFocused: Bool
    private let gridSpacing = 14.0
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            preview
                .safeAreaBar(edge: .bottom) { statusBar }
                .navigationSubtitle(viewModel.aiFilenameSubtitle ?? "")
                .toolbar { toolbar }
        }
        // On the split view rather than its detail, so the inspector runs the full window height.
        .inspector(isPresented: $showsSettingsPanel) {
            inspector
                .inspectorColumnWidth(min: 320, ideal: 370, max: 460)
                // SwiftUI keeps this item at the far right even while the inspector is closed.
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsSettingsPanel.toggle() } label: { Label("Settings", systemImage: "sidebar.right") }
                            .help("Show or hide the settings panel")
                    }
                }
        }
        .task { await viewModel.refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .scanShowDocumentation)) { _ in
            showingDocumentation = true
        }
        .sheet(isPresented: $showingDocumentation) {
            ScanDocumentationView()
        }
        .sheet(isPresented: $showingActivityLog) {
            ActivityLogView(viewModel: viewModel)
        }
        .sheet(item: $scannerDetails) { details in
            ScannerDetailsView(details: details)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await viewModel.rotateSelectedPage() } } label: { Label("Rotate", systemImage: "rotate.right") }
                .disabled(viewModel.selectedPageID == nil)
                .help("Rotate the selected page")
            Button(role: .destructive) { Task { await viewModel.deleteSelectedPage() } } label: { Label("Delete", systemImage: "trash") }
                .disabled(viewModel.selectedPageID == nil)
                .help("Delete the selected page")
            Button { Task { await viewModel.clearPages() } } label: { Label("Clear", systemImage: "xmark.circle") }
                .disabled(viewModel.pages.isEmpty && viewModel.lastOutputs.isEmpty)
                .help("Remove all pages")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { viewModel.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                .disabled(viewModel.lastOutputs.isEmpty)
                .help("Reveal in Finder")
            Button { Task { await viewModel.saveExport() } } label: { Label("Save/Export", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
                .disabled(viewModel.pages.isEmpty || viewModel.isScanning || viewModel.isSavingShownPages)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            if viewModel.isScanning {
                Button(role: .cancel) { Task { await viewModel.cancelScan() } } label: { Label("Cancel", systemImage: "xmark.circle").labelStyle(.titleAndIcon) }
            } else {
                let scanButton = Button { Task { await viewModel.startScan() } } label: { Label { Text("Scan") } icon: { Image("ScannerSheetFed").resizable().scaledToFit().frame(width: 17, height: 17) }.labelStyle(.titleAndIcon) }
                // Prominent only when it can be used: a disabled prominent button renders washed out.
                if viewModel.selectedIdentity == nil {
                    scanButton.buttonStyle(.glass).disabled(true)
                } else {
                    scanButton.buttonStyle(.glassProminent)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label { Text("Scanners") } icon: { Image("ScannerSheetFed").resizable().scaledToFit().frame(width: 18, height: 18) }.font(.headline)
                Spacer()
                Button { showingDocumentation = true } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .help("Scan Help")
                Button { Task { await viewModel.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(viewModel.isRefreshing)
                    .help("Refresh scanners")
            }
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
            }
            .listStyle(.sidebar)
            // A double-click (the list's primary action) opens the scanner's details.
            .contextMenu(forSelectionType: ScannerIdentity.self) { identities in
                if let identity = identities.first {
                    Button("Show Details…") { scannerDetails = viewModel.details(for: identity) }
                }
            } primaryAction: { identities in
                if let identity = identities.first { scannerDetails = viewModel.details(for: identity) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
    }

    private var preview: some View {
        Group {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One line at the bottom of the pages: what the app is doing at the
    /// left, the page count and the thumbnail size at the right.
    private var statusBar: some View {
        HStack(spacing: 12) {
            ActivityStatus(content: activity).layoutPriority(-1)
            Spacer(minLength: 8)
            Text("\(viewModel.pages.count) page\(viewModel.pages.count == 1 ? "" : "s")\(viewModel.hiddenBlankPageCount > 0 ? " · \(viewModel.hiddenBlankPageCount) blank hidden" : "")").foregroundStyle(.secondary).lineLimit(1)
            thumbnailSizeSlider
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    /// The one place that says what the app is doing, from the scan to the
    /// saved file. During an export it shows the same step, detail, progress
    /// and elapsed time as `PostScanActivity` reports, and how many other
    /// documents are waiting to be finished.
    private var activity: ActivityStatus.Content {
        let waiting = viewModel.exportsInProgress
        if case let .scanning(progress, _) = viewModel.status {
            return .init(symbol: .scanner, tint: .accentColor, title: Text(viewModel.status.displayText), fraction: progress, waiting: waiting, isWorking: true)
        }
        if viewModel.pendingProcessingCount > 0 {
            return .init(symbol: .system("photo.on.rectangle"), tint: .accentColor, title: Text("Processing \(viewModel.pendingProcessingCount)…"), waiting: waiting, isWorking: true)
        }
        if viewModel.isSavingPages {
            return .init(symbol: .system("square.and.arrow.down"), tint: .accentColor, title: Text("Saving…"), waiting: waiting - 1, isWorking: true)
        }
        if let activity = viewModel.postScanActivity {
            return .init(symbol: .system(activity.symbol), tint: .accentColor, title: Text(activity.title), detail: Text(activity.detail), fraction: activity.fraction, startedAt: activity.startedAt, waiting: waiting - 1, isWorking: true)
        }
        if case let .error(message) = viewModel.status {
            return .init(symbol: .system("exclamationmark.octagon.fill"), tint: .red, title: Text(message))
        }
        if let first = viewModel.lastOutputs.first, !viewModel.isSavingShownPages {
            let files = viewModel.lastOutputs.count == 1 ? Text(first.lastPathComponent) : Text("Files: \(viewModel.lastOutputs.count)")
            return .init(symbol: .system("checkmark.circle.fill"), tint: .green, title: Text("Finished"), detail: files)
        }
        return .init(symbol: .scanner, tint: viewModel.status == .disconnected ? .secondary : .green, title: Text(viewModel.status.displayText), isEmphasized: false)
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
        .controlSize(.mini)
        .frame(width: 130)
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
                        PageThumbnail(page: page, selected: page.id == viewModel.selectedPageID, size: thumbnailSize, progress: viewModel.pageProgress[page.id])
                            .id(page.id)
                            .onTapGesture { viewModel.selectedPageID = page.id; focusPages() }
                            .contextMenu {
                                Button("Quick Look") { viewModel.selectedPageID = page.id; viewModel.toggleQuickLook() }
                                Button("Rotate 90°") { Task { viewModel.selectedPageID = page.id; await viewModel.rotateSelectedPage() } }
                                Button("Delete", role: .destructive) { Task { viewModel.selectedPageID = page.id; await viewModel.deleteSelectedPage() } }
                            }
                    }
                }
                .padding(16)
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

    private var inspector: some View {
        Form {
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
            Section("Destination") {
                LabeledContent("Save to") {
                    Text(viewModel.destinationFolder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .help(viewModel.destinationFolder.path)
                Text(viewModel.destinationFolder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                HStack {
                    Button { viewModel.chooseDestination() } label: { Label("Choose…", systemImage: "folder.badge.gearshape") }
                    Button { viewModel.openDestinationFolder() } label: { Label("Show", systemImage: "folder") }
                    Spacer()
                    Button("Reset") { viewModel.resetDestination() }
                        .disabled(viewModel.destinationFolder.standardizedFileURL == DestinationFolderStore.defaultFolder.standardizedFileURL)
                        .help("Use the default folder \(DestinationFolderStore.defaultFolder.path)")
                }
                LabeledContent("Open with") {
                    if let app = viewModel.openWithAppURL { Text(app.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle) }
                    else if viewModel.openWithBundleID != nil { Text("App not found").foregroundStyle(.orange) }
                    else { Text("No app") }
                }
                HStack {
                    Button { viewModel.chooseOpenWithApp() } label: { Label("Choose App…", systemImage: "app.badge") }
                    Spacer()
                    Button("Don't Open") { viewModel.openWithBundleID = nil }.disabled(viewModel.openWithBundleID == nil)
                }
                Text("Each saved file opens in this app, after OCR if it runs, for example to import it into a document manager.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Language / OCR") {
                Picker("OCR language", selection: $viewModel.ocrSettings.language) {
                    ForEach(OCRLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Run OCR (ocrmypdf) after scanning", isOn: $viewModel.ocrSettings.runOCRmyPDF)
                if viewModel.ocrSettings.runOCRmyPDF {
                    Picker("OCR engine", selection: $viewModel.ocrSettings.engine) { ForEach(OCRmyPDFEngine.allCases) { Text($0.rawValue).tag($0) } }
                }
                if viewModel.isRunningOCR { HStack { ProgressView().controlSize(.small); Text("Running ocrmypdf…").font(.caption).foregroundStyle(.secondary) } }
                else if viewModel.ocrSettings.runOCRmyPDF && OCRmyPDFRunner.locate(customPath: viewModel.ocrSettings.ocrmypdfPath) == nil { Text("ocrmypdf was not found. Install it with \"brew install ocrmypdf\".").font(.caption).foregroundStyle(.orange) }
                else { Text("Same setting as Settings ▸ Language. Applies to every exported PDF.").font(.caption).foregroundStyle(.secondary) }
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
                TextField("Filename template", text: profileString(\.options.export.filenameTemplate)); Text("Tokens: {date}, {time}, {name}, {docdate}, {sender}, {type}, {subject}, {person}, {page}, {side}").font(.caption).foregroundStyle(.secondary)
                TextField("Date format", text: profileString(\.options.export.dateFormat), prompt: Text(verbatim: ExportSettings.defaultDateFormat))
                TextField("Time format", text: profileString(\.options.export.timeFormat), prompt: Text(verbatim: ExportSettings.defaultTimeFormat))
                Text("For {date}, {docdate} and {time}: yyyy = year, MM = month, dd = day, HH = hour, mm = minute, ss = second; for example dd.MM.yyyy. Empty uses the default.").font(.caption).foregroundStyle(.secondary)
                if viewModel.selectedProfile.options.export.filenameTemplate.contains("{name}") {
                    if let reason = FoundationModelNameSuggester.unavailableReason { Text("\(reason) {name} becomes \"\(DocumentName.fallback)\".").font(.caption).foregroundStyle(.orange) }
                    else { Text("{name} is proposed on this Mac by Apple Intelligence from the text of the first pages.").font(.caption).foregroundStyle(.secondary) }
                }
                if ScanOutputWriter.analysisTokens.contains(where: viewModel.selectedProfile.options.export.filenameTemplate.contains) {
                    if let reason = FoundationModelNameSuggester.unavailableReason { Text("\(reason) {sender}, {type} and {subject} stay empty; {docdate} and {person} still work.").font(.caption).foregroundStyle(.orange) }
                    else { Text("{sender}, {type} and {subject} are read on this Mac by Apple Intelligence, using only words written in the document. {docdate} is the date the document was written, or the scan date. {person} comes from the people list in Settings ▸ Language.").font(.caption).foregroundStyle(.secondary) }
                }
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
                Toggle("Remove blank pages", isOn: profile(\.options.processing.removeBlankPages))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Deskew and crop to page", isOn: profile(\.options.processing.deskew))
                    Text("Straightens skewed sheets and crops away the paper edges, like ScanSnap Home. Also available as Edit > Auto-Align Page.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Crop to content", isOn: profile(\.options.processing.autoCrop))
                    Text("Trims the paper margins down to the printed content, for receipts and clippings.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Automatic orientation", isOn: profile(\.options.processing.autoRotate))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("AI page orientation", isOn: profile(\.options.processing.aiOrientation))
                    Text("Apple's on-device text recognition reads each page and turns it so the text is upright, including pages fed upside down. Pages without text keep the automatic orientation above.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Diagnostics") {
                if viewModel.selectedScannerUsesEpjitsuProtocol, let profile = viewModel.selectedEpjitsuProfile {
                    VStack(alignment: .leading, spacing: 5) {
                        Button("Choose \(profile.name) firmware…") { viewModel.chooseEpjitsuFirmware() }
                        Text(viewModel.epjitsuFirmwareFilename.map { "\(profile.name) firmware: \($0)" } ?? "\(profile.name) firmware is not selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Activity Log…") { showingActivityLog = true }
                if !viewModel.lastOutputs.isEmpty { Text("Last export: \(ByteCountFormatter.string(fromByteCount: viewModel.lastOutputByteCount, countStyle: .file))").font(.caption) }
            }
        }.formStyle(.grouped)
    }

    private func profile<T>(_ keyPath: WritableKeyPath<ScanProfile, T>) -> Binding<T> { Binding(get: { viewModel.selectedProfile[keyPath: keyPath] }, set: { var p = viewModel.selectedProfile; p[keyPath: keyPath] = $0; viewModel.updateProfile(p) }) }
    private func profileString(_ keyPath: WritableKeyPath<ScanProfile, String>) -> Binding<String> { profile(keyPath) }
    private func capabilityToggle(_ title: String, value: Binding<Bool>, supported: Bool, reason: String) -> some View { Toggle(title, isOn: value).disabled(!supported).help(supported ? "" : reason) }
    private var paperCleanupLabel: String {
        let amount = viewModel.selectedProfile.options.processing.paperCleanup
        return amount == 0 ? "Off" : "\(Int((amount * 100).rounded()))%"
    }
}

private struct PageThumbnail: View {
    let page: StoredPage
    let selected: Bool
    /// Minimum width of the grid cell; the image height follows it.
    let size: Double
    /// nil when the page is not part of an export.
    let progress: ScannerWorkspaceViewModel.PageProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(contentsOf: page.fileURL) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: size, maxHeight: size * 1.6)
                    .background(.white)
            } else {
                Image(systemName: "photo").frame(maxWidth: .infinity, minHeight: size * 1.25)
            }
            HStack(spacing: 5) {
                Text("Page \(page.pageIndex) · \(page.side.rawValue)").font(.caption).foregroundStyle(.secondary)
                switch progress {
                case .readingText:
                    ProgressView().controlSize(.mini).help("Reading text…").accessibilityLabel("Reading text…")
                case .textRecognized:
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.blue).help("Text recognized").accessibilityLabel("Text recognized")
                case .fileFinished:
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).help("File finished").accessibilityLabel("File finished")
                case nil:
                    EmptyView()
                }
            }
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

/// The activity log in a sheet, opened from the inspector.
private struct ActivityLogView: View {
    let viewModel: ScannerWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity log").font(.headline)
            ScrollView {
                Text(viewModel.activityLog.reversed().joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy log") { viewModel.copyActivityLog() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

/// What the app is doing, at the left of the status line: a colored symbol
/// that pulses while work goes on, the step, its detail, and during an export
/// a small progress bar and the elapsed time.
struct ActivityStatus: View {
    /// The scanner drawing from the asset catalog, or an SF Symbol.
    enum Symbol { case scanner, system(String) }

    struct Content {
        var symbol: Symbol
        var tint: Color
        var title: Text
        var detail: Text? = nil
        /// nil shows no bar.
        var fraction: Double? = nil
        var startedAt: Date? = nil
        /// Other documents still to be finished.
        var waiting = 0
        var isEmphasized = true
        var isWorking = false
    }

    let content: Content

    var body: some View {
        HStack(spacing: 6) {
            symbol
                .frame(width: 16, height: 16)
                .foregroundStyle(content.tint)
                .symbolEffect(.pulse, isActive: content.isWorking)
            content.title
                .fontWeight(content.isEmphasized ? .medium : .regular)
                .foregroundStyle(content.isEmphasized ? .primary : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = content.detail {
                detail.foregroundStyle(.secondary).monospacedDigit().lineLimit(1).truncationMode(.middle)
            }
            if let fraction = content.fraction {
                ProgressView(value: fraction).controlSize(.small).frame(width: 80)
            }
            if let startedAt = content.startedAt {
                Text(startedAt, style: .timer).foregroundStyle(.secondary).monospacedDigit()
            }
            if content.waiting > 0 {
                Text("Waiting: \(content.waiting)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(content.detail ?? content.title)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var symbol: some View {
        switch content.symbol {
        case .scanner: Image("ScannerSheetFed").resizable().scaledToFit()
        case let .system(name): Image(systemName: name)
        }
    }
}
