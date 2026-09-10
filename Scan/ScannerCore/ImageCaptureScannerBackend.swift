import AppKit
import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

/// Long-lived ownership of Image Capture discovery. `ICDeviceBrowser` and its
/// delegate are non-retaining, so a short-lived browser is not a reliable way
/// to obtain a device that will subsequently be opened for scanning.
final class ImageCaptureScannerDiscovery: NSObject, ScannerDiscovery, ICDeviceBrowserDelegate {
    static let shared = ImageCaptureScannerDiscovery()

    private var browser: ICDeviceBrowser?
    private var devices: [String: ICScannerDevice] = [:]
    private var continuation: CheckedContinuation<[ScannerIdentity], Never>?
    private var didEnumerateLocalDevices = false
    private var onChange: (@MainActor () -> Void)?

    /// Scanner plus every Image Capture location. The browser notifies local
    /// completion first; remote devices remain observable in the live cache.
    private static let scannerMask = ICDeviceTypeMask(rawValue:
        ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.bluetooth.rawValue
    )!

    func discover() async -> [ScannerIdentity] {
        await withCheckedContinuation { continuation in
            dispatchPrecondition(condition: .onQueue(.main))
            self.continuation?.resume(returning: identities)
            self.continuation = continuation
            startIfNeeded()
            if didEnumerateLocalDevices { finishSnapshot() }
        }
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        startIfNeeded()
    }

    func scanner(matching identity: ScannerIdentity) -> ICScannerDevice? {
        if let scanner = devices[identity.id] { return scanner }
        return devices.values.first(where: { candidate in
            let candidateIdentity = Self.identity(for: candidate)
            return candidateIdentity.persistentID == identity.persistentID
                || (identity.serialNumber != nil && candidateIdentity.serialNumber == identity.serialNumber)
        })
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        devices[Self.identity(for: scanner).id] = scanner
        notifyChangeAfterEnumeration()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        devices.removeValue(forKey: Self.identity(for: scanner).id)
        notifyChangeAfterEnumeration()
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        didEnumerateLocalDevices = true
        finishSnapshot()
    }

    @MainActor private var identities: [ScannerIdentity] {
        devices.values.map(Self.identity(for:)).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func startIfNeeded() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = Self.scannerMask
        self.browser = browser
        browser.start()
    }

    /// Devices reported during the initial enumeration belong to the first
    /// snapshot; only later additions and removals are changes.
    private func notifyChangeAfterEnumeration() {
        if didEnumerateLocalDevices { onChange?() }
    }

    private func finishSnapshot() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: identities)
    }

    static func identity(for scanner: ICScannerDevice) -> ScannerIdentity {
        ScannerIdentity(
            name: scanner.name ?? "Image Capture Scanner",
            manufacturer: scanner.transportType ?? "Image Capture",
            model: scanner.productKind ?? "Scanner",
            serialNumber: scanner.serialNumberString,
            connectionKind: .imageCapture,
            usbDeviceID: scanner.usbVendorID == 0 ? nil : USBDeviceID(vendorID: UInt16(truncatingIfNeeded: scanner.usbVendorID), productID: UInt16(truncatingIfNeeded: scanner.usbProductID)),
            locationID: scanner.usbLocationID == 0 ? nil : UInt32(truncatingIfNeeded: scanner.usbLocationID),
            persistentID: scanner.persistentIDString ?? scanner.uuidString
        )
    }
}

