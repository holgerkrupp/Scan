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

    /// iX1600 scenarios pinned after hardware validation: native gray and
    /// line-art windows, the hopper check, and scanner buffering.
    static let ix1600Scenarios: [Scenario] = [
        Scenario("ix1600-duplex-color-300-buffer", source: .adfDuplex, mode: .color, dpi: 300, sheets: 1, autoCrop: true, buffering: true),
        Scenario("ix1600-front-gray-150", source: .adfFront, mode: .gray, dpi: 150, sheets: 1),
        Scenario("ix1600-front-lineart-150", source: .adfFront, mode: .lineart, dpi: 150, sheets: 1),
        Scenario("ix1600-empty-feeder", source: .adfFront, mode: .color, dpi: 300, sheets: 0, expectsFeederEmpty: true)
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

    /// The iX1300, iX1400 and iX1500 inherit the iX1600 profile, so all send
    /// the same commands; the flow is SANE's generic one plus the iX500-style
    /// hopper check, without the pre-read or quantisation table.
    func testIX1600CommandSequencesArePinned() async throws {
        for scenario in Self.ix1600Scenarios {
            try await assertMatchesFixture(driver: FujitsuScanSnapIX1600Driver(), scenario: scenario, identity: Self.identity(productID: 0x1632))
        }
    }

    func testIX1x00SiblingsMirrorTheIX1600CommandFlow() async throws {
        let wrapperPrefix = "W 43" + String(repeating: "00", count: 0x12)
        let scenarios = [
            Scenario("ix1x00-duplex-color-300", source: .adfDuplex, mode: .color, dpi: 300, sheets: 1, autoCrop: true),
            Scenario("ix1x00-front-gray-200", source: .adfFront, mode: .gray, dpi: 200, sheets: 1),
            Scenario("ix1x00-front-lineart-150", source: .adfFront, mode: .lineart, dpi: 150, sheets: 1),
            Scenario("ix1x00-duplex-color-400-buffer", source: .adfDuplex, mode: .color, dpi: 400, sheets: 2, autoCrop: true, buffering: true),
            Scenario("ix1x00-empty-feeder", source: .adfFront, mode: .color, dpi: 300, sheets: 0, expectsFeederEmpty: true)
        ]
        for scenario in scenarios {
            let ix1600 = try await Self.transcript(driver: FujitsuScanSnapIX1600Driver(), scenario: scenario, identity: Self.identity(productID: 0x1632))
            let siblings: [(ScannerDriver, UInt16)] = [(FujitsuScanSnapIX1500Driver(), 0x159f), (FujitsuScanSnapIX1300Driver(), 0x162c), (FujitsuScanSnapIX1400Driver(), 0x1630)]
            for (driver, productID) in siblings {
                let sibling = try await Self.transcript(driver: driver, scenario: scenario, identity: Self.identity(productID: productID))
                XCTAssertEqual(sibling, ix1600, "\(scenario.name) \(driver.name)")
            }

            XCTAssertTrue(ix1600.contains { $0.hasPrefix(wrapperPrefix + "c2") }, "\(scenario.name): hopper check")
            XCTAssertFalse(ix1600.contains { $0.hasPrefix(wrapperPrefix + "1d") }, "\(scenario.name): iX500 diagnostic pre-read must stay disabled")
            XCTAssertFalse(ix1600.contains { $0.hasPrefix(wrapperPrefix + "2a0088") }, "\(scenario.name): iX500 JPEG table must stay disabled")
            // Native modes: the window's composition byte follows the request.
            let expectedComposition: UInt8 = switch scenario.options.colorMode { case .lineart: 0; case .gray: 2; case .color: 5 }
            let windowPayload = try XCTUnwrap(ix1600.first { $0.hasPrefix("W ") && $0.count == 2 + 2 * (scenario.options.source == .adfDuplex ? 136 : 72) && $0.hasPrefix("W 0000000000000040") })
            let bytes = stride(from: 2, to: windowPayload.count, by: 2).map { UInt8(windowPayload[windowPayload.index(windowPayload.startIndex, offsetBy: $0)..<windowPayload.index(windowPayload.startIndex, offsetBy: $0 + 2)], radix: 16)! }
            XCTAssertEqual(bytes[8 + 0x19], expectedComposition, "\(scenario.name): composition")
            // Internal gamma curve: window byte 0x29 = 0 and no downloaded table.
            XCTAssertEqual(bytes[8 + 0x29], 0, "\(scenario.name): internal gamma selector")
            XCTAssertFalse(ix1600.contains { $0.hasPrefix(wrapperPrefix + "2a0083") }, "\(scenario.name): no gamma table download")
            if scenario.options.acquisition.scannerBuffering {
                XCTAssertTrue(ix1600.contains { $0 == "W 000000003a06c0c0" + "00000000" }, "\(scenario.name): buffer mode on")
            }

            // SANE's check_for_cancel(): a started batch ends with SCANNER
            // CONTROL cancel after the feeder runs empty; an empty feeder at
            // the start sends neither halt nor cancel.
            let cancels = ix1600.filter { $0.hasPrefix(wrapperPrefix + "f104") }.count
            let halts = ix1600.filter { $0.hasPrefix(wrapperPrefix + "3104") }.count
            XCTAssertEqual(halts, 0, "\(scenario.name): no OBJECT POSITION halt")
            XCTAssertEqual(cancels, scenario.expectsFeederEmpty ? 0 : 1, "\(scenario.name): closing cancel")
            if !scenario.expectsFeederEmpty {
                let cancelIndex = try XCTUnwrap(ix1600.firstIndex { $0.hasPrefix(wrapperPrefix + "f104") })
                let lastFeed = try XCTUnwrap(ix1600.lastIndex { $0.hasPrefix(wrapperPrefix + "3101") })
                XCTAssertGreaterThan(cancelIndex, lastFeed, "\(scenario.name): cancel follows the empty-feeder feed")
            }
        }
    }

    /// The validated S1500 and iX500 sequences must not pick up the SANE
    /// cancel flow: no command after the empty feeder, halt then cancel when
    /// the feeder is empty from the start.
    func testS1500AndIX500KeepTheirBatchEndSequence() async throws {
        let wrapperPrefix = "W 43" + String(repeating: "00", count: 0x12)
        let twoSheets = Scenario("s1500-two-sheets", source: .adfFront, mode: .color, dpi: 200, sheets: 2)
        let s1500 = try await Self.transcript(driver: FujitsuScanSnapS1500Driver(), scenario: twoSheets)
        XCTAssertFalse(s1500.contains { $0.hasPrefix(wrapperPrefix + "f104") })

        let empty = Scenario("ix500-empty", source: .adfFront, mode: .color, dpi: 300, sheets: 0, expectsFeederEmpty: true)
        let ix500 = try await Self.transcript(driver: FujitsuScanSnapIX500Driver(), scenario: empty, identity: Self.identity(productID: 0x132b))
        let halt = try XCTUnwrap(ix500.firstIndex { $0.hasPrefix(wrapperPrefix + "3104") })
        let cancel = try XCTUnwrap(ix500.firstIndex { $0.hasPrefix(wrapperPrefix + "f104") })
        XCTAssertLessThan(halt, cancel)
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
