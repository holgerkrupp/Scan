import AppKit
import XCTest
@testable import Scan

/// The view model saves the pages scanned before a failure.
@MainActor
final class PartialScanSaveTests: XCTestCase {
    private func makeWorkspace(driver: ScannerDriver) throws -> ScannerWorkspaceViewModel {
        let suiteName = "PartialScanSaveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).json"))
        }
        return ScannerWorkspaceViewModel(discovery: JamDiscovery(), registry: ScannerDriverRegistry(drivers: [driver]), outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: defaults), automaticRefreshDelay: .milliseconds(20), statisticsStore: ScanStatisticsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).json"), defaults: defaults))
    }

    private func makeDestination() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PartialScanSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHardwareScanSavesPagesBeforeAJam() async throws {
        let workspace = try makeWorkspace(driver: JammingDriver(pagesBeforeJam: 2))
        let destination = try makeDestination()
        do {
            _ = try await workspace.scanAndExport(identity: JamDiscovery.scanner, destinationOverride: destination)
            XCTFail("The jam must still be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("saved"), error.localizedDescription)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertFalse(files.isEmpty, "The pages scanned before the jam must be exported")
        XCTAssertEqual(workspace.pages.count, 2)
        XCTAssertFalse(workspace.lastOutputs.isEmpty)
    }

    func testInteractiveScanWithoutAutosaveOnlyKeepsPages() async throws {
        let workspace = try makeWorkspace(driver: JammingDriver(pagesBeforeJam: 1))
        var profile = workspace.selectedProfile
        profile.options.export.automaticallySaveAfterScanning = false
        workspace.updateProfile(profile)
        workspace.selectedIdentity = JamDiscovery.scanner
        let destination = try makeDestination()
        await workspace.startScan(destinationOverride: destination)
        await workspace.waitForProcessing()
        XCTAssertEqual(workspace.pages.count, 1, "Pages stay available for a manual save")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        guard case .error = workspace.status else { return XCTFail("The jam must be shown") }
    }
}

private struct JamDiscovery: ScannerDiscovery {
    static let scanner = ScannerIdentity(name: "Jamming Scanner", manufacturer: "Test", model: "Jam", serialNumber: nil, connectionKind: .imageCapture, usbDeviceID: nil, locationID: nil, persistentID: "jamming-scanner")
    func discover() async -> [ScannerIdentity] { [Self.scanner] }
}

private final class JammingDriver: ScannerDriver {
    let name = "Jamming test driver"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = []
    let pagesBeforeJam: Int
    init(pagesBeforeJam: Int) { self.pagesBeforeJam = pagesBeforeJam }
    func canDrive(_ identity: ScannerIdentity) -> Bool { true }
    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice { JammingDevice(identity: identity, pages: pagesBeforeJam) }
}

/// Delivers `pages` printed pages, then fails like a paper jam.
private final class JammingDevice: ScannerDevice {
    let identity: ScannerIdentity
    let capabilities = ScannerCapabilities(sources: ScanSource.allCases, colorModes: ScanColorMode.allCases, resolutionsDPI: [150, 300, 600], supportsDuplex: true)
    let status: ScannerStatus = .idle
    private let pages: Int
    init(identity: ScannerIdentity, pages: Int) { self.identity = identity; self.pages = pages }
    func open() async throws {}
    func close() async {}
    func cancel() async {}
    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        let frames = try (1...pages).map(Self.printedFrame)
        return AsyncThrowingStream { continuation in
            frames.forEach { continuation.yield($0) }
            continuation.finish(throwing: ScannerError.transportUnavailable("Paper jam."))
        }
    }

    private static func printedFrame(_ index: Int) throws -> PageFrame {
        let width = 600, height = 800
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for line in 0..<12 { context.fill(CGRect(x: 60, y: 100 + line * 50, width: width - 120, height: 6)) }
        let data = try ScanImageProcessor.encodeJPEG(try XCTUnwrap(context.makeImage()), quality: 0.9)
        return PageFrame(pageIndex: index, side: .front, pixelFormat: .jpeg, width: width, height: height, resolutionDPI: 300, data: data)
    }
}
