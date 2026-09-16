import Foundation
import XCTest
@testable import Scan

/// Pins the exact USB command sequence of the native ScanSnap drivers against
/// recorded fixtures, using `FujitsuScriptedTransport` instead of hardware.
///
/// The S1500 fixtures were recorded from the original, hardware-validated
/// driver (commit 7a27cf8) running against the same scripted transport, so a
/// passing test proves the shared engine still sends byte-identical commands
/// for that model. The iX500 fixtures pin the current behaviour that was
/// validated on hardware.
final class FujitsuCommandTranscriptTests: XCTestCase {
    struct Scenario {
        let name: String
        let options: ScanOptions
        let pixelWidth: Int
        let sheets: Int
        let expectsFeederEmpty: Bool

        init(_ name: String, source: ScanSource, mode: ScanColorMode, dpi: Int, sheets: Int, autoCrop: Bool = false, buffering: Bool = false, hardwareJPEG: Bool = false, expectsFeederEmpty: Bool = false) {
            self.name = name
            var options = ScanOptions(
                acquisition: AcquisitionSettings(source: source, colorMode: mode, resolutionDPI: dpi, scannerBuffering: buffering, hardwareCompression: hardwareJPEG),
                processing: ImageProcessingSettings(autoCrop: autoCrop)
            )
            options.export.jpegQuality = 0.82
            self.options = options
            self.pixelWidth = Int(8.5 * Double(dpi))
            self.sheets = sheets
            self.expectsFeederEmpty = expectsFeederEmpty
        }
    }

    static let s1500Scenarios: [Scenario] = [
        Scenario("s1500-front-gray-300", source: .adfFront, mode: .gray, dpi: 300, sheets: 1),
        Scenario("s1500-duplex-color-300-autocrop", source: .adfDuplex, mode: .color, dpi: 300, sheets: 1, autoCrop: true),
        Scenario("s1500-front-lineart-150", source: .adfFront, mode: .lineart, dpi: 150, sheets: 1),
        Scenario("s1500-back-color-200-two-sheets", source: .adfBack, mode: .color, dpi: 200, sheets: 2),
        Scenario("s1500-empty-feeder", source: .adfDuplex, mode: .color, dpi: 300, sheets: 0, expectsFeederEmpty: true)
    ]

    static let ix500Scenarios: [Scenario] = [
        Scenario("ix500-duplex-color-300-buffer", source: .adfDuplex, mode: .color, dpi: 300, sheets: 1, autoCrop: true, buffering: true),
        Scenario("ix500-front-gray-150", source: .adfFront, mode: .gray, dpi: 150, sheets: 1),
        Scenario("ix500-empty-feeder", source: .adfFront, mode: .color, dpi: 300, sheets: 0, expectsFeederEmpty: true)
    ]

    static let identity = identity(productID: 0x11a2)

