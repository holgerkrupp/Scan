import XCTest
@testable import Scan

final class FujitsuScanSnapDriverTests: XCTestCase {
    private let ix500Identity = ScannerIdentity(
        name: "ScanSnap iX500", manufacturer: "Fujitsu", model: "iX500", serialNumber: "X1",
        connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x132b), locationID: 3
    )
    private let s1500Identity = ScannerIdentity(
        name: "ScanSnap S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: "S1",
        connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 7
    )

    func testRegistryRoutesIX500ToItsNativeDriver() {
        let driver = ScannerDriverRegistry.live.driver(for: ix500Identity)
        XCTAssertTrue(driver is FujitsuScanSnapIX500Driver)
        XCTAssertFalse(FujitsuScanSnapS1500Driver().canDrive(ix500Identity))

        let capabilities = ScannerDriverRegistry.live.capabilities(for: ix500Identity)
        XCTAssertEqual(capabilities, FujitsuScanSnapModelProfile.ix500.capabilities)
        XCTAssertEqual(capabilities?.supportsDuplex, true)
        XCTAssertEqual(capabilities?.colorModes, [.color, .gray, .lineart])
        XCTAssertEqual(capabilities?.resolutionsDPI, [150, 200, 300, 600])
    }

    func testS1500DriverStillClaimsOnlyItsValidatedID() {
        XCTAssertTrue(ScannerDriverRegistry.live.driver(for: s1500Identity) is FujitsuScanSnapS1500Driver)
        XCTAssertFalse(FujitsuScanSnapIX500Driver().canDrive(s1500Identity))

        let unknownFujitsu = ScannerIdentity(
            name: "Unknown", manufacturer: "Fujitsu", model: "?", serialNumber: nil,
            connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x1234), locationID: nil
        )
        XCTAssertNil(ScannerDriverRegistry.live.driver(for: unknownFujitsu))
    }

    func testIX500PlanScansColorAndRoundsWidthToEvenPixels() {
        let options = ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .gray, resolutionDPI: 150))
        let plan = FujitsuScanPlan(options: options, profile: .ix500)

        XCTAssertEqual(plan.colorMode, .gray)
        XCTAssertEqual(plan.scannerColorMode, .color)
        XCTAssertEqual(plan.composition, 5)
        XCTAssertEqual(plan.bitsPerPixel, 8)
        // 8.5 in * 150 dpi = 1275 px, rounded down to SANE's ppl_mod_by_mode[COLOR] = 2.
        XCTAssertEqual(plan.imageSize.width, 1274)
        XCTAssertEqual(plan.widthScannerUnits, 1274 * 1200 / 150)
        XCTAssertEqual(plan.bytesPerLine(forWidth: 1274), 1274 * 3)
        XCTAssertTrue(plan.traceDescription.contains("gray (scanned as color)"))
    }

    func testS1500PlanIsUnchangedByProfileRefactor() {
        for (mode, composition, bits) in [(ScanColorMode.lineart, UInt8(0), UInt8(1)), (.gray, 2, 8), (.color, 5, 8)] {
            for dpi in [150, 200, 300, 400, 600] {
                let options = ScanOptions(acquisition: AcquisitionSettings(source: .adfFront, colorMode: mode, resolutionDPI: dpi))
                let plan = FujitsuScanPlan(options: options, profile: .s1500)
                XCTAssertEqual(plan.widthScannerUnits, 10_200, "\(mode) \(dpi)")
                XCTAssertEqual(plan.heightScannerUnits, 16_800)
                XCTAssertEqual(plan.paperWidthScannerUnits, 10_201)
                XCTAssertEqual(plan.paperHeightScannerUnits, 16_802)
                XCTAssertEqual(plan.imageSize.width, Int(8.5 * Double(dpi)))
                XCTAssertEqual(plan.imageSize.height, 14 * dpi)
                XCTAssertEqual(plan.scannerColorMode, mode)
                XCTAssertEqual(plan.composition, composition)
                XCTAssertEqual(plan.bitsPerPixel, bits)
            }
        }
    }

    func testScannerBufferingIsGatedByCapabilityAndDecodesFromOldProfiles() throws {
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .color, resolutionDPI: 300, scannerBuffering: true))
        XCTAssertNoThrow(try FujitsuScanSnapModelProfile.ix500.capabilities.validate(options))
        XCTAssertThrowsError(try FujitsuScanSnapModelProfile.s1500.capabilities.validate(options))
        XCTAssertTrue(FujitsuScanPlan(options: options, profile: .ix500).scannerBuffering)
        XCTAssertFalse(FujitsuScanPlan(options: options, profile: .s1500).scannerBuffering)
        options.acquisition.scannerBuffering = false
        XCTAssertNoThrow(try FujitsuScanSnapModelProfile.s1500.capabilities.validate(options))

        // A profile saved before the option existed has no key for it.
        let legacy = Data(#"{"source":"ADF Front","colorMode":"Gray","resolutionDPI":200}"#.utf8)
        let decoded = try JSONDecoder().decode(AcquisitionSettings.self, from: legacy)
        XCTAssertEqual(decoded, AcquisitionSettings(source: .adfFront, colorMode: .gray, resolutionDPI: 200, scannerBuffering: false))
        let roundTrip = try JSONDecoder().decode(AcquisitionSettings.self, from: try JSONEncoder().encode(options.acquisition))
        XCTAssertEqual(roundTrip, options.acquisition)
    }

    func testGammaTablePayloadsMatchSANEAndPinTheS1500Bytes() {
        // S1500: the exact 1034-byte payload the original driver sent.
        var expected = [UInt8](repeating: 0, count: 10 + 1024)
        expected[2] = 0x10; expected[4] = 0x04; expected[5] = 0x00; expected[6] = 0x01; expected[7] = 0x00
        for input in 0..<1024 { expected[10 + input] = UInt8(max(0, min(255, Int(Double(input) * 0.25 - 0.5)))) }
        XCTAssertEqual(FujitsuGammaTable.payload(inputBits: FujitsuScanSnapModelProfile.s1500.lookupTableInputBits), expected)

        // iX500: SANE's adbits = 8 table, 256 entries, slope 1, offset -0.5.
        let ix500 = FujitsuGammaTable.payload(inputBits: FujitsuScanSnapModelProfile.ix500.lookupTableInputBits)
        XCTAssertEqual(ix500.count, 10 + 256)
        XCTAssertEqual(Array(ix500[0..<10]), [0, 0, 0x10, 0, 0x01, 0x00, 0x01, 0x00, 0, 0])
        XCTAssertEqual(ix500[10], 0)
        XCTAssertEqual(ix500[11], 0)
        XCTAssertEqual(ix500[12], 1)
        XCTAssertEqual(ix500[10 + 255], 254)
    }

    func testColorInterlaceWindowBytesMatchSANE() {
        XCTAssertEqual(FujitsuColorInterlace.rgb.scanningOrder, 0x01)
        XCTAssertEqual(FujitsuColorInterlace.rgb.scanningOrderArgument, 0x00)
        XCTAssertEqual(FujitsuColorInterlace.bgr.scanningOrder, 0x01)
        XCTAssertEqual(FujitsuColorInterlace.bgr.scanningOrderArgument, 0x05)
        XCTAssertEqual(FujitsuColorInterlace.rrggbb.scanningOrder, 0x00)
        XCTAssertEqual(FujitsuColorInterlace.rrggbb.scanningOrderArgument, 0x00)
        XCTAssertEqual(FujitsuColorInterlace.allCases.first, .rgb)
    }

    func testDecoderInvertsAndDeinterlacesColor() {
        // Two pixels: (10, 20, 30) and (40, 50, 60), delivered with Fujitsu's inverted polarity.
        let rgbWire = Data([10, 20, 30, 40, 50, 60].map { UInt8($0) ^ 0xff })
        let bgrWire = Data([30, 20, 10, 60, 50, 40].map { UInt8($0) ^ 0xff })
        let lineWire = Data([10, 40, 20, 50, 30, 60].map { UInt8($0) ^ 0xff })
        let expected = FujitsuScanSnapImageDecoder.Samples(bytes: [10, 20, 30, 40, 50, 60], samplesPerPixel: 3)

        XCTAssertEqual(decode(rgbWire, width: 2, scanner: .color, output: .color, interlace: .rgb), expected)
        XCTAssertEqual(decode(bgrWire, width: 2, scanner: .color, output: .color, interlace: .bgr), expected)
        XCTAssertEqual(decode(lineWire, width: 2, scanner: .color, output: .color, interlace: .rrggbb), expected)
    }

    func testDecoderDerivesGrayAndLineartFromColorLikeSANE() {
        // Averages 20 (below the 127 threshold, black) and 200 (white).
        let wire = Data([10, 20, 30, 190, 200, 210].map { UInt8($0) ^ 0xff })
        XCTAssertEqual(
            decode(wire, width: 2, scanner: .color, output: .gray, interlace: .rgb),
            FujitsuScanSnapImageDecoder.Samples(bytes: [20, 200], samplesPerPixel: 1)
        )
        XCTAssertEqual(
            decode(wire, width: 2, scanner: .color, output: .lineart, interlace: .rgb),
            FujitsuScanSnapImageDecoder.Samples(bytes: [0, 255], samplesPerPixel: 1)
        )
    }

    func testDecoderKeepsNativeGrayAndLineartPaths() {
        XCTAssertEqual(
            decode(Data([0x00, 0xff]), width: 2, scanner: .gray, output: .gray, interlace: .rgb),
            FujitsuScanSnapImageDecoder.Samples(bytes: [255, 0], samplesPerPixel: 1)
        )
        // Ten packed 1-bit pixels: first and last are black.
        let lineart = decode(Data([0x80, 0x40]), width: 10, scanner: .lineart, output: .lineart, interlace: .rgb)
        XCTAssertEqual(lineart.samplesPerPixel, 1)
        XCTAssertEqual(lineart.bytes.count, 10)
        XCTAssertEqual(lineart.bytes[0], 0)
        XCTAssertEqual(lineart.bytes[9], 0)
        XCTAssertEqual(lineart.bytes[1..<9].filter { $0 == 255 }.count, 8)
    }

    private func decode(
        _ data: Data,
        width: Int,
        scanner: ScanColorMode,
        output: ScanColorMode,
        interlace: FujitsuColorInterlace
    ) -> FujitsuScanSnapImageDecoder.Samples {
        FujitsuScanSnapImageDecoder.normalizedSamples(
            data: data,
            width: width,
            height: 1,
            scannerColorMode: scanner,
            outputColorMode: output,
            interlace: interlace
        )
    }
}
