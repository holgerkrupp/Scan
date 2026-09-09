import AppKit
import Foundation
import Observation
import SwiftUI

actor ScanPageStore {
    private let folder: URL
    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func append(_ frame: PageFrame) throws -> StoredPage {
        let url = folder.appendingPathComponent("\(frame.id.uuidString).page")
        try frame.data.write(to: url, options: .atomic)
        return StoredPage(frame: frame, fileURL: url)
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
    var discoveredIdentities: [ScannerIdentity] = []
    var selectedIdentity: ScannerIdentity? { didSet { updateCapabilities() } }
    var selectedProfile: ScanProfile
    var profiles: [ScanProfile]
    var capabilities: ScannerCapabilities?
    var destinationFolder: URL { didSet { persistDestinationBookmark() } }
    var status: ScannerStatus = .disconnected
    var pages: [StoredPage] = []
    var selectedPageID: UUID?
    var pagesScanned = 0
    var lastOutputs: [URL] = []
    var lastOutputByteCount: Int64 = 0
    var activityLog: [String] = []
    var isRefreshing = false
    var isScanning = false
    var showsSimulator = true
    var diagnosticsExpanded = false
    var isCancelRequested = false

    private let discovery: ScannerDiscovery
    private let registry: ScannerDriverRegistry
    private let outputWriter: ScanOutputWriter
    private var profileStore: ScanProfileStore
    private var activeDevice: ScannerDevice?
    private var pageStore: ScanPageStore?
    private var traceObserver: NSObjectProtocol?

    convenience init() { self.init(discovery: CompositeScannerDiscovery(), registry: .live, outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: .standard)) }

    init(discovery: ScannerDiscovery, registry: ScannerDriverRegistry, outputWriter: ScanOutputWriter, profileStore: ScanProfileStore) {
        self.discovery = discovery; self.registry = registry; self.outputWriter = outputWriter; self.profileStore = profileStore
        let loadedProfiles = profileStore.load()
        self.profiles = loadedProfiles
        let selectedID = profileStore.selectedProfileID
        self.selectedProfile = loadedProfiles.first(where: { $0.id == selectedID }) ?? loadedProfiles[0]
        self.destinationFolder = Self.restoreDestinationBookmark() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scans", isDirectory: true)
        traceObserver = NotificationCenter.default.addObserver(forName: ScanTrace.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let message = note.userInfo?[ScanTrace.messageKey] as? String else { return }
            Task { @MainActor [weak self] in self?.log(message) }
        }
    }

    func refreshDevices() async {
        isRefreshing = true; defer { isRefreshing = false }
        var identities = await discovery.discover()
        if showsSimulator { identities.append(contentsOf: [MockScannerDriver.identity, MockScannerDriver.limitedIdentity]) }
        discoveredIdentities = identities
        if selectedIdentity == nil || !identities.contains(where: { $0.id == selectedIdentity?.id }) { selectedIdentity = identities.first }
        status = selectedIdentity == nil ? .disconnected : .idle
        log("Discovered \(identities.count) scanner candidate\(identities.count == 1 ? "" : "s").")
    }

    func capabilities(for identity: ScannerIdentity) -> ScannerCapabilities? { registry.capabilities(for: identity) }

    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Folder"; panel.directoryURL = destinationFolder
        if panel.runModal() == .OK, let url = panel.url { destinationFolder = url; _ = url.startAccessingSecurityScopedResource(); log("Destination set to \(url.path).") }
    }

    func startScan() async {
        guard let selectedIdentity else { status = .error("Select a scanner before scanning."); return }
        guard let driver = registry.driver(for: selectedIdentity) else { status = .error("No driver is available for \(selectedIdentity.name). This device is discovered but unsupported."); return }
        guard let capabilities = registry.capabilities(for: selectedIdentity) else { status = .error("Capabilities are unavailable for \(selectedIdentity.name)."); return }
        do { try capabilities.validate(selectedProfile.options) } catch { status = .error(error.localizedDescription); log(error.localizedDescription); return }

        isScanning = true; isCancelRequested = false; pagesScanned = 0; lastOutputs = []; lastOutputByteCount = 0; pages = []; selectedPageID = nil; status = .scanning(progress: nil, pagesScanned: 0)
        let store = ScanPageStore(); pageStore = store
        let transport: USBDeviceTransport? = selectedIdentity.connectionKind == .usb ? IOKitUSBDeviceTransport(identity: selectedIdentity) : nil
        let device = driver.makeDevice(identity: selectedIdentity, transport: transport); activeDevice = device
        defer { activeDevice = nil; isScanning = false }
        do {
            try await device.open(); if let transport { log("Opened USB pipes: \(await transport.endpointSummary).") }
            let stream = try await device.startScan(options: selectedProfile.options)
            for try await frame in stream {
                let page = try await store.append(frame)
                pages.append(page); pagesScanned = pages.count; selectedPageID = selectedPageID ?? page.id; status = .scanning(progress: nil, pagesScanned: pages.count)
            }
            status = .idle; log("Received \(pages.count) page\(pages.count == 1 ? "" : "s").")
            if selectedProfile.options.export.automaticallySaveAfterScanning { await saveExport() }
        } catch {
            if isCancelRequested || error is CancellationError || (error as? ScannerError) == .scanCancelled { status = .idle; log("Scan cancelled; retained \(pages.count) partial page\(pages.count == 1 ? "" : "s") for review.") }
            else { status = .error(error.localizedDescription); log("Scan failed: \(error.localizedDescription)") }
        }
        await device.close()
    }

    func cancelScan() async {
        guard isScanning else { return }; isCancelRequested = true; await activeDevice?.cancel(); activeDevice = nil; status = .idle; isScanning = false; log("Scan cancellation requested; partial pages are retained.")
    }

    func saveExport() async {
        guard !pages.isEmpty else { status = .error("There are no pages to export."); return }
        do { let result = try await outputWriter.write(pages: pages, options: selectedProfile.options, destinationFolder: destinationFolder); lastOutputs = result.outputURLs; lastOutputByteCount = result.outputByteCount; status = .idle; log("Exported \(result.pagesScanned) page\(result.pagesScanned == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: result.outputByteCount, countStyle: .file))).") }
        catch { status = .error(error.localizedDescription); log("Export failed: \(error.localizedDescription)") }
    }

    func clearPages() async { pages = []; selectedPageID = nil; lastOutputs = []; lastOutputByteCount = 0; await pageStore?.clear(); pageStore = nil; log("Cleared pages and output links.") }
    func revealInFinder() { guard let url = lastOutputs.first ?? (pages.first.map { $0.fileURL }) else { return }; NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func deleteSelectedPage() async { guard let id = selectedPageID, let index = pages.firstIndex(where: { $0.id == id }) else { return }; pages.remove(at: index); selectedPageID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id; log("Deleted page.") }
    func movePage(from source: IndexSet, to destination: Int) { pages.move(fromOffsets: source, toOffset: destination) }

    func rotateSelectedPage() async {
        guard let id = selectedPageID, let index = pages.firstIndex(where: { $0.id == id }), let store = pageStore else { return }
        do {
            let page = pages[index]; let frame = PageFrame(id: page.id, pageIndex: page.pageIndex, side: page.side, pixelFormat: page.pixelFormat, width: page.width, height: page.height, resolutionDPI: page.resolutionDPI, data: try Data(contentsOf: page.fileURL))
            let settings = ImageProcessingSettings(rotation: .degrees90); guard let rotated = try ScanImageProcessor.process(frame, settings: settings, outputDPI: frame.resolutionDPI) else { return }
            pages[index] = try await store.replace(page, with: rotated); log("Rotated page \(index + 1) by 90 degrees.")
        } catch { log("Could not rotate page: \(error.localizedDescription)") }
    }

    func copyActivityLog() { let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(activityLog.reversed().joined(separator: "\n"), forType: .string); log("Activity log copied.") }
    func updateProfile(_ profile: ScanProfile) { guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }; profiles[index] = profile; selectedProfile = profile; profileStore.selectedProfileID = profile.id; persistProfiles() }
    func selectProfile(id: UUID) { guard let profile = profiles.first(where: { $0.id == id }) else { return }; selectedProfile = profile; profileStore.selectedProfileID = profile.id; persistProfiles() }
    func duplicateSelectedProfile() { var copy = selectedProfile; copy.name += " Copy"; copy = ScanProfile(name: copy.name, options: copy.options); profiles.append(copy); selectedProfile = copy; profileStore.selectedProfileID = copy.id; persistProfiles() }
    func profileBinding() -> Binding<ScanProfile> { Binding(get: { self.selectedProfile }, set: { self.updateProfile($0) }) }
    func isSupported(_ source: ScanSource) -> Bool { capabilities?.sources.contains(source) ?? false }
    func isSupported(_ mode: ScanColorMode) -> Bool { capabilities?.colorModes.contains(mode) ?? false }
    func isSupported(_ dpi: Int) -> Bool { capabilities?.resolutionsDPI.contains(dpi) ?? false }
    func isSupported(_ format: ScanOutputFormat) -> Bool { capabilities?.outputFormats.contains(format) ?? false }

    private func updateCapabilities() {
        capabilities = selectedIdentity.flatMap { registry.capabilities(for: $0) }
        guard let capabilities else { return }
        var profile = selectedProfile
        if !capabilities.sources.contains(profile.options.source), let first = capabilities.sources.first { profile.options.source = first }
        if !capabilities.colorModes.contains(profile.options.colorMode), let first = capabilities.colorModes.first { profile.options.colorMode = first }
        if !capabilities.resolutionsDPI.contains(profile.options.resolutionDPI), let nearest = capabilities.resolutionsDPI.min(by: { abs($0 - profile.options.resolutionDPI) < abs($1 - profile.options.resolutionDPI) }) { profile.options.resolutionDPI = nearest }
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
