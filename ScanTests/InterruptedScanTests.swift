import AppKit
import XCTest
@testable import Scan

/// A sheet that the iX500 does not pick up (inserted moments before the
/// hardware button) and a scan that ends in a paper jam. Driven through
/// `FujitsuScriptedTransport` and a fake device; no hardware involved.
@MainActor final class InterruptedScanTests: XCTestCase {
    private let identity = FujitsuCommandTranscriptTests.identity(productID: 0x132b)
    private let wrapperPrefix = "W 43" + String(repeating: "00", count: 0x12)

    private func makeDevice(_ transport: FujitsuScriptedTransport) -> FujitsuScanSnapDevice {
        let device = FujitsuScanSnapIX500Driver().makeDevice(identity: identity, transport: transport) as! FujitsuScanSnapDevice
        device.feedSettingsProvider = { _ in ScannerFeedSettings() }
        return device
    }

    private func scan(_ device: FujitsuScanSnapDevice, pages: inout Int) async throws {
        let options = ScanOptions(acquisition: AcquisitionSettings(source: .adfFront, colorMode: .color, resolutionDPI: 300))
        for try await _ in try await device.startScan(options: options) { pages += 1 }
    }

    private func commands(_ transport: FujitsuScriptedTransport, prefix: String) -> [Int] {
        transport.transcript.indices.filter { transport.transcript[$0].hasPrefix(wrapperPrefix + prefix) }
    }

    func testUnpickedFirstSheetIsFedAgainWithoutHalting() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 1)
        transport.unpickedFeeds = 1
        let device = makeDevice(transport)
        try await device.open()
        var pages = 0
        try await scan(device, pages: &pages)
        await device.close()

        XCTAssertEqual(pages, 1)
        let feeds = commands(transport, prefix: "3101")
        XCTAssertEqual(feeds.count, 3, "unpicked feed, real feed, empty-feeder feed")
        let halts = commands(transport, prefix: "3104")
        XCTAssertTrue(halts.isEmpty, "The motor must not be halted between the two feeds")
    }

    func testRepeatedUnpickedFeedsAreRetriedSeveralTimes() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 1)
        transport.unpickedFeeds = 3
        let device = makeDevice(transport)
        try await device.open()
        var pages = 0
        try await scan(device, pages: &pages)
        await device.close()
        XCTAssertEqual(pages, 1)
    }

    func testPaperJamKeepsSheetsTransferredBeforeIt() async throws {
        let transport = FujitsuScriptedTransport(identity: identity, pixelWidth: 2550, pixelHeight: 8, sheets: 3)
        transport.jamsOnSheet = 2
        let device = makeDevice(transport)
        try await device.open()
        var pages = 0
        do {
            try await scan(device, pages: &pages)
            XCTFail("A paper jam must end the scan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Paper jam"), error.localizedDescription)
        }
        await device.close()
        XCTAssertEqual(pages, 1, "Sheet 1 was complete and must still be delivered")
    }
}