final class CompositeScannerDiscovery: ScannerDiscovery {
    private let native: ScannerDiscovery
    private let imageCapture: ScannerDiscovery
    init(native: ScannerDiscovery = USBScannerDiscovery(), imageCapture: ScannerDiscovery = ImageCaptureScannerDiscovery.shared) { self.native = native; self.imageCapture = imageCapture }
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        native.observeChanges(onChange)
        imageCapture.observeChanges(onChange)
    }
    func discover() async -> [ScannerIdentity] {
        let (nativeDevices, imageCaptureDevices) = await (native.discover(), imageCapture.discover())
        var result = nativeDevices
        for candidate in imageCaptureDevices {
            let duplicate = result.contains { existing in
                if let a = existing.usbDeviceID, let b = candidate.usbDeviceID, a == b { return existing.serialNumber == candidate.serialNumber || existing.locationID == candidate.locationID || (existing.serialNumber == nil && candidate.serialNumber == nil && existing.locationID == nil && candidate.locationID == nil) }
                return existing.serialNumber != nil && existing.serialNumber == candidate.serialNumber && existing.manufacturer == candidate.manufacturer
            }
            if !duplicate { result.append(candidate) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ImageCaptureScannerDriver: ScannerDriver {
    let name = "Apple Image Capture scanner backend"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = []
    func canDrive(_ identity: ScannerIdentity) -> Bool { identity.connectionKind == .imageCapture }
    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice { ImageCaptureScannerDevice(identity: identity) }
}

final class ImageCaptureScannerDevice: NSObject, ScannerDevice, ICScannerDeviceDelegate {
    let identity: ScannerIdentity
    private(set) var capabilities: ScannerCapabilities
    private(set) var status: ScannerStatus = .disconnected
    private var scanner: ICScannerDevice?
    private var scanContinuation: AsyncThrowingStream<PageFrame, Error>.Continuation?
    private var selectionContinuation: CheckedContinuation<ICScannerFunctionalUnit, Error>?
    private var pageIndex = 0
    private var cancelled = false
    private var activeSource: ScanSource?
    private var transferDirectory: URL?

    init(identity: ScannerIdentity) {
        self.identity = identity
        // Concrete capabilities are available only after opening the device and
        // selecting each of its functional units.
        capabilities = ScannerCapabilities(sources: [], colorModes: ScanColorMode.allCases, resolutionsDPI: [], supportsBlankPageRemoval: true, supportsDeskew: true, supportsAutoCrop: true, supportsAutoRotate: true, supportsDuplex: false)
    }

    func open() async throws {
        guard let scanner = ImageCaptureScannerDiscovery.shared.scanner(matching: identity) else { throw ScannerError.deviceNotFound }
        self.scanner = scanner
        scanner.delegate = self
        do {
            try await scanner.requestOpenSession(options: nil)
            try await updateCapabilities(from: scanner)
            status = .idle
        } catch {
            scanner.delegate = nil
            self.scanner = nil
            throw error
        }
    }

    func close() async {
        guard let scanner else { return }
        if scanner.hasOpenSession { try? await scanner.requestCloseSession(options: nil) }
        scanner.delegate = nil
        self.scanner = nil
        selectionContinuation = nil
        activeSource = nil
        if let transferDirectory { try? FileManager.default.removeItem(at: transferDirectory) }
        transferDirectory = nil
        status = .disconnected
    }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        guard let scanner else { throw ScannerError.transportUnavailable("Image Capture scanner session is not open.") }
        let unit = try await select(functionalUnitFor: options.source, scanner: scanner)
        try validate(options: options, for: unit)
        configure(unit: unit, with: options)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Scan-ImageCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transferDirectory = directory
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = directory
        scanner.documentName = "Scan-\(UUID().uuidString)"
        scanner.documentUTI = UTType.tiff.identifier

        cancelled = false
        pageIndex = 0
        activeSource = options.source
        status = .scanning(progress: nil, pagesScanned: 0)
        return AsyncThrowingStream { continuation in
            self.scanContinuation = continuation
            scanner.requestScan()
        }
    }

    func cancel() async {
        cancelled = true
        scanner?.cancelScan()
        status = .idle
        finishScan(throwing: ScannerError.scanCancelled)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard !cancelled else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ScannerError.outputFailed("Image Capture delivered an unreadable scan at \(url.lastPathComponent).")
            }
            pageIndex += 1
            let frame = PageFrame(pageIndex: pageIndex, side: activeSource == .adfDuplex ? .unknown : .front, pixelFormat: pixelFormat(for: url), width: cgImage.width, height: cgImage.height, resolutionDPI: Int(scanner.selectedFunctionalUnit.resolution), data: data)
            scanContinuation?.yield(frame)
            status = .scanning(progress: Self.normalizedProgress(Double(scanner.selectedFunctionalUnit.scanProgressPercentDone)), pagesScanned: pageIndex)
        } catch {
            status = .error(error.localizedDescription)
            finishScan(throwing: error)
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        if cancelled { finishScan(throwing: ScannerError.scanCancelled) }
        else if let error { status = .error(error.localizedDescription); finishScan(throwing: error) }
        else { finishScan() }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        guard let continuation = selectionContinuation else { return }
        selectionContinuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: functionalUnit) }
    }

    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) { status = .idle }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { if let error { status = .error(error.localizedDescription) } }
    func didRemove(_ device: ICDevice) { status = .disconnected; finishScan(throwing: ScannerError.deviceNotFound) }
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard let error else { return }
        status = .error(error.localizedDescription)
        finishScan(throwing: error)
    }

    private func updateCapabilities(from scanner: ICScannerDevice) async throws {
        let originalType = scanner.selectedFunctionalUnit.type
        let available = Set(scanner.availableFunctionalUnitTypes.map { ICScannerFunctionalUnitType(rawValue: $0.uintValue) })
        var sources: [ScanSource] = []
        var resolutionsBySource: [ScanSource: [Int]] = [:]
        var area: ScannerCapabilities.ScanArea?

        if available.contains(.flatbed) {
            let unit = try await select(.flatbed, scanner: scanner)
            sources.append(.flatbed)
            let resolutions: [Int] = unit.supportedResolutions.map { $0 }
            resolutionsBySource[.flatbed] = resolutions.sorted()
            area = scanArea(for: unit)
        }
        if available.contains(.documentFeeder) {
            let unit = try await select(.documentFeeder, scanner: scanner)
            let resolutions: [Int] = unit.supportedResolutions.map { $0 }
            sources.append(.adfFront)
            resolutionsBySource[.adfFront] = resolutions
            if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder, feeder.supportsDuplexScanning {
                sources.append(.adfDuplex)
                resolutionsBySource[.adfDuplex] = resolutions
            }
            area = area ?? scanArea(for: unit)
        }
        if available.contains(originalType) { _ = try await select(originalType, scanner: scanner) }

        capabilities = ScannerCapabilities(sources: sources, colorModes: ScanColorMode.allCases, resolutionsDPI: Array(Set(resolutionsBySource.values.flatMap { $0 })).sorted(), resolutionsBySource: resolutionsBySource, scanArea: area, supportsBlankPageRemoval: true, supportsDeskew: true, supportsAutoCrop: true, supportsAutoRotate: true, supportsDuplex: sources.contains(.adfDuplex))
    }

    private func select(functionalUnitFor source: ScanSource, scanner: ICScannerDevice) async throws -> ICScannerFunctionalUnit {
        switch source {
        case .flatbed: return try await select(.flatbed, scanner: scanner)
        case .adfFront, .adfDuplex: return try await select(.documentFeeder, scanner: scanner)
        case .adfBack: throw ScannerError.unsupportedOption("Image Capture does not expose an ADF-back-only functional unit. Use ADF Duplex and retain the returned pages.")
        }
    }

    private func select(_ type: ICScannerFunctionalUnitType, scanner: ICScannerDevice) async throws -> ICScannerFunctionalUnit {
        if scanner.selectedFunctionalUnit.type == type { return scanner.selectedFunctionalUnit }
        return try await withCheckedThrowingContinuation { continuation in
            selectionContinuation = continuation
            scanner.requestSelect(type)
        }
    }

    private func configure(unit: ICScannerFunctionalUnit, with options: ScanOptions) {
        unit.resolution = options.resolutionDPI
        switch options.colorMode { case .color: unit.pixelDataType = .RGB; case .gray: unit.pixelDataType = .gray; case .lineart: unit.pixelDataType = .BW }
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder { feeder.duplexScanningEnabled = options.source == .adfDuplex }
    }

    private func validate(options: ScanOptions, for unit: ICScannerFunctionalUnit) throws {
        try capabilities.validate(options)
        guard unit.supportedResolutions.contains(options.resolutionDPI) else { throw ScannerError.unsupportedOption("Resolution \(options.resolutionDPI) dpi is not supported by the selected Image Capture unit.") }
        let supportsDuplex = (unit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning ?? false
        if options.source == .adfDuplex, !supportsDuplex { throw ScannerError.unsupportedOption("Duplex scanning is not supported by the selected Image Capture feeder.") }
    }

    private func finishScan(throwing error: Error? = nil) {
        guard let continuation = scanContinuation else { return }
        scanContinuation = nil
        activeSource = nil
        if let error { continuation.finish(throwing: error) }
        else { status = .idle; continuation.finish() }
    }

    private func scanArea(for unit: ICScannerFunctionalUnit) -> ScannerCapabilities.ScanArea {
        let area = unit.scanArea
        return .init(width: Double(area.size.width), height: Double(area.size.height), unit: measurementUnitName(unit.measurementUnit))
    }

    private func measurementUnitName(_ unit: ICScannerMeasurementUnit) -> String {
        switch unit { case .inches: "inches"; case .centimeters: "centimeters"; case .picas: "picas"; case .points: "points"; case .twips: "twips"; case .pixels: "pixels"; @unknown default: "scanner units" }
    }

    private func pixelFormat(for url: URL) -> PagePixelFormat {
        switch (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) { case .some(.jpeg): .jpeg; case .some(.png): .png; case .some(.tiff): .tiff; default: .unknown }
    }

    static func normalizedProgress(_ percentage: Double) -> Double {
        min(max(percentage / 100, 0), 1)
    }
}
