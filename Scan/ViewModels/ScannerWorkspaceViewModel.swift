import AppKit
import Foundation
import Observation
import SwiftUI

/// A page as the scanner delivered it. Raw pages are kept for the whole
/// review session so the processing options can be changed and re-applied.
struct RawPage: Identifiable, Sendable {
    let id: UUID
    let pageIndex: Int
    let side: PageSide
    let pixelFormat: PagePixelFormat
    let width: Int
    let height: Int
    let resolutionDPI: Int
    let fileURL: URL

    nonisolated init(frame: PageFrame, fileURL: URL) {
        id = frame.id; pageIndex = frame.pageIndex; side = frame.side; pixelFormat = frame.pixelFormat; width = frame.width; height = frame.height; resolutionDPI = frame.resolutionDPI; self.fileURL = fileURL
    }

    nonisolated func frame() throws -> PageFrame {
        PageFrame(id: id, pageIndex: pageIndex, side: side, pixelFormat: pixelFormat, width: width, height: height, resolutionDPI: resolutionDPI, data: try Data(contentsOf: fileURL, options: .mappedIfSafe))
    }
}

/// Adjustments made to one page in the workspace, applied on top of the
/// profile's processing settings each time the page is rendered.
struct PageEdits: Equatable, Sendable {
    /// Quarter turns clockwise added to the profile's rotation.
    var quarterTurns = 0
    /// Straighten and crop this page even if the profile does not.
    var align = false
}

/// Files of one review session: the raw scans and the processed pages the
/// workspace shows and exports.
actor ScanPageStore {
    private let folder: URL
    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func append(_ frame: PageFrame) throws -> StoredPage {
        // Named and typed like a document so Quick Look shows a readable title
        // and picks the image previewer.
        let name = "Page \(frame.pageIndex)\(frame.side == .unknown ? "" : " \(frame.side.rawValue)")"
        var url = folder.appendingPathComponent(name).appendingPathExtension(Self.fileExtension(for: frame.pixelFormat))
        if FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(frame.id.uuidString)").appendingPathExtension(Self.fileExtension(for: frame.pixelFormat))
        }
        try frame.data.write(to: url, options: .atomic)
        return StoredPage(frame: frame, fileURL: url)
    }
    static func fileExtension(for format: PagePixelFormat) -> String {
        switch format {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .rgb8, .gray8, .unknown: "page"
        }
    }
    func replace(_ page: StoredPage, with frame: PageFrame) throws -> StoredPage {
        try frame.data.write(to: page.fileURL, options: .atomic)
        return StoredPage(frame: frame, fileURL: page.fileURL)
    }

    func clear() { try? FileManager.default.removeItem(at: folder) }
}

@MainActor
@Observable
final class ScannerWorkspaceViewModel {
    /// The single workspace is shared by the window and App Intents so a scan
    /// started from Shortcuts is visible when the app is brought to the front.
    static let shared = ScannerWorkspaceViewModel()

    var discoveredIdentities: [ScannerIdentity] = []
    var selectedIdentity: ScannerIdentity? { didSet { updateCapabilities() } }
    var selectedProfile: ScanProfile
    var profiles: [ScanProfile]
    var capabilities: ScannerCapabilities?
    var destinationFolder: URL { didSet { persistDestinationBookmark() } }
    var status: ScannerStatus = .disconnected
    /// The scans as delivered, in display order. They stay for the whole
    /// review session so the processing options can be re-applied.
    private(set) var rawPages: [RawPage] = []
    /// Per-page rotation and alignment overrides.
    private(set) var pageEdits: [UUID: PageEdits] = [:]
    /// The processed rendition of each raw page; missing while it is being
    /// processed or when it was found blank.
    private(set) var processedPages: [UUID: StoredPage] = [:]
    /// Raw pages hidden because "Remove blank pages" found them empty.
    private(set) var blankPageIDs: Set<UUID> = []
    /// Pages still being (re)processed in the background.
    private(set) var pendingProcessingCount = 0
    /// What the grid shows and the export writes: the processed pages, in
    /// scan order, without the blank ones.
    var pages: [StoredPage] { rawPages.compactMap { processedPages[$0.id] } }
    var hiddenBlankPageCount: Int { blankPageIDs.count }
    var selectedPageID: UUID?
    /// Columns the page grid currently shows; the view keeps it current so
    /// keyboard navigation (also from the Quick Look panel) can move vertically.
    var gridColumns = 1
    var pagesScanned = 0
    var lastOutputs: [URL] = []
    var lastOutputByteCount: Int64 = 0
    var activityLog: [String] = []
    var isRefreshing = false
    var isScanning = false
    var diagnosticsExpanded = false
    var isCancelRequested = false
    var s300FirmwareFilename: String?

