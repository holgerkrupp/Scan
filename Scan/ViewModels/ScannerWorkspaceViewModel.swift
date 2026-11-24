import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class HardwareScanCoordinator {
    private let registry: ScannerDriverRegistry
    private let onEvent: (ScannerIdentity, ScannerHardwareEventCapabilities, ScannerHardwareEvent) -> Void
    private let onDiagnostic: (String) -> Void
    private var task: Task<Void, Never>?
    private var activeDevice: ScannerDevice?
    private var activeSource: ScannerHardwareEventSource?
    /// Set while monitoring a scanner that needs `requiresExclusiveSession`.
    private var stopWaitsForMonitor = false

    init(
        registry: ScannerDriverRegistry,
        onEvent: @escaping (ScannerIdentity, ScannerHardwareEventCapabilities, ScannerHardwareEvent) -> Void,
        onDiagnostic: @escaping (String) -> Void
    ) {
        self.registry = registry
        self.onEvent = onEvent
        self.onDiagnostic = onDiagnostic
    }

    /// The S1300i stops responding when two sessions talk to it at once or a
    /// session is closed in the middle of a command, so its monitor is
    /// replaced only after the previous one has released the scanner.
    private static func requiresExclusiveSession(_ identity: ScannerIdentity) -> Bool {
        identity.usbDeviceID.flatMap(EpjitsuScanSnapModelProfile.profile(for:)) == .s1300i
    }

    func start(identity: ScannerIdentity) {
        stopWaitsForMonitor = Self.requiresExclusiveSession(identity)
        if stopWaitsForMonitor {
            let previous = task
            previous?.cancel()
            task = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                await self?.monitor(identity: identity)
            }
            return
        }
        task = Task { [weak self] in
            await self?.monitor(identity: identity)
        }
    }

    func stop() async {
        if stopWaitsForMonitor {
            // The monitor closes its own device on the way out.
            guard let task else { return }
            self.task = nil
            task.cancel()
            await activeSource?.stopHardwareEventObservation()
            await task.value
            return
        }
        task?.cancel()
        task = nil
        await activeSource?.stopHardwareEventObservation()
        await activeDevice?.close()
        activeSource = nil
        activeDevice = nil
    }

    private func monitor(identity: ScannerIdentity) async {
        let closesOnCancellation = Self.requiresExclusiveSession(identity)
        while !Task.isCancelled {
            guard let driver = registry.driver(for: identity) else { return }
            let transport: USBDeviceTransport? = identity.connectionKind == .usb ? IOKitUSBDeviceTransport(identity: identity) : nil
            let device = driver.makeDevice(identity: identity, transport: transport)
            activeDevice = device
            do {
                try await device.open()
                guard let source = device as? ScannerHardwareEventSource else {
                    onDiagnostic("\(identity.name) does not expose a hardware-button event source.")
                    await device.close()
                    return
                }
                activeSource = source
                let capabilities = source.hardwareEventCapabilities
                let stream = try await source.startHardwareEventObservation()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    onEvent(identity, capabilities, event)
                }
            } catch is CancellationError {
                // An exclusive-session monitor still closes its device below.
                guard closesOnCancellation else { break }
            } catch {
                onDiagnostic("Hardware-button monitoring for \(identity.name) is unavailable: \(error.localizedDescription)")
            }
            await sourceStopAndClose(source: activeSource, device: device)
            activeSource = nil
            activeDevice = nil
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func sourceStopAndClose(source: ScannerHardwareEventSource?, device: ScannerDevice) async {
        await source?.stopHardwareEventObservation()
        await device.close()
    }
}

