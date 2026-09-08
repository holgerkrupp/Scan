import AppKit
import Foundation
import ImageCaptureCore

final class ImageCaptureScannerDiscovery: NSObject, ScannerDiscovery, ICDeviceBrowserDelegate {
    private var browser: ICDeviceBrowser?
    private var found: [ScannerIdentity] = []
    private var continuation: CheckedContinuation<[ScannerIdentity], Never>?

    func discover() async -> [ScannerIdentity] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async(execute: {
                self.found = []; self.continuation = continuation
                let browser = ICDeviceBrowser(); browser.delegate = self; browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x102)!; self.browser = browser; browser.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.finish() }
            })
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        found.append(Self.identity(for: scanner))
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) { finish() }

    private func finish() {
        guard let continuation else { return }; self.continuation = nil; browser?.stop(); continuation.resume(returning: found)
    }

    static func identity(for scanner: ICScannerDevice) -> ScannerIdentity {
        ScannerIdentity(name: scanner.name ?? "Image Capture Scanner", manufacturer: "macOS", model: scanner.name ?? "Scanner", serialNumber: scanner.serialNumberString, connectionKind: .imageCapture, usbDeviceID: scanner.usbVendorID == 0 ? nil : USBDeviceID(vendorID: UInt16(truncatingIfNeeded: scanner.usbVendorID), productID: UInt16(truncatingIfNeeded: scanner.usbProductID)), locationID: scanner.usbLocationID == 0 ? nil : UInt32(truncatingIfNeeded: scanner.usbLocationID), persistentID: scanner.persistentIDString ?? scanner.uuidString)
    }
}

final class CompositeScannerDiscovery: ScannerDiscovery {
    private let native: ScannerDiscovery
    private let imageCapture: ScannerDiscovery
    init(native: ScannerDiscovery = USBScannerDiscovery(), imageCapture: ScannerDiscovery = ImageCaptureScannerDiscovery()) { self.native = native; self.imageCapture = imageCapture }
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
    private var browser: ICDeviceBrowser?
    private var scanner: ICScannerDevice?
    private var scanContinuation: AsyncThrowingStream<PageFrame, Error>.Continuation?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var pageIndex = 0
    private var cancelled = false

    init(identity: ScannerIdentity) {
        self.identity = identity
        capabilities = ScannerCapabilities(sources: [.adfFront, .flatbed], colorModes: [.color, .gray, .lineart], resolutionsDPI: [75, 150, 200, 300, 600], supportsBlankPageRemoval: true, supportsDeskew: true, supportsAutoCrop: true, supportsAutoRotate: true, supportsDuplex: false)
    }

    func open() async throws {
        let scanner = try await locateScanner()
        self.scanner = scanner; scanner.delegate = self
        try await requestOpen(scanner)
        updateCapabilities(from: scanner)
        status = .idle
    }

    func close() async { if let scanner { try? await scanner.requestCloseSession() }; browser?.stop(); scanner = nil; browser = nil; status = .disconnected }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        try capabilities.validate(options); guard let scanner else { throw ScannerError.transportUnavailable("Image Capture scanner session is not open.") }
        let unit = scanner.selectedFunctionalUnit
        if options.source == .flatbed { scanner.requestSelect(.flatbed) } else { scanner.requestSelect(.documentFeeder) }
        unit.resolution = options.resolutionDPI; unit.pixelDataType = options.colorMode == .color ? .RGB : (options.colorMode == .gray ? .gray : .BW)
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder { feeder.duplexScanningEnabled = options.source == .adfDuplex }
        scanner.transferMode = .fileBased; scanner.downloadsDirectory = FileManager.default.temporaryDirectory; scanner.documentUTI = "public.tiff"
        cancelled = false; pageIndex = 0; status = .scanning(progress: nil, pagesScanned: 0)
        return AsyncThrowingStream { continuation in self.scanContinuation = continuation; scanner.requestScan() }
    }

    func cancel() async { cancelled = true; scanner?.cancelScan(); scanContinuation?.finish(throwing: ScannerError.scanCancelled); scanContinuation = nil; status = .idle }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        guard !cancelled, let data = try? Data(contentsOf: url), let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        pageIndex += 1; let frame = PageFrame(pageIndex: pageIndex, side: .front, pixelFormat: .tiff, width: cgImage.width, height: cgImage.height, resolutionDPI: scanner.selectedFunctionalUnit.resolution, data: data); scanContinuation?.yield(frame); status = .scanning(progress: Double(scanner.selectedFunctionalUnit.scanProgressPercentDone), pagesScanned: pageIndex)
    }
    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) { if cancelled { scanContinuation?.finish(throwing: ScannerError.scanCancelled) } else if let error { status = .error(error.localizedDescription); scanContinuation?.finish(throwing: error) } else { status = .idle; scanContinuation?.finish() }; scanContinuation = nil }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { if let error { openContinuation?.resume(throwing: error) } else { openContinuation?.resume() }; openContinuation = nil }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) {}
    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {}

    private func locateScanner() async throws -> ICScannerDevice {
        let browser = ICDeviceBrowser(); let delegate = ImageCaptureDelegate(); self.browser = browser; browser.delegate = delegate; browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x102)!; browser.start(); try await Task.sleep(for: .milliseconds(700)); browser.stop()
        guard let device = (browser.devices ?? []).compactMap({ $0 as? ICScannerDevice }).first(where: { ImageCaptureScannerDiscovery.identity(for: $0).id == identity.id || ($0.serialNumberString != nil && $0.serialNumberString == identity.serialNumber) }) else { throw ScannerError.deviceNotFound }; return device
    }
    private func requestOpen(_ scanner: ICScannerDevice) async throws { try await withCheckedThrowingContinuation { continuation in openContinuation = continuation; scanner.requestOpenSession() } }
    private func updateCapabilities(from scanner: ICScannerDevice) {
        var sources: [ScanSource] = []
        if scanner.availableFunctionalUnitTypes.contains(where: { $0.intValue == 0 }) { sources.append(.flatbed) }
        if let feeder = scanner.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder {
            sources.append(feeder.supportsDuplexScanning ? .adfDuplex : .adfFront)
            if feeder.supportsDuplexScanning { sources.append(.adfBack) }
        }
        let dpi = scanner.selectedFunctionalUnit.supportedResolutions.map { $0 }
        let area = scanner.selectedFunctionalUnit.scanArea
        capabilities = ScannerCapabilities(sources: sources.isEmpty ? [.adfFront] : sources, colorModes: [.color, .gray, .lineart], resolutionsDPI: dpi.isEmpty ? [75, 150, 200, 300, 600] : dpi, scanArea: .init(width: Double(area.size.width), height: Double(area.size.height), unit: "scanner units"), supportsBlankPageRemoval: true, supportsDeskew: true, supportsAutoCrop: true, supportsAutoRotate: true, supportsDuplex: sources.contains(.adfDuplex))
    }
}

private final class ImageCaptureDelegate: NSObject, ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {}
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
}