    private let discovery: ScannerDiscovery
    private let registry: ScannerDriverRegistry
    private let outputWriter: ScanOutputWriter
    private var profileStore: ScanProfileStore
    private var activeDevice: ScannerDevice?
    private var pageStore: ScanPageStore?
    private var traceObserver: NSObjectProtocol?
    private let s300FirmwareStore: ScanSnapS300FirmwareStore
    private let automaticRefreshDelay: Duration
    private var automaticRefreshTask: Task<Void, Never>?
    private var processingGeneration = 0
    private var processingChain: Task<Void, Never>?
    private var reprocessDebounce: Task<Void, Never>?

    convenience init() { self.init(discovery: CompositeScannerDiscovery(), registry: .live, outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: .standard)) }

    init(discovery: ScannerDiscovery, registry: ScannerDriverRegistry, outputWriter: ScanOutputWriter, profileStore: ScanProfileStore, automaticRefreshDelay: Duration = .seconds(1)) {
        self.discovery = discovery; self.registry = registry; self.outputWriter = outputWriter; self.profileStore = profileStore; self.automaticRefreshDelay = automaticRefreshDelay
        let firmwareStore = ScanSnapS300FirmwareStore(defaults: .standard)
        self.s300FirmwareStore = firmwareStore
        self.s300FirmwareFilename = firmwareStore.selectedFilename
        let loadedProfiles = profileStore.load()
        self.profiles = loadedProfiles
        let selectedID = profileStore.selectedProfileID
        self.selectedProfile = loadedProfiles.first(where: { $0.id == selectedID }) ?? loadedProfiles[0]
        self.destinationFolder = Self.restoreDestinationBookmark() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scans", isDirectory: true)
        traceObserver = NotificationCenter.default.addObserver(forName: ScanTrace.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let message = note.userInfo?[ScanTrace.messageKey] as? String else { return }
            Task { @MainActor [weak self] in self?.log(message) }
        }
        discovery.observeChanges { [weak self] in self?.scheduleAutomaticRefresh() }
    }

    func refreshDevices() async { await refreshDevices(isAutomatic: false) }

    private func refreshDevices(isAutomatic: Bool) async {
        isRefreshing = true; defer { isRefreshing = false }
        let previousSelectionID = selectedIdentity?.id
        let identities = await discovery.discover()
        discoveredIdentities = identities
        if selectedIdentity == nil || !identities.contains(where: { $0.id == selectedIdentity?.id }) { selectedIdentity = identities.first }
        // An automatic refresh keeps the current status (such as an unread scan error) unless the selected scanner changed.
        if !isAutomatic || selectedIdentity?.id != previousSelectionID { status = selectedIdentity == nil ? .disconnected : .idle }
        log("Discovered \(identities.count) scanner candidate\(identities.count == 1 ? "" : "s").")
    }

    /// Plugging in a scanner fires several notifications (USB and Image Capture), so they are coalesced into one refresh.
    /// A refresh resets the scan status, so it waits until a running scan has finished.
    private func scheduleAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { [weak self, automaticRefreshDelay] in
            try? await Task.sleep(for: automaticRefreshDelay)
            while self?.isScanning == true, !Task.isCancelled { try? await Task.sleep(for: automaticRefreshDelay) }
            guard !Task.isCancelled, let self else { return }
            self.log("Scanner connection change detected.")
            await self.refreshDevices(isAutomatic: true)
        }
    }

    func capabilities(for identity: ScannerIdentity) -> ScannerCapabilities? { registry.capabilities(for: identity) }

    var selectedScannerUsesS300Protocol: Bool {
        guard let deviceID = selectedIdentity?.usbDeviceID else { return false }
        return FujitsuScanSnapS300Driver(firmwareProvider: { nil }).supportedUSBDeviceIDs.contains(deviceID)
    }

    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Folder"; panel.directoryURL = destinationFolder
        panel.title = "Choose Default Saving Location"
        panel.message = "Scans will be saved to this folder by default."
        if panel.runModal() == .OK, let url = panel.url {
            _ = url.startAccessingSecurityScopedResource()
            destinationFolder = url
            log("Destination set to \(url.path).")
        }
    }

    func chooseS300Firmware() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose ScanSnap S300 Firmware"
        panel.message = "Select 300_0C00.nal for an S300 or 300M_0C00.nal for an S300M. The app stores only a security-scoped bookmark."
        panel.prompt = "Use Firmware"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try s300FirmwareStore.saveFirmware(at: url)
            s300FirmwareFilename = url.lastPathComponent
            log("S300 firmware selected: \(url.lastPathComponent).")
        } catch {
            status = .error(error.localizedDescription)
            log("Could not use S300 firmware: \(error.localizedDescription)")
        }
    }

    func startScan() async {
        guard let selectedIdentity else { status = .error("Select a scanner before scanning."); return }
        guard let driver = registry.driver(for: selectedIdentity) else { status = .error("No driver is available for \(selectedIdentity.name). This device is discovered but unsupported."); return }

        isScanning = true; isCancelRequested = false; pagesScanned = 0; lastOutputs = []; lastOutputByteCount = 0; status = .scanning(progress: nil, pagesScanned: 0)
        resetPages()
        let store = ScanPageStore(); pageStore = store
        let transport: USBDeviceTransport? = selectedIdentity.connectionKind == .usb ? IOKitUSBDeviceTransport(identity: selectedIdentity) : nil
        let device = driver.makeDevice(identity: selectedIdentity, transport: transport); activeDevice = device
        defer { activeDevice = nil; isScanning = false }
        do {
            try await device.open()
            capabilities = device.capabilities
            reconcileProfile(using: device.capabilities)
            if let transport { log("Opened USB pipes: \(await transport.endpointSummary).") }
            let stream = try await device.startScan(options: selectedProfile.options)
            for try await frame in stream {
                try await ingest(frame)
                status = .scanning(progress: nil, pagesScanned: rawPages.count)
            }
            status = .idle; log("Received \(rawPages.count) page\(rawPages.count == 1 ? "" : "s").")
            await waitForProcessing()
            if selectedProfile.options.export.automaticallySaveAfterScanning { await saveExport() }
        } catch {
            if isCancelRequested || error is CancellationError || (error as? ScannerError) == .scanCancelled { status = .idle; log("Scan cancelled; retained \(pages.count) partial page\(pages.count == 1 ? "" : "s") for review.") }
            else { status = .error(error.localizedDescription); log("Scan failed: \(error.localizedDescription)") }
        }
        await device.close()
    }

    /// Runs the selected profile as a complete, export-producing job for an
    /// automation. Unlike the interactive Scan button, this always exports the
    /// captured pages so Shortcuts has files it can pass to its next action.
    func scanAndExport(profileID: UUID? = nil) async throws -> ScanJobResult {
        if let profileID {
            guard profiles.contains(where: { $0.id == profileID }) else {
                throw ScannerError.outputFailed("The selected scan profile is no longer available.")
            }
            selectProfile(id: profileID)
        }

        await refreshDevices()
        guard selectedIdentity != nil else { throw ScannerError.deviceNotFound }

        await startScan()
        if isCancelRequested { throw ScannerError.scanCancelled }
        if case let .error(message) = status { throw ScannerError.outputFailed(message) }
        guard !pages.isEmpty else { throw ScannerError.feederEmpty }

        if lastOutputs.isEmpty {
            await saveExport()
        }
        if case let .error(message) = status { throw ScannerError.outputFailed(message) }
        guard !lastOutputs.isEmpty else {
            throw ScannerError.outputFailed("The scan finished without creating an output file.")
        }
        return ScanJobResult(outputURLs: lastOutputs, pagesScanned: pages.count, outputByteCount: lastOutputByteCount)
    }

    func cancelScan() async {
        guard isScanning else { return }; isCancelRequested = true; await activeDevice?.cancel(); activeDevice = nil; status = .idle; isScanning = false; log("Scan cancellation requested; partial pages are retained.")
    }

    func saveExport() async {
        await waitForProcessing()
        guard !pages.isEmpty else { status = .error(rawPages.isEmpty ? "There are no pages to export." : "Every page was found blank; turn off blank-page removal to export them."); return }
        do { let result = try await outputWriter.write(pages: pages, options: selectedProfile.options, destinationFolder: destinationFolder); lastOutputs = result.outputURLs; lastOutputByteCount = result.outputByteCount; status = .idle; log("Exported \(result.pagesScanned) page\(result.pagesScanned == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: result.outputByteCount, countStyle: .file))).") }
        catch { status = .error(error.localizedDescription); log("Export failed: \(error.localizedDescription)") }
    }

    func clearPages() async { resetPages(); lastOutputs = []; lastOutputByteCount = 0; await pageStore?.clear(); pageStore = nil; log("Cleared pages and output links.") }
    func revealInFinder() { guard let url = lastOutputs.first ?? (pages.first.map { $0.fileURL }) else { return }; NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openDestinationFolder() {
        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(destinationFolder)
        } catch {
            status = .error("Could not open the saving location: \(error.localizedDescription)")
            log("Could not open destination: \(error.localizedDescription)")
        }
    }
    var selectedPage: StoredPage? { pages.first { $0.id == selectedPageID } }

    /// Opens or closes the Quick Look panel (Space or Command-Y). Like the
    /// Finder's, the panel previews whatever is selected and follows the selection.
    func toggleQuickLook() { PageQuickLookController.shared.toggle() }

    /// Moves the selection with the keyboard; `columns` is the grid's current column count.
    func selectPage(moving move: PageGridNavigation.Move, columns: Int) {
        let current = pages.firstIndex { $0.id == selectedPageID }
        guard let index = PageGridNavigation.index(after: current, move: move, count: pages.count, columns: columns) else { return }
        selectedPageID = pages[index].id
    }

    func deleteSelectedPage() async { guard let id = selectedPageID, let index = pages.firstIndex(where: { $0.id == id }) else { return }; pages.remove(at: index); selectedPageID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id; log("Deleted page.") }
    func movePage(from source: IndexSet, to destination: Int) { pages.move(fromOffsets: source, toOffset: destination) }

    func rotateSelectedPage() async {
        guard let id = selectedPageID, let raw = rawPages.first(where: { $0.id == id }) else { return }
        pageEdits[id, default: PageEdits()].quarterTurns += 1
        log("Rotated page \(raw.pageIndex) by 90 degrees.")
        processPage(raw)
    }

    /// Edit > Auto-Align Page: straightens the selected page and crops its
    /// edges, whether or not the profile does so for every page.
    func alignSelectedPage() async {
        guard let id = selectedPageID, let raw = rawPages.first(where: { $0.id == id }) else { return }
        if selectedProfile.options.processing.deskew { log("Page \(raw.pageIndex) is already aligned by the profile."); return }
        pageEdits[id, default: PageEdits()].align = true
        log("Aligned page \(raw.pageIndex).")
        processPage(raw)
    }

    // MARK: - Processing pipeline

    /// Stores a frame from the scanner as a raw page and queues its processing.
    /// Exposed for tests; `startScan` feeds every received frame through it.
    func ingest(_ frame: PageFrame) async throws {
        let store: ScanPageStore
        if let pageStore { store = pageStore } else { store = ScanPageStore(); pageStore = store }
        let raw = try await store.appendRaw(frame)
        rawPages.append(raw)
        pagesScanned = rawPages.count
        processPage(raw)
    }

    /// The profile's processing settings with the page's own edits on top.
    func effectiveProcessingSettings(for pageID: UUID) -> ImageProcessingSettings {
        var settings = selectedProfile.options.processing
        let edits = pageEdits[pageID] ?? PageEdits()
        let degrees = ((settings.rotation.rawValue + 90 * edits.quarterTurns) % 360 + 360) % 360
        settings.rotation = PageRotation(rawValue: degrees) ?? .degrees0
        if edits.align { settings.deskew = true }
        return settings
    }

    /// Suspends until every queued page has been processed.
    func waitForProcessing() async {
        while let chain = processingChain, pendingProcessingCount > 0 {
            await chain.value
            if processingChain == chain { break }
        }
    }

    private func resetPages() {
        processingGeneration += 1
        rawPages = []; processedPages = [:]; pageEdits = [:]; blankPageIDs = []; selectedPageID = nil; pagesScanned = 0
    }

    /// Re-renders every page after the processing options changed. Debounced,
    /// because sliders and toggles fire in quick succession.
    private func scheduleReprocessAll() {
        reprocessDebounce?.cancel()
        reprocessDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.processingGeneration += 1
            for raw in self.rawPages { self.processPage(raw) }
        }
    }

    /// Renders one raw page with the current settings on a background
    /// thread, one page after another, and publishes the result unless the
    /// settings changed again or the page was removed in the meantime.
    private func processPage(_ raw: RawPage) {
        guard let store = pageStore else { return }
        let settings = effectiveProcessingSettings(for: raw.id)
        let generation = processingGeneration
        pendingProcessingCount += 1
        let previous = processingChain
        processingChain = Task { [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) { () -> Result<PageFrame?, Error> in
                Result { try Self.render(raw, settings: settings) }
            }.value
            guard let self else { return }
            self.pendingProcessingCount = max(0, self.pendingProcessingCount - 1)
            guard generation == self.processingGeneration, self.rawPages.contains(where: { $0.id == raw.id }) else { return }
            switch outcome {
            case let .success(frame?):
                do {
                    self.processedPages[raw.id] = try await store.writeProcessed(frame)
                    self.blankPageIDs.remove(raw.id)
                } catch {
                    self.log("Could not store page \(raw.pageIndex): \(error.localizedDescription)")
                }
            case .success(nil):
                if self.blankPageIDs.insert(raw.id).inserted { self.log("Page \(raw.pageIndex) is blank and hidden.") }
                self.processedPages[raw.id] = nil
            case let .failure(error):
                self.log("Could not process page \(raw.pageIndex): \(error.localizedDescription)")
                // Keep the page visible rather than losing it.
                if self.processedPages[raw.id] == nil, let frame = try? raw.frame(), let stored = try? await store.writeProcessed(frame) { self.processedPages[raw.id] = stored }
            }
            self.reconcileSelection()
        }
    }

    nonisolated private static func render(_ raw: RawPage, settings: ImageProcessingSettings) throws -> PageFrame? {
        let frame = try raw.frame()
        return try ScanImageProcessor.process(frame, settings: settings, outputDPI: frame.resolutionDPI)
    }

    /// Keeps a page selected while pages appear and disappear.
    private func reconcileSelection() {
        let visible = pages
        if let selectedPageID, visible.contains(where: { $0.id == selectedPageID }) { return }
        selectedPageID = visible.first?.id
    }

    func copyActivityLog() { let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(activityLog.reversed().joined(separator: "\n"), forType: .string); log("Activity log copied.") }
    func updateProfile(_ profile: ScanProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let processingChanged = profile.options.processing != selectedProfile.options.processing || profile.id != selectedProfile.id
        profiles[index] = profile; selectedProfile = profile; profileStore.selectedProfileID = profile.id; persistProfiles()
        if processingChanged, !rawPages.isEmpty { scheduleReprocessAll() }
    }
    func selectProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let processingChanged = profile.options.processing != selectedProfile.options.processing
        selectedProfile = profile; profileStore.selectedProfileID = profile.id; persistProfiles()
        if processingChanged, !rawPages.isEmpty { scheduleReprocessAll() }
    }
    func duplicateSelectedProfile() { var copy = selectedProfile; copy.name += " Copy"; copy = ScanProfile(name: copy.name, options: copy.options); profiles.append(copy); selectedProfile = copy; profileStore.selectedProfileID = copy.id; persistProfiles() }
    func profileBinding() -> Binding<ScanProfile> { Binding(get: { self.selectedProfile }, set: { self.updateProfile($0) }) }
    func isSupported(_ source: ScanSource) -> Bool {
        if let capabilities { return capabilities.sources.contains(source) }
        return selectedIdentity?.connectionKind == .imageCapture && source != .adfBack
    }
    func isSupported(_ mode: ScanColorMode) -> Bool { capabilities?.colorModes.contains(mode) ?? (selectedIdentity?.connectionKind == .imageCapture) }
    func isSupported(_ dpi: Int) -> Bool { capabilities?.resolutions(for: selectedProfile.options.source).contains(dpi) ?? (selectedIdentity?.connectionKind == .imageCapture) }
    func isSupported(_ format: ScanOutputFormat) -> Bool { capabilities?.outputFormats.contains(format) ?? (selectedIdentity?.connectionKind == .imageCapture) }

    private func updateCapabilities() {
        if selectedIdentity?.connectionKind == .imageCapture {
            // Image Capture reports unit-specific settings only after an open
            // session. Do not reject a saved profile based on guessed values.
            capabilities = nil
            return
        }
        capabilities = selectedIdentity.flatMap { registry.capabilities(for: $0) }
        guard let capabilities else { return }
        reconcileProfile(using: capabilities)
    }

    private func reconcileProfile(using capabilities: ScannerCapabilities) {
        var profile = selectedProfile
        if !capabilities.sources.contains(profile.options.source), let first = capabilities.sources.first { profile.options.source = first }
        if !capabilities.colorModes.contains(profile.options.colorMode), let first = capabilities.colorModes.first { profile.options.colorMode = first }
        let sourceResolutions = capabilities.resolutions(for: profile.options.source)
        if !sourceResolutions.contains(profile.options.resolutionDPI), let nearest = sourceResolutions.min(by: { abs($0 - profile.options.resolutionDPI) < abs($1 - profile.options.resolutionDPI) }) { profile.options.resolutionDPI = nearest }
        if !capabilities.outputFormats.contains(profile.options.outputFormat), let first = capabilities.outputFormats.first { profile.options.outputFormat = first }
        if !capabilities.supportsBlankPageRemoval { profile.options.removeBlankPages = false }
        if !capabilities.supportsDeskew { profile.options.deskew = false }
        if !capabilities.supportsAutoCrop { profile.options.autoCrop = false }
        if !capabilities.supportsAutoRotate { profile.options.autoRotate = false }
        if !capabilities.supportsScannerBuffering { profile.options.acquisition.scannerBuffering = false }
        if !capabilities.supportsHardwareCompression { profile.options.acquisition.hardwareCompression = false }
        if profile != selectedProfile { updateProfile(profile) }
    }
    private func persistProfiles() { profileStore.save(profiles) }
    private func persistDestinationBookmark() { guard let data = try? destinationFolder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }; UserDefaults.standard.set(data, forKey: "scan.destinationBookmark") }
    private static func restoreDestinationBookmark() -> URL? { guard let data = UserDefaults.standard.data(forKey: "scan.destinationBookmark") else { return nil }; var stale = false; guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }; _ = url.startAccessingSecurityScopedResource(); return url }
    private func log(_ message: String) { let formatter = DateFormatter(); formatter.timeStyle = .medium; activityLog.insert("[\(formatter.string(from: Date()))] \(message)", at: 0); activityLog = Array(activityLog.prefix(100)) }
}