final class ScanNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ScanNotificationService()
    private let center = UNUserNotificationCenter.current()
    private let categoryID = "scan.hardware-result"
    private let revealActionID = "scan.reveal-result"

    private override init() {
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: revealActionID, title: "Reveal Scan", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID, actions: [action], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifySuccess(identity: ScannerIdentity, outputURLs: [URL], pages: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Scan complete"
        content.body = "\(identity.name) scanned \(pages) page\(pages == 1 ? "" : "s")."
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = ["url": outputURLs.first?.path as Any]
        add(content)
    }

    func notifyFailure(identity: ScannerIdentity, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Scan failed"
        content.body = "\(identity.name): \(message)"
        content.sound = .default
        content.categoryIdentifier = categoryID
        add(content)
    }

    private func add(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: "scan-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request)
    }

    // The notification center may call its delegate on any thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        let path = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            else { NSApp.activate(ignoringOtherApps: true) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

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

    func appendRaw(_ frame: PageFrame) throws -> RawPage {
        let url = folder.appendingPathComponent("Raw \(Self.baseName(for: frame))").appendingPathExtension(Self.fileExtension(for: frame.pixelFormat))
        try frame.data.write(to: url, options: .atomic)
        return RawPage(frame: frame, fileURL: url)
    }

    /// Writes the processed rendition of a raw page. Named and typed like a
    /// document so Quick Look shows a readable title and picks the image previewer.
    func writeProcessed(_ frame: PageFrame) throws -> StoredPage {
        let url = folder.appendingPathComponent("Page \(Self.baseName(for: frame))").appendingPathExtension(Self.fileExtension(for: frame.pixelFormat))
        try frame.data.write(to: url, options: .atomic)
        return StoredPage(frame: frame, fileURL: url)
    }

    private static func baseName(for frame: PageFrame) -> String {
        "\(frame.pageIndex)\(frame.side == .unknown ? "" : " \(frame.side.rawValue)") \(frame.id.uuidString.prefix(8))"
    }

    // Kept for callers that use ScanPageStore directly (for example, Quick Look tests).
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

/// A scan that stopped with its pages kept, waiting for "Scan More" or
/// "Finish and Save" (`AcquisitionSettings.asksToContinueWhenFeederEmpties`).
struct ScanInterruption: Equatable, Sendable {
    let message: String
    /// The feeder simply ran out, as opposed to a jam or a double feed.
    var isEndOfStack = false
    let destinationOverride: URL?
}

extension PageFrame {
    /// The same page placed after `offset` pages already in the document.
    nonisolated func renumbered(by offset: Int) -> PageFrame {
        offset == 0 ? self : PageFrame(id: id, pageIndex: pageIndex + offset, side: side, pixelFormat: pixelFormat, width: width, height: height, resolutionDPI: resolutionDPI, data: data)
    }
}

/// Long-running work after the scanner has finished - text recognition,
/// the Apple Intelligence filename and ocrmypdf - shown in the status line
/// below the pages. `fraction` is nil when the step cannot report its progress.
struct PostScanActivity: Equatable {
    var symbol: String
    var title: String
    var detail: String
    var fraction: Double?
    /// When the whole export started; drives the elapsed-time display.
    var startedAt: Date

    static func step(_ progress: ExportProgress, startedAt: Date) -> PostScanActivity {
        switch progress {
        case let .readingText(page, total):
            PostScanActivity(symbol: "text.viewfinder", title: "Reading text for the filename", detail: "Page \(page) of \(total) · Vision OCR", fraction: Double(page - 1) / Double(max(total, 1)), startedAt: startedAt)
        case .proposingName:
            PostScanActivity(symbol: "apple.intelligence", title: "Apple Intelligence is naming the document", detail: "Proposing a title from the recognized text", fraction: nil, startedAt: startedAt)
        case let .writingPage(page, total, recognizingText):
            PostScanActivity(symbol: recognizingText ? "doc.text.magnifyingglass" : "doc.richtext", title: recognizingText ? "Recognizing text (OCR)" : "Writing the export", detail: "Page \(page) of \(total)", fraction: Double(page - 1) / Double(max(total, 1)), startedAt: startedAt)
        }
    }

    static func ocrmypdf(file: Int, of total: Int, name: String, language: String, startedAt: Date) -> PostScanActivity {
        PostScanActivity(symbol: "doc.text.magnifyingglass", title: "Running OCR (ocrmypdf)", detail: total > 1 ? "PDF \(file) of \(total) · \(name) · \(language)" : "\(name) · \(language)", fraction: total > 1 ? Double(file - 1) / Double(total) : nil, startedAt: startedAt)
    }
}

@MainActor
@Observable
final class ScannerWorkspaceViewModel {
    /// The single workspace is shared by the window and App Intents so a scan
    /// started from Shortcuts is visible when the app is brought to the front.
    static let shared = ScannerWorkspaceViewModel()

    var discoveredIdentities: [ScannerIdentity] = []
    var selectedIdentity: ScannerIdentity? { didSet { updateCapabilities(); refreshEpjitsuFirmwareSelection() } }
    var selectedProfile: ScanProfile
    var profiles: [ScanProfile]
    var capabilities: ScannerCapabilities?
    var destinationFolder: URL { didSet { persistDestinationBookmark() } }
    private let destinationStore = DestinationFolderStore(defaults: .standard)
    /// Settings ▸ Language: default OCR language and the ocrmypdf switch.
    var ocrSettings: OCRSettings { didSet { ocrSettingsStore.save(ocrSettings) } }
    private let ocrSettingsStore = OCRSettingsStore(defaults: .standard)
    /// The app each saved file is opened in, such as a document manager
    /// that files it; nil opens nothing.
    var openWithBundleID: String? = UserDefaults.standard.string(forKey: ScannerWorkspaceViewModel.openWithKey) { didSet { UserDefaults.standard.set(openWithBundleID, forKey: Self.openWithKey) } }
    private static let openWithKey = "scan.openWithBundleID"
    /// True while ocrmypdf runs on the last export.
    var isRunningOCR = false
    /// Set while an export runs its OCR and AI steps; nil otherwise.
    private(set) var postScanActivity: PostScanActivity?
    /// How far each page has got in the last export, shown on its thumbnail.
    enum PageProgress { case readingText, textRecognized, fileFinished }
    private(set) var pageProgress: [UUID: PageProgress] = [:]
    /// Exports waiting or running behind the scanner, oldest first, each
    /// with the page session it saves. The next scan does not wait for them.
    private(set) var exportSessions: [Int] = []
    /// True while the pages are being saved, before they can be finished in the background.
    private(set) var isSavingPages = false
    var exportsInProgress: Int { exportSessions.count }
    /// True while the pages on screen are being saved, so they are not saved twice.
    var isSavingShownPages: Bool { exportSessions.contains(pageSession) }
    private var exportQueue: Task<Void, Never>?
    /// The latest queued export, so an automation can wait for its own files.
    private var latestExport: (session: Int, task: Task<ScanJobResult, Never>)?
    /// Changes whenever the pages on screen are replaced or cleared.
    private var pageSession = 0
    /// Set while a scan is paused (feeder empty, paper jam, double feed) and its pages are kept.
    private(set) var scanInterruption: ScanInterruption?
    /// Scanner of the pages on screen, so an export is counted for it.
    private var lastScanScannerID: String?
    private let statisticsStore: ScanStatisticsStore
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
    var isCancelRequested = false
    var epjitsuFirmwareFilename: String?
    var hardwareButtonSettings: HardwareButtonSettings
    var hardwareButtonCapabilities: ScannerHardwareEventCapabilities?
    var hardwareButtonStatusMessage: String?

    private let discovery: ScannerDiscovery
    private let registry: ScannerDriverRegistry
    private let outputWriter: ScanOutputWriter
    private var profileStore: ScanProfileStore
    private var activeDevice: ScannerDevice?
    private var pageStore: ScanPageStore?
    private var traceObserver: NSObjectProtocol?
    private let automaticRefreshDelay: Duration
    private var automaticRefreshTask: Task<Void, Never>?
    private let hardwareSettingsStore: HardwareButtonSettingsStore
    private var hardwareDiagnosticKeys: Set<String> = []
    private var processingGeneration = 0
    private var processingChain: Task<Void, Never>?
    private var reprocessDebounce: Task<Void, Never>?

    @ObservationIgnored private var hardwareCoordinator: HardwareScanCoordinator? = nil

    convenience init() { self.init(discovery: CompositeScannerDiscovery(wifi: VENSScannerDiscovery()), registry: .live, outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: .standard)) }

    init(discovery: ScannerDiscovery, registry: ScannerDriverRegistry, outputWriter: ScanOutputWriter, profileStore: ScanProfileStore, automaticRefreshDelay: Duration = .seconds(1), statisticsStore: ScanStatisticsStore? = nil) {
        self.discovery = discovery; self.registry = registry; self.outputWriter = outputWriter; self.profileStore = profileStore; self.automaticRefreshDelay = automaticRefreshDelay; self.statisticsStore = statisticsStore ?? .shared
        let hardwareStore = HardwareButtonSettingsStore(defaults: .standard)
        self.hardwareSettingsStore = hardwareStore
        self.hardwareButtonSettings = hardwareStore.load()
        self.epjitsuFirmwareFilename = nil
        let loadedProfiles = profileStore.load()
        self.profiles = loadedProfiles
        let selectedID = profileStore.selectedProfileID
        self.selectedProfile = loadedProfiles.first(where: { $0.id == selectedID }) ?? loadedProfiles[0]
        self.destinationFolder = DestinationFolderStore(defaults: .standard).restore() ?? DestinationFolderStore.defaultFolder
        self.ocrSettings = OCRSettingsStore(defaults: .standard).load()
        traceObserver = NotificationCenter.default.addObserver(forName: ScanTrace.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let message = note.userInfo?[ScanTrace.messageKey] as? String else { return }
            Task { @MainActor [weak self] in self?.log(message) }
        }
        self.hardwareCoordinator = HardwareScanCoordinator(
            registry: registry,
            onEvent: { [weak self] identity, capabilities, event in
                self?.handleHardwareEvent(identity: identity, capabilities: capabilities, event: event)
            },
            onDiagnostic: { [weak self] message in self?.logHardwareDiagnostic(message) }
        )
        discovery.observeChanges { [weak self] in self?.scheduleAutomaticRefresh() }
    }

    var hardwareButtonEnabled: Bool {
        get { hardwareButtonSettings.enabled }
        set { setHardwareButtonEnabled(newValue) }
    }

    var hardwareLaunchAtLogin: Bool {
        get { hardwareButtonSettings.launchAtLogin }
        set { setHardwareLaunchAtLogin(newValue) }
    }

    var hardwareDefaultProfileID: UUID? {
        get { hardwareButtonSettings.defaultProfileID }
        set {
            hardwareButtonSettings.defaultProfileID = newValue
            persistHardwareSettings()
            Task { await restartHardwareMonitoring() }
        }
    }

    func applicationDidLaunch() async {
        applyBackgroundPolicy()
        guard hardwareButtonSettings.enabled else { return }
        await ScanNotificationService.shared.requestAuthorization()
        await refreshDevices()
        await restartHardwareMonitoring()
    }

    func setHardwareButtonEnabled(_ enabled: Bool) {
        if enabled, hardwareButtonSettings.defaultProfileID == nil {
            hardwareButtonSettings.defaultProfileID = selectedProfile.id
        }
        hardwareButtonSettings.enabled = enabled
        persistHardwareSettings()
        applyBackgroundPolicy()
        Task {
            if enabled { await ScanNotificationService.shared.requestAuthorization() }
            await restartHardwareMonitoring()
        }
    }

    func setHardwareLaunchAtLogin(_ enabled: Bool) {
        hardwareButtonSettings.launchAtLogin = enabled
        persistHardwareSettings()
        applyBackgroundPolicy()
    }

    func hardwareProfileID(for identity: ScannerIdentity) -> UUID? {
        hardwareButtonSettings.perScannerProfileIDs[identity.id] ?? hardwareButtonSettings.defaultProfileID ?? selectedProfile.id
    }

    func setHardwareProfileOverride(_ profileID: UUID?, for identity: ScannerIdentity) {
        if let profileID { hardwareButtonSettings.perScannerProfileIDs[identity.id] = profileID }
        else { hardwareButtonSettings.perScannerProfileIDs.removeValue(forKey: identity.id) }
        persistHardwareSettings()
    }

    func hardwareDestination(for identity: ScannerIdentity) -> URL {
        hardwareSettingsStore.destination(for: identity, settings: hardwareButtonSettings) ?? destinationFolder
    }

    func chooseHardwareDestination() {
        guard let identity = selectedIdentity else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = hardwareDestination(for: identity)
        panel.prompt = "Use for One-Touch Scans"
        panel.title = "One-Touch Scan Destination"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try hardwareSettingsStore.setDestination(url, for: identity, settings: &hardwareButtonSettings)
            hardwareButtonStatusMessage = "One-touch scans for \(identity.name) will be saved to \(url.path)."
            log(hardwareButtonStatusMessage ?? "")
        } catch {
            hardwareButtonStatusMessage = "Could not save the one-touch destination: \(error.localizedDescription)"
            logHardwareDiagnostic(hardwareButtonStatusMessage ?? "")
        }
    }

    func hardwareProfileSummary(for identity: ScannerIdentity?) -> String {
        guard let identity, let profileID = hardwareProfileID(for: identity), let profile = profiles.first(where: { $0.id == profileID }) else {
            return "No one-touch profile selected."
        }
        let options = profile.options
        return "\(profile.name), \(options.source.rawValue.lowercased()), \(options.resolutionDPI) dpi \(options.colorMode.rawValue.lowercased()) → \(hardwareDestination(for: identity).path)"
    }

    private func persistHardwareSettings() { hardwareSettingsStore.save(hardwareButtonSettings) }

    private func applyBackgroundPolicy() {
        NSApp.setActivationPolicy(hardwareButtonSettings.enabled ? .accessory : .regular)
        do {
            if hardwareButtonSettings.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            logHardwareDiagnostic("Could not update launch-at-login: \(error.localizedDescription)")
        }
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
        if hardwareButtonSettings.enabled, !isScanning { await restartHardwareMonitoring() }
    }

    private func restartHardwareMonitoring() async {
        await hardwareCoordinator?.stop()
        guard hardwareButtonSettings.enabled, !isScanning else { return }
        guard let identity = selectedIdentity ?? discoveredIdentities.first else {
            hardwareButtonStatusMessage = "One-touch scanning is enabled, but no scanner is connected."
            return
        }
        hardwareCoordinator?.start(identity: identity)
    }

    private func handleHardwareEvent(
        identity: ScannerIdentity,
        capabilities: ScannerHardwareEventCapabilities,
        event: ScannerHardwareEvent
    ) {
        hardwareButtonCapabilities = capabilities
        switch event {
        case .scanButtonPressed:
            guard capabilities.supportsOneTouchScanning else {
                let message = "\(identity.name) reported a Scan button press, but one-touch acquisition is not available for this backend yet."
                hardwareButtonStatusMessage = message
                logHardwareDiagnostic(message)
                return
            }
            guard hardwareButtonSettings.enabled, !isScanning else { return }
            Task { await performHardwareScan(for: identity) }
        case let .feederChanged(hasPaper):
            log("\(identity.name) feeder \(hasPaper ? "has paper" : "is empty") (hardware event).")
        case let .diagnostic(message):
            logHardwareDiagnostic(message)
        }
    }

    private func logHardwareDiagnostic(_ message: String) {
        let key = message.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        guard hardwareDiagnosticKeys.insert(key).inserted else { return }
        hardwareButtonStatusMessage = message
        log(message)
    }

    private func performHardwareScan(for identity: ScannerIdentity) async {
        guard !isScanning else { return }
        let profileID = hardwareProfileID(for: identity)
        let destination = hardwareDestination(for: identity)
        do {
            await hardwareCoordinator?.stop()
            // While a document is paused, the button adds the next stack to it.
            if scanInterruption != nil { await startScan(destinationOverride: destination, continuing: true); return }
            let result = try await scanAndExport(profileID: profileID, identity: identity, destinationOverride: destination)
            ScanNotificationService.shared.notifySuccess(identity: identity, outputURLs: result.outputURLs, pages: result.pagesScanned)
        } catch {
            // Waiting for the next stack or for "Finish and Save" is not a failure.
            if scanInterruption != nil { return }
            logHardwareDiagnostic("One-touch scan failed for \(identity.name): \(error.localizedDescription)")
            ScanNotificationService.shared.notifyFailure(identity: identity, message: error.localizedDescription)
            await restartHardwareMonitoring()
        }
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
    func details(for identity: ScannerIdentity) -> ScannerDetails {
        let usbProperties = USBDeviceEnumerator().registryProperties(for: identity)
        return registry.details(for: identity, usbRegistryProperties: usbProperties)
    }

    var selectedScannerUsesEpjitsuProtocol: Bool {
        guard let deviceID = selectedIdentity?.usbDeviceID else { return false }
        return EpjitsuScanSnapModelProfile.profile(for: deviceID) != nil
    }

    var selectedEpjitsuProfile: EpjitsuScanSnapModelProfile? {
        selectedIdentity?.usbDeviceID.flatMap(EpjitsuScanSnapModelProfile.profile(for:))
    }

    func refreshEpjitsuFirmwareSelection() {
        guard let profile = selectedEpjitsuProfile else {
            epjitsuFirmwareFilename = nil
            return
        }
        epjitsuFirmwareFilename = EpjitsuScanSnapFirmwareStore(profile: profile, defaults: .standard).selectedFilename
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

    func chooseEpjitsuFirmware() {
        guard let profile = selectedEpjitsuProfile else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose \(profile.name) Firmware"
        panel.message = "Select \(profile.expectedFirmwareFileNames.joined(separator: " or ")). The app stores a model-specific security-scoped bookmark."
        panel.prompt = "Use Firmware"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EpjitsuScanSnapFirmwareStore(profile: profile, defaults: .standard).saveFirmware(at: url)
            epjitsuFirmwareFilename = url.lastPathComponent
            log("\(profile.name) firmware selected: \(url.lastPathComponent).")
        } catch {
            status = .error(error.localizedDescription)
            log("Could not use \(profile.name) firmware: \(error.localizedDescription)")
        }
    }

    /// `alwaysExport` is set by automations (hardware button, Shortcuts), which
    /// must produce files even when the profile does not save automatically.
    /// A paused scan, or `continuing`, adds the new pages to those on screen.
    func startScan(destinationOverride: URL? = nil, alwaysExport: Bool = false, continuing: Bool = false) async {
        guard let selectedIdentity else { status = .error("Select a scanner before scanning."); return }
        guard let driver = registry.driver(for: selectedIdentity) else { status = .error("No driver is available for \(selectedIdentity.name). This device is discovered but unsupported."); return }

        let paused = scanInterruption
        let resumes = (continuing || paused != nil) && !rawPages.isEmpty
        let destinationOverride = destinationOverride ?? paused?.destinationOverride
        scanInterruption = nil
        await hardwareCoordinator?.stop()
        isScanning = true; isCancelRequested = false; lastOutputs = []; lastOutputByteCount = 0; status = .scanning(progress: nil, pagesScanned: resumes ? rawPages.count : 0)
        let scanStartedAt = Date(); var scanOutcome = ScanRecord.Outcome.completed; var scanFinishedAt: Date?
        lastScanScannerID = selectedIdentity.id
        if !resumes {
            pagesScanned = 0
            resetPages()
            pageStore = ScanPageStore()
        }
        let pageOffset = rawPages.count, blankPageOffset = hiddenBlankPageCount
        let asksForMore = selectedProfile.options.acquisition.asksToContinueWhenFeederEmpties
        let transport: USBDeviceTransport? = selectedIdentity.connectionKind == .usb ? IOKitUSBDeviceTransport(identity: selectedIdentity) : nil
        let device = driver.makeDevice(identity: selectedIdentity, transport: transport); activeDevice = device
        do {
            try await device.open()
            capabilities = device.capabilities
            reconcileProfile(using: device.capabilities)
            if let transport { log("Opened USB pipes: \(await transport.endpointSummary).") }
            let stream = try await device.startScan(options: selectedProfile.options.forScanner)
            for try await frame in stream {
                try await ingest(frame.renumbered(by: pageOffset))
                status = .scanning(progress: nil, pagesScanned: rawPages.count)
            }
            status = .idle; log("Received \(rawPages.count) page\(rawPages.count == 1 ? "" : "s").")
            scanFinishedAt = Date()
            if asksForMore {
                scanInterruption = ScanInterruption(message: String(localized: "The feeder is empty."), isEndOfStack: true, destinationOverride: destinationOverride)
            } else {
                await waitForProcessing()
                if alwaysExport || selectedProfile.options.export.automaticallySaveAfterScanning { await saveExport(destinationOverride: destinationOverride) }
            }
        } catch {
            if isCancelRequested || error is CancellationError || (error as? ScannerError) == .scanCancelled { scanOutcome = .cancelled; status = .idle; log("Scan cancelled; retained \(pages.count) partial page\(pages.count == 1 ? "" : "s") for review.") }
            else if asksForMore, !rawPages.isEmpty {
                // The sheets before the jam are complete: keep them and let the scan go on.
                scanOutcome = .failed
                scanFinishedAt = Date()
                scanInterruption = ScanInterruption(message: error.localizedDescription, destinationOverride: destinationOverride)
                status = .error(error.localizedDescription)
                log("Scan paused after \(rawPages.count) page\(rawPages.count == 1 ? "" : "s"): \(error.localizedDescription)")
            }
            else {
                scanOutcome = (error as? ScannerError) == .feederEmpty && rawPages.isEmpty ? .cancelled : .failed
                log("Scan failed: \(error.localizedDescription)")
                scanFinishedAt = Date()
                await savePagesBeforeFailure(error: error, destinationOverride: destinationOverride, alwaysExport: alwaysExport)
            }
        }
        // A resumed scan counts only the pages of this run.
        statisticsStore.append(ScanRecord(date: scanStartedAt, scannerID: selectedIdentity.id, kind: .scan, pages: rawPages.count - pageOffset, blankPages: max(0, hiddenBlankPageCount - blankPageOffset), duration: (scanFinishedAt ?? Date()).timeIntervalSince(scanStartedAt), outcome: scanOutcome))
        await device.close()
        // Clear the scan state before restarting, as restartHardwareMonitoring() skips the restart while isScanning is true.
        activeDevice = nil; isScanning = false
        await restartHardwareMonitoring()
    }

    /// Ends a paused scan and saves the document with the pages received so far.
    func finishInterruptedScan() async {
        guard let interruption = scanInterruption else { return }
        scanInterruption = nil
        status = .idle
        await saveExport(destinationOverride: interruption.destinationOverride)
    }

    /// A jam or multifeed ends the batch, but the sheets transferred before it
    /// are complete: save them like a finished scan (processing, export, OCR)
    /// so a background one-touch scan does not lose them on the next press.
    private func savePagesBeforeFailure(error: Error, destinationOverride: URL?, alwaysExport: Bool) async {
        let message = error.localizedDescription
        guard !rawPages.isEmpty, alwaysExport || selectedProfile.options.export.automaticallySaveAfterScanning else {
            status = .error(message)
            return
        }
        await waitForProcessing()
        // Waits for the final file name, which the message gives.
        _ = await saveExport(destinationOverride: destinationOverride)?.value
        if lastOutputs.isEmpty {
            status = .error(message)
        } else {
            let saved = "\(pages.count) page\(pages.count == 1 ? "" : "s") scanned before the failure \(pages.count == 1 ? "was" : "were") saved to \(lastOutputs.first?.lastPathComponent ?? "the destination")."
            log(saved)
            status = .error("\(message) \(saved)")
        }
    }

    /// Runs the selected profile as a complete, export-producing job for an
    /// automation. Unlike the interactive Scan button, this always exports the
    /// captured pages so Shortcuts has files it can pass to its next action.
    func scanAndExport(profileID: UUID? = nil, identity: ScannerIdentity? = nil, destinationOverride: URL? = nil) async throws -> ScanJobResult {
        if let profileID {
            guard profiles.contains(where: { $0.id == profileID }) else {
                throw ScannerError.outputFailed("The selected scan profile is no longer available.")
            }
            selectProfile(id: profileID)
        }

        if let identity { selectedIdentity = identity }
        else { await refreshDevices() }
        guard selectedIdentity != nil else { throw ScannerError.deviceNotFound }

        await startScan(destinationOverride: destinationOverride, alwaysExport: true)
        if isCancelRequested { throw ScannerError.scanCancelled }
        // A paused scan is finished from its dialog, never saved half done from here.
        if let scanInterruption { throw ScannerError.outputFailed(scanInterruption.message) }
        if case let .error(message) = status { throw ScannerError.outputFailed(message) }
        guard !pages.isEmpty else { throw ScannerError.feederEmpty }

        // This scan's own files, with their final names; the scanner is free again meanwhile.
        let session = pageSession
        var export = latestExport?.session == session ? latestExport?.task : nil
        if export == nil { export = await saveExport(destinationOverride: destinationOverride) }
        if let export {
            let result = await export.value
            if session == pageSession, case let .error(message) = status { throw ScannerError.outputFailed(message) }
            if !result.outputURLs.isEmpty { return result }
        }
        if case let .error(message) = status { throw ScannerError.outputFailed(message) }
        throw ScannerError.outputFailed("The scan finished without creating an output file.")
    }

    /// The exported filename shown next to the window title, but only when
    /// Apple Intelligence filled the template's `{name}` token.
    var aiFilenameSubtitle: String? {
        guard selectedProfile.options.export.filenameTemplate.contains("{name}"), !isSavingShownPages,
              FoundationModelNameSuggester.unavailableReason == nil,
              let first = lastOutputs.first else { return nil }
        return lastOutputs.count > 1 ? "\(first.lastPathComponent) (+\(lastOutputs.count - 1))" : first.lastPathComponent
    }

    func cancelScan() async {
        guard isScanning else { return }; isCancelRequested = true; await activeDevice?.cancel(); activeDevice = nil; status = .idle; isScanning = false; log("Scan cancellation requested; partial pages are retained.")
    }

    /// Saves the pages on screen at once, then queues the slow part: the text
    /// layer, the name read from the document, ocrmypdf and the app that
    /// opens the files. Documents are finished one after another behind the
    /// scanner, so the next scan can start right away; the returned task
    /// gives this document's final files.
    @discardableResult
    func saveExport(destinationOverride: URL? = nil) async -> Task<ScanJobResult, Never>? {
        await waitForProcessing()
        guard !pages.isEmpty else { status = .error(rawPages.isEmpty ? "There are no pages to export." : "Every page was found blank; turn off blank-page removal to export them."); return nil }
        let session = pageSession, options = selectedProfile.options, folder = destinationOverride ?? destinationFolder
        let scannerID = lastScanScannerID ?? selectedIdentity?.id ?? "unknown"
        let date = Date()
        // Only these two need the document's text, which takes a while.
        let template = options.export.filenameTemplate
        let readsText = options.export.outputFormat == .searchablePDF || template.contains("{name}") || ScanOutputWriter.analysisTokens.contains(where: template.contains)
        var quick = options
        if quick.export.outputFormat == .searchablePDF { quick.export.outputFormat = .pdf }
        exportSessions.append(session)
        isSavingPages = true
        let snapshot: (pages: [StoredPage], folder: URL)
        let saved: ScanJobResult
        do {
            // The next scan or Clear removes the page files; the export keeps its own links to them.
            snapshot = try ScanOutputWriter.snapshot(pages)
            do { saved = try await outputWriter.write(pages: snapshot.pages, options: quick, destinationFolder: folder, ocrLanguage: ocrSettings.language, people: ocrSettings.people, date: date, naming: DocumentNaming()) }
            catch { try? FileManager.default.removeItem(at: snapshot.folder); throw error }
        } catch {
            isSavingPages = false
            if let index = exportSessions.lastIndex(of: session) { exportSessions.remove(at: index) }
            status = .error(error.localizedDescription); log("Export failed: \(error.localizedDescription)")
            return nil
        }
        isSavingPages = false
        lastOutputs = saved.outputURLs; lastOutputByteCount = saved.outputByteCount; status = .idle
        log("Saved \(saved.pagesScanned) page\(saved.pagesScanned == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: saved.outputByteCount, countStyle: .file)))\(readsText ? "; the text and the name follow" : "").")
        let previous = exportQueue
        let task = Task {
            await previous?.value
            defer { try? FileManager.default.removeItem(at: snapshot.folder); if let index = exportSessions.firstIndex(of: session) { exportSessions.remove(at: index) } }
            return await finishExport(saved, pages: snapshot.pages, options: options, readsText: readsText, date: date, session: session, scannerID: scannerID)
        }
        exportQueue = Task { _ = await task.value }
        latestExport = (session, task)
        return task
    }

    /// Waits until every queued document is finished.
    func waitForExports() async {
        while !exportSessions.isEmpty, let queue = exportQueue { await queue.value }
    }

    /// Writes the document again with its text and name, puts those files in
    /// place of the saved ones, then runs ocrmypdf and opens the files. The
    /// saved files stay as they are when a step fails. Only the export of
    /// the pages still on screen updates the window.
    private func finishExport(_ saved: ScanJobResult, pages exported: [StoredPage], options: ScanOptions, readsText: Bool, date: Date, session: Int, scannerID: String) async -> ScanJobResult {
        let startedAt = Date()
        var outputs = saved.outputURLs
        pageProgress = [:]
        outputWriter.onProgress = { [weak self] progress in
            self?.postScanActivity = .step(progress, startedAt: startedAt)
            // Pages are written in order, so those before the current one have their text.
            if case let .writingPage(page, _, true) = progress {
                for (index, exportedPage) in exported.enumerated() where index < page { self?.pageProgress[exportedPage.id] = index < page - 1 ? .textRecognized : .readingText }
            }
        }
        defer { outputWriter.onProgress = nil; postScanActivity = nil }
        if readsText, let folder = outputs.first?.deletingLastPathComponent() {
            do {
                // A folder on the same volume, so the finished files move into place without a copy.
                let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let finished = try await outputWriter.write(pages: exported, options: options, destinationFolder: staging, ocrLanguage: ocrSettings.language, people: ocrSettings.people, date: date)
                guard finished.outputURLs.count == outputs.count else { throw ScannerError.outputFailed("The finished export has \(finished.outputURLs.count) files instead of \(outputs.count).") }
                outputs = try outputWriter.replace(outputs, with: finished.outputURLs)
                log("Finished \(outputs.map(\.lastPathComponent).joined(separator: ", ")).")
            } catch {
                for page in exported { pageProgress[page.id] = nil }
                log("Could not add the text and the name; the files are saved without them: \(error.localizedDescription)")
                if session == pageSession { status = .error(error.localizedDescription) }
            }
        }
        for (id, progress) in pageProgress where progress == .readingText { pageProgress[id] = .textRecognized }
        if session == pageSession { lastOutputs = outputs }
        await runOCRmyPDFIfEnabled(on: outputs, startedAt: startedAt)
        openInChosenApp(outputs)
        for page in exported { pageProgress[page.id] = .fileFinished }
        let bytes = outputs.reduce(Int64(0)) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
        if session == pageSession { lastOutputByteCount = bytes }
        statisticsStore.append(ScanRecord(date: Date(), scannerID: scannerID, kind: .export, pages: saved.pagesScanned, files: outputs.count, bytes: bytes))
        return ScanJobResult(outputURLs: outputs, pagesScanned: saved.pagesScanned, outputByteCount: bytes)
    }

    /// Runs ocrmypdf on the exported PDFs when Settings ▸ Language enables it.
    /// A failure keeps the exported files untouched and is reported in the status.
    /// Whether each ocrmypdf found has the Apple Live Text plugin; asking
    /// costs a second of Python start-up, so the answer is kept.
    private var appleOCRAvailability: [URL: Bool] = [:]

    private func hasAppleOCR(_ runner: OCRmyPDFRunner) async -> Bool {
        if let known = appleOCRAvailability[runner.executableURL] { return known }
        let available = await runner.hasAppleOCR()
        appleOCRAvailability[runner.executableURL] = available
        return available
    }

    private func runOCRmyPDFIfEnabled(on outputs: [URL], startedAt: Date) async {
        let pdfs = outputs.filter { $0.pathExtension.lowercased() == "pdf" }
        guard ocrSettings.runOCRmyPDF, !pdfs.isEmpty else { return }
        guard let runner = OCRmyPDFRunner.locate(customPath: ocrSettings.ocrmypdfPath) else {
            log("ocrmypdf was not found in \(OCRmyPDFRunner.searchDirectories.joined(separator: ", ")); install it with \"brew install ocrmypdf\" or turn OCR off in Settings.")
            return
        }
        let language = ocrSettings.language
        isRunningOCR = true
        defer { isRunningOCR = false }
        var usesAppleOCR = false
        if ocrSettings.engine != .tesseract {
            usesAppleOCR = await hasAppleOCR(runner)
            if !usesAppleOCR, ocrSettings.engine == .appleLiveText { log("The ocrmypdf-appleocr plugin is not installed next to ocrmypdf; using Tesseract.") }
        }
        let onFile: @MainActor @Sendable (Int, Int, URL) -> Void = { [weak self] file, total, url in
            self?.postScanActivity = .ocrmypdf(file: file, of: total, name: url.lastPathComponent, language: language.displayName, startedAt: startedAt)
        }
        log("Running ocrmypdf (\(usesAppleOCR ? "Apple Live Text" : "Tesseract"), \(language.tesseractCode)) on \(pdfs.count) PDF\(pdfs.count == 1 ? "" : "s")…")
        do {
            let processed: [URL]
            do {
                processed = try await runner.process(pdfs, language: language, usesAppleOCR: usesAppleOCR, onFile: onFile)
            } catch is OCRmyPDFRunner.LiveTextTimeout {
                // macOS may still be preparing its recognition models; the PDFs are untouched.
                log("Apple Live Text did not respond, as happens while macOS prepares its text recognition models; using Tesseract instead.")
                processed = try await runner.process(pdfs, language: language, usesAppleOCR: false, onFile: onFile)
            }
            log("OCR finished for \(processed.map(\.lastPathComponent).joined(separator: ", ")).")
        } catch {
            status = .error(error.localizedDescription)
            log("OCR failed: \(error.localizedDescription)")
        }
    }

    var openWithAppURL: URL? { openWithBundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }

    func chooseOpenWithApp() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.application]; panel.prompt = "Use App"
        panel.directoryURL = openWithAppURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.title = "Choose an App to Open Scans"
        panel.message = "Each saved file will be opened in this app."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { status = .error("\(url.lastPathComponent) cannot be used to open scans."); return }
        openWithBundleID = bundleID
        log("Saved files will open in \(url.deletingPathExtension().lastPathComponent).")
    }

    /// Opens the saved files in the app chosen in the inspector, after OCR
    /// has finished with them. A failure is only logged: the files are saved.
    private func openInChosenApp(_ outputs: [URL]) {
        guard let bundleID = openWithBundleID, !outputs.isEmpty else { return }
        guard let app = openWithAppURL else { log("The app chosen to open scans (\(bundleID)) was not found."); return }
        Task {
            do { _ = try await NSWorkspace.shared.open(outputs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
            catch { log("Could not open the saved files in \(app.deletingPathExtension().lastPathComponent): \(error.localizedDescription)") }
        }
    }

    func clearPages() async { resetPages(); scanInterruption = nil; lastOutputs = []; lastOutputByteCount = 0; await pageStore?.clear(); pageStore = nil; log("Cleared pages and output links.") }
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

    func deleteSelectedPage() async {
        guard let id = selectedPageID, let visibleIndex = pages.firstIndex(where: { $0.id == id }) else { return }
        rawPages.removeAll { $0.id == id }
        processedPages[id] = nil
        pageEdits[id] = nil
        blankPageIDs.remove(id)
        selectedPageID = pages.isEmpty ? nil : pages[min(visibleIndex, pages.count - 1)].id
        log("Deleted page.")
    }
    func movePage(from source: IndexSet, to destination: Int) {
        var visibleIDs = pages.map(\.id)
        visibleIDs.move(fromOffsets: source, toOffset: destination)

        var reorderedVisiblePages = visibleIDs.compactMap { id in rawPages.first { $0.id == id } }
        for index in rawPages.indices where processedPages[rawPages[index].id] != nil {
            rawPages[index] = reorderedVisiblePages.removeFirst()
        }
    }

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
        processingGeneration += 1; pageSession += 1
        rawPages = []; processedPages = [:]; pageEdits = [:]; blankPageIDs = []; selectedPageID = nil; pagesScanned = 0; pageProgress = [:]
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
        let automaticColor = selectedProfile.options.acquisition.colorMode == .automatic
        let generation = processingGeneration
        pendingProcessingCount += 1
        let previous = processingChain
        processingChain = Task { [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) { () -> Result<PageFrame?, Error> in
                Result { try Self.render(raw, settings: settings, automaticColor: automaticColor) }
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

    nonisolated private static func render(_ raw: RawPage, settings: ImageProcessingSettings, automaticColor: Bool) throws -> PageFrame? {
        let frame = try raw.frame()
        return try ScanImageProcessor.process(frame, settings: settings, outputDPI: frame.resolutionDPI, automaticColor: automaticColor)
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
    func isSupported(_ mode: ScanColorMode) -> Bool { capabilities?.supports(mode) ?? (selectedIdentity?.connectionKind == .imageCapture) }
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
        if !capabilities.supportsScannerBuffering { profile.options.acquisition.scannerBuffering = false }
        if !capabilities.supportsHardwareCompression { profile.options.acquisition.hardwareCompression = false }
        if profile != selectedProfile { updateProfile(profile) }
    }
    private func persistProfiles() { profileStore.save(profiles) }
    private func persistDestinationBookmark() {
        do { try destinationStore.save(destinationFolder) }
        catch { log("Could not remember destination \(destinationFolder.path) for the next launch: \(error.localizedDescription)") }
    }
    func resetDestination() {
        destinationStore.reset()
        destinationFolder = DestinationFolderStore.defaultFolder
        log("Destination reset to \(destinationFolder.path).")
    }
    private func log(_ message: String) { ScanSystemLog.write(message); let formatter = DateFormatter(); formatter.timeStyle = .medium; activityLog.insert("[\(formatter.string(from: Date()))] \(message)", at: 0); activityLog = Array(activityLog.prefix(100)) }
}