    static func identity(productID: UInt16) -> ScannerIdentity {
        ScannerIdentity(
            name: "Scripted ScanSnap", manufacturer: "Fujitsu", model: String(format: "0x%04x", productID), serialNumber: "SCRIPT",
            connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: productID), locationID: 1
        )
    }

    /// Protocol-backed models whose colour and gray flow is the S1500's: RGB is
    /// accepted on the first interlace probe and every best-effort step
    /// succeeds, so they must reproduce the S1500 fixtures byte for byte. The
    /// fi-5530C is left out because it sends the 256-entry gamma table.
    static let s1500CompatibleModels: [(driver: ScannerDriver, productID: UInt16)] = [
        (FujitsuScanSnapS1500Driver(), 0x10f2), // ScanSnap fi-5110EOXM
        (FujitsuFiSeriesDriver(), 0x10e0),      // fi-5x20C
        (FujitsuFiSeriesDriver(), 0x114f),      // fi-6130
        (FujitsuFiSeriesDriver(), 0x11f2)       // fi-6240Z
    ]

    /// Runs one scenario through `driver` and returns the transport transcript.
    static func transcript(
        driver: ScannerDriver,
        scenario: Scenario,
        identity: ScannerIdentity = FujitsuCommandTranscriptTests.identity,
        rejectsGammaTable: Bool = false
    ) async throws -> [String] {
        let transport = FujitsuScriptedTransport(
            identity: identity, pixelWidth: scenario.pixelWidth, pixelHeight: 8, sheets: scenario.sheets, rejectsGammaTable: rejectsGammaTable
        )
        let device = driver.makeDevice(identity: identity, transport: transport)
        try await device.open()
        var pages = 0
        do {
            let stream = try await device.startScan(options: scenario.options)
            for try await _ in stream { pages += 1 }
            if scenario.expectsFeederEmpty {
                XCTFail("\(scenario.name): expected the empty-feeder error")
            }
        } catch let error as ScannerError where error == .feederEmpty && scenario.expectsFeederEmpty {
            // expected
        }
        await device.close()
        if !scenario.expectsFeederEmpty {
            let expectedPages = scenario.sheets * (scenario.options.source == .adfDuplex ? 2 : 1)
            XCTAssertEqual(pages, expectedPages, "\(scenario.name): page count")
        }
        return transport.transcript
    }

    static func fixtureURL(_ name: String) -> URL? {
        Bundle(for: FujitsuCommandTranscriptTests.self).url(forResource: name, withExtension: "transcript")
    }

    private func assertMatchesFixture(driver: ScannerDriver, scenario: Scenario, identity: ScannerIdentity = FujitsuCommandTranscriptTests.identity) async throws {
        guard let url = Self.fixtureURL(scenario.name) else {
            return XCTFail("Missing fixture \(scenario.name).transcript in the test bundle")
        }
        let expected = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let actual = try await Self.transcript(driver: driver, scenario: scenario, identity: identity)

        if actual != expected {
            let firstDifference = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actual.count, expected.count)
            let context = { (lines: [String]) -> String in
                lines[max(0, firstDifference - 2)..<min(lines.count, firstDifference + 2)].map { String($0.prefix(120)) }.joined(separator: "\n    ")
            }
            XCTFail("""
            \(scenario.name) (\(identity.model)): command transcript differs at entry \(firstDifference) (actual \(actual.count) entries, fixture \(expected.count)).
              actual:
                \(context(actual))
              fixture:
                \(context(expected))
            """)
        }
    }

    func testS1500CommandSequencesMatchTheOriginalDriver() async throws {
        for scenario in Self.s1500Scenarios {
            try await assertMatchesFixture(driver: FujitsuScanSnapS1500Driver(), scenario: scenario)
        }
    }

    func testIX500CommandSequencesArePinned() async throws {
        for scenario in Self.ix500Scenarios {
            try await assertMatchesFixture(driver: FujitsuScanSnapIX500Driver(), scenario: scenario)
        }
    }

    func testIX1500UsesGenericColorFlowForColorAndSoftwareGray() async throws {
        let driver = await FujitsuScanSnapIX1500Driver()
        let identity = Self.identity(productID: 0x159f)
        let color = Scenario("ix1500-color", source: .adfDuplex, mode: .color, dpi: 300, sheets: 1, autoCrop: true)
        let gray = Scenario("ix1500-gray", source: .adfDuplex, mode: .gray, dpi: 300, sheets: 1, autoCrop: true)

        let colorTranscript = try await Self.transcript(driver: driver, scenario: color, identity: identity)
        let grayTranscript = try await Self.transcript(driver: driver, scenario: gray, identity: identity)

        // Gray conversion happens after acquisition, so the scanner receives
        // the same color command sequence for both requests.
        XCTAssertEqual(grayTranscript, colorTranscript)

        let wrapperPrefix = "W 43" + String(repeating: "00", count: 0x12)
        XCTAssertFalse(colorTranscript.contains { $0.hasPrefix(wrapperPrefix + "1d") }, "iX500 diagnostic pre-read must stay disabled")
        XCTAssertFalse(colorTranscript.contains { $0.hasPrefix(wrapperPrefix + "2a0088") }, "iX500 JPEG table must stay disabled")
        XCTAssertFalse(colorTranscript.contains { $0.hasPrefix(wrapperPrefix + "c2") }, "iX500 hopper check must stay disabled")
    }

    func testProtocolBackedModelsReproduceTheS1500ColorAndGraySequences() async throws {
        for model in Self.s1500CompatibleModels {
            for scenario in Self.s1500Scenarios where scenario.options.colorMode != .lineart {
                try await assertMatchesFixture(driver: model.driver, scenario: scenario, identity: Self.identity(productID: model.productID))
            }
        }
    }

    func testProtocolBackedModelsContinueWhenTheGammaTableIsRejected() async throws {
        let scenario = Scenario("fi6130-gamma-rejected", source: .adfDuplex, mode: .color, dpi: 300, sheets: 1)
        // transcript() asserts that both sides of the sheet are delivered.
        let transcript = try await Self.transcript(
            driver: FujitsuFiSeriesDriver(), scenario: scenario, identity: Self.identity(productID: 0x114f), rejectsGammaTable: true
        )
        let wrapperPrefix = "W 43" + String(repeating: "00", count: 0x12)
        let gammaIndex = try XCTUnwrap(transcript.firstIndex { $0.hasPrefix(wrapperPrefix + "2a0083") })
        // Table payload, failed status, then REQUEST SENSE before the scan continues.
        XCTAssertEqual(transcript[gammaIndex + 2], "R 13")
        XCTAssertTrue(transcript[gammaIndex + 3].hasPrefix(wrapperPrefix + "03"))
    }

    func testValidatedS1500StillAbortsWhenTheGammaTableIsRejected() async throws {
        let scenario = Scenario("s1500-gamma-rejected", source: .adfFront, mode: .color, dpi: 300, sheets: 1)
        let transport = FujitsuScriptedTransport(identity: Self.identity, pixelWidth: scenario.pixelWidth, pixelHeight: 8, sheets: 1, rejectsGammaTable: true)
        let device = FujitsuScanSnapS1500Driver().makeDevice(identity: Self.identity, transport: transport)
        try await device.open()
        do {
            let stream = try await device.startScan(options: scenario.options)
            for try await _ in stream {}
            XCTFail("The S1500 must not scan with a rejected gamma table")
        } catch {
            XCTAssertNotEqual(error as? ScannerError, .feederEmpty)
        }
        await device.close()
    }
}
