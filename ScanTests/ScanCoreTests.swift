import AppKit
import XCTest
@testable import Scan

@MainActor
final class ScanCoreTests: XCTestCase {
    func testSizePresetMappingIsDocumentedAndStable() {
        XCTAssertEqual(ScanFileSizePreset.small.documentedMapping.outputDPI, 150)
        XCTAssertEqual(ScanFileSizePreset.small.documentedMapping.colorMode, .gray)
        XCTAssertEqual(ScanFileSizePreset.balanced.documentedMapping.outputDPI, 200)
        XCTAssertEqual(ScanFileSizePreset.highQuality.documentedMapping.quality, 0.92)
        XCTAssertTrue(ScanFileSizePreset.lossless.documentedMapping.lossless)
        var options = ScanOptions(); options.applyPreset(.small)
        XCTAssertEqual(options.acquisition.colorMode, .gray); XCTAssertEqual(options.export.outputDPI, 150)
    }

    func testCapabilityFilteringRejectsUnsupportedOptions() {
        let capabilities = ScannerCapabilities(sources: [.adfFront], colorModes: [.gray], resolutionsDPI: [200], outputFormats: [.png], supportsBlankPageRemoval: false, supportsDeskew: false, supportsAutoCrop: false, supportsAutoRotate: false, supportsDuplex: false)
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .color, resolutionDPI: 300))
        XCTAssertThrowsError(try capabilities.validate(options))
        options.acquisition = AcquisitionSettings(source: .adfFront, colorMode: .gray, resolutionDPI: 200); options.export.outputFormat = .pdf
        XCTAssertThrowsError(try capabilities.validate(options))
    }

    func testProfilePersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "ScanCoreTests-\(UUID().uuidString)")!
        var store = ScanProfileStore(defaults: defaults); var profile = ScanProfile.defaults[0]; profile.name = "Test profile"; store.save([profile]); store.selectedProfileID = profile.id
        XCTAssertEqual(store.load().first?.name, "Test profile"); XCTAssertEqual(store.selectedProfileID, profile.id)
    }

    func testBlankPageDetectionAndJPEGDownsampling() throws {
        let blank = try makeFrame(pageIndex: 1, blank: true, width: 600, height: 800)
        let printed = try makeFrame(pageIndex: 2, blank: false, width: 600, height: 800)
        guard let image = NSImage(data: printed.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return XCTFail("image") }
        XCTAssertTrue(ScanImageProcessor.isBlank(try XCTUnwrap(NSImage(data: blank.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        XCTAssertFalse(ScanImageProcessor.isBlank(image))
        let settings = ImageProcessingSettings(); let downsampled = try XCTUnwrap(ScanImageProcessor.process(printed, settings: settings, outputDPI: 150))
        XCTAssertEqual(downsampled.width, 300); XCTAssertEqual(downsampled.height, 400); XCTAssertEqual(downsampled.resolutionDPI, 150)
    }

    func testPDFPageCountBlankRemovalAndUniqueFilenames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScanTests-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: folder) }
        let frames = [try makeFrame(pageIndex: 1, blank: false), try makeFrame(pageIndex: 2, blank: true), try makeFrame(pageIndex: 3, blank: false)]
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfFront, colorMode: .color, resolutionDPI: 300), processing: ImageProcessingSettings(removeBlankPages: true), export: ExportSettings(outputFormat: .pdf, sizePreset: .custom, outputDPI: 150, exportMode: .combinedPDF, filenameTemplate: "Fixed"))
        let writer = ScanOutputWriter(); let first = try await writer.write(frames: frames, options: options, destinationFolder: folder); XCTAssertEqual(first.pagesScanned, 2); XCTAssertEqual(first.outputURLs.count, 1); XCTAssertEqual(CGPDFDocument(first.outputURLs[0] as CFURL)?.numberOfPages, 2)
        options.export.exportMode = .separateFiles; let second = try await writer.write(frames: [frames[0]], options: options, destinationFolder: folder); XCTAssertEqual(second.outputURLs.count, 1); XCTAssertNotEqual(first.outputURLs[0].lastPathComponent, second.outputURLs[0].lastPathComponent)
    }

    func testCompositeDiscoveryDeduplicatesNativeS1500InFavorOfNative() async {
        let native = ScannerIdentity(name: "Native S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: "S1", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 7)
        let imageCaptureDuplicate = ScannerIdentity(name: "Image Capture S1500", manufacturer: "macOS", model: "S1500", serialNumber: "S1", connectionKind: .imageCapture, usbDeviceID: native.usbDeviceID, locationID: 7, persistentID: "ic-s1")
        let other = ScannerIdentity(name: "Other Scanner", manufacturer: "Example", model: "Flatbed", serialNumber: "O1", connectionKind: .imageCapture, usbDeviceID: nil, locationID: nil, persistentID: "ic-o1")
        let result = await CompositeScannerDiscovery(native: StaticDiscovery([native]), imageCapture: StaticDiscovery([imageCaptureDuplicate, other])).discover()
        XCTAssertEqual(result.count, 2); XCTAssertTrue(result.contains(native)); XCTAssertFalse(result.contains(imageCaptureDuplicate)); XCTAssertTrue(result.contains(other))
    }

    func testLegacyScanSnapUSBModelsAreClaimedByTheNativeDriver() {
        let driver = FujitsuScanSnapS1500Driver()
        let expected: Set<USBDeviceID> = [
            USBDeviceID(vendorID: 0x04c5, productID: 0x10fe),
            USBDeviceID(vendorID: 0x04c5, productID: 0x1135),
            USBDeviceID(vendorID: 0x04c5, productID: 0x1155),
            USBDeviceID(vendorID: 0x04c5, productID: 0x116f),
            USBDeviceID(vendorID: 0x04c5, productID: 0x11a2),
            USBDeviceID(vendorID: 0x04c5, productID: 0x132b)
        ]
        XCTAssertEqual(driver.supportedUSBDeviceIDs, expected)

        let ix500 = ScannerIdentity(name: "ScanSnap iX500", manufacturer: "Fujitsu", model: "iX500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x132b), locationID: 1)
        let device = driver.makeDevice(identity: ix500, transport: nil)
        XCTAssertEqual(device.capabilities.resolutionsDPI, [150, 200, 300, 600])
        XCTAssertTrue(device.capabilities.supportsDuplex)
    }

    private func makeFrame(pageIndex: Int, blank: Bool, width: Int = 300, height: Int = 400) throws -> PageFrame {
        let image = NSImage(size: NSSize(width: width, height: height)); image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill(); if !blank { NSColor.black.setFill(); NSRect(x: 30, y: 40, width: width - 60, height: 20).fill() }; image.unlockFocus(); let tiff = try XCTUnwrap(image.tiffRepresentation); let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff)); let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])); return PageFrame(pageIndex: pageIndex, side: .front, pixelFormat: .jpeg, width: width, height: height, resolutionDPI: 300, data: data)
    }
}

private struct StaticDiscovery: ScannerDiscovery {
    let identities: [ScannerIdentity]
    init(_ identities: [ScannerIdentity]) { self.identities = identities }
    func discover() async -> [ScannerIdentity] { identities }
}
