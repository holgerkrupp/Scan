import XCTest
@testable import Scan

final class FujitsuJPEGStreamSplitterTests: XCTestCase {
    private let soi: [UInt8] = [0xff, 0xd8]
    private let dqt: [UInt8] = [0xff, 0xdb, 0x00, 0x04, 0x00, 0x00]
    private let dri: [UInt8] = [0xff, 0xdd, 0x00, 0x04, 0x00, 0x01]
    private let sos: [UInt8] = [0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00]
    private let eoi: [UInt8] = [0xff, 0xd9]

    private func sof(width: Int, height: Int = 0x0010) -> [UInt8] {
        [0xff, 0xc0, 0x00, 0x11, 0x08, UInt8(height >> 8), UInt8(height & 0xff), UInt8(width >> 8), UInt8(width & 0xff),
         0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
    }

    private func jfif(dpi: Int) -> [UInt8] {
        [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02, 0x01,
         UInt8(dpi >> 8), UInt8(dpi & 0xff), UInt8(dpi >> 8), UInt8(dpi & 0xff), 0x00, 0x00]
    }

    /// Entropy data as the scanner interleaves it: front, RST0, back, RST1, front, RST2, back.
    private let interleavedScan: [UInt8] = [0x11, 0x22, 0xff, 0xd0, 0x33, 0x44, 0xff, 0xd1, 0x55, 0x66, 0xff, 0xd2, 0x77, 0x88]

    func testInterlacedDuplexStreamIsSplitIntoTwoJPEGs() {
        let stream = soi + dqt + sof(width: 32) + dri + sos + interleavedScan + eoi
        let splitter = FujitsuJPEGStreamSplitter(requestedWidth: 16, resolutionDPI: 300, duplex: true)
        // Feed in awkward chunk sizes to exercise marker handling across boundaries.
        var offset = 0
        for size in [1, 2, 3, 5, 7, 11, 13] where offset < stream.count {
            let end = min(stream.count, offset + size)
            splitter.feed(Data(stream[offset..<end]))
            offset = end
        }
        splitter.feed(Data(stream[offset...]))

        XCTAssertTrue(splitter.isInterlaced)
        XCTAssertTrue(splitter.hasReachedEndOfImage)
        XCTAssertEqual(splitter.frameWidth, 16)
        XCTAssertEqual(splitter.frameHeight, 0x10)

        let headers = soi + jfif(dpi: 300) + dqt + sof(width: 16) + dri + sos
        XCTAssertEqual([UInt8](splitter.front), headers + [0x11, 0x22, 0xff, 0xd0, 0x55, 0x66] + eoi)
        XCTAssertEqual([UInt8](splitter.back), headers + [0x33, 0x44, 0xff, 0xd0, 0x77, 0x88] + eoi)
    }

    func testRestartMarkersAreRenumberedPerSide() {
        // 20 intervals: even ones belong to the front, odd ones to the back.
        // Interval k carries the single byte k; the scanner numbers the markers 0-7 cyclically.
        var scan: [UInt8] = [0]
        for interval in 1..<20 {
            scan += [0xff, 0xd0 + UInt8((interval - 1) % 8), UInt8(interval)]
        }
        let stream = soi + sof(width: 32) + sos + scan + eoi
        let splitter = FujitsuJPEGStreamSplitter(requestedWidth: 16, resolutionDPI: 200, duplex: true)
        splitter.feed(Data(stream))

        let headerLength = soi.count + jfif(dpi: 200).count + sof(width: 16).count + sos.count
        var frontExpected: [UInt8] = [0]
        var backExpected: [UInt8] = [1]
        for k in 1..<10 {
            frontExpected += [0xff, 0xd0 + UInt8((k - 1) % 8), UInt8(2 * k)]
            backExpected += [0xff, 0xd0 + UInt8((k - 1) % 8), UInt8(2 * k + 1)]
        }
        XCTAssertEqual([UInt8](splitter.front.dropFirst(headerLength)), frontExpected + eoi)
        XCTAssertEqual([UInt8](splitter.back.dropFirst(headerLength)), backExpected + eoi)
    }

    func testDuplexStreamWithPlainWidthIsTreatedAsFrontOnly() {
        let stream = soi + dqt + sof(width: 16) + dri + sos + interleavedScan + eoi
        let splitter = FujitsuJPEGStreamSplitter(requestedWidth: 16, resolutionDPI: 300, duplex: true)
        splitter.feed(Data(stream))

        XCTAssertFalse(splitter.isInterlaced)
        XCTAssertTrue(splitter.back.isEmpty)
        XCTAssertEqual(splitter.frameWidth, 16)
        XCTAssertEqual([UInt8](splitter.front), soi + jfif(dpi: 300) + dqt + sof(width: 16) + dri + sos + interleavedScan + eoi)
    }

    func testSimplexStreamKeepsMarkersAndGainsJFIFHeader() {
        let stream = soi + dqt + sof(width: 16) + sos + interleavedScan + eoi + [0xaa, 0xbb]
        let splitter = FujitsuJPEGStreamSplitter(requestedWidth: 16, resolutionDPI: 600, duplex: false)
        splitter.feed(Data(stream))

        XCTAssertTrue(splitter.hasReachedEndOfImage)
        XCTAssertEqual([UInt8](splitter.front), soi + jfif(dpi: 600) + dqt + sof(width: 16) + sos + interleavedScan + eoi, "trailing bytes after EOI are dropped")
        XCTAssertTrue(splitter.back.isEmpty)
    }

    func testExistingAPP0HeaderIsNotDuplicated() {
        let stream = soi + jfif(dpi: 72) + sof(width: 16) + sos + [0x01] + eoi
        let splitter = FujitsuJPEGStreamSplitter(requestedWidth: 16, resolutionDPI: 300, duplex: false)
        splitter.feed(Data(stream))
        XCTAssertEqual([UInt8](splitter.front), stream)
    }

    func testStuffedZeroBytesAndFillBytesSurvive() {
        let scan: [UInt8] = [0x12, 0xff, 0x00, 0x34, 0xff, 0xff, 0xd0, 0x56]
        let stream = soi + sof(width: 16) + sos + scan + eoi
        let splitter = FujitsuJPEGStreamSplitter(requestedWidth: 16, resolutionDPI: 300, duplex: false)
        splitter.feed(Data(stream))
        XCTAssertEqual([UInt8](splitter.front), soi + jfif(dpi: 300) + sof(width: 16) + sos + scan + eoi)
    }

    func testHardwareJPEGOptionGatingAndQualityMapping() throws {
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .color, resolutionDPI: 300, hardwareCompression: true))
        XCTAssertNoThrow(try FujitsuScanSnapModelProfile.ix500.capabilities.validate(options))
        XCTAssertThrowsError(try FujitsuScanSnapModelProfile.s1500.capabilities.validate(options))

        let plan = FujitsuScanPlan(options: options, profile: .ix500)
        XCTAssertTrue(plan.hardwareJPEG)
        XCTAssertEqual(plan.imageSize.width, 2544, "8.5 in * 300 dpi = 2550 rounded down to 8x8 blocks")
        XCTAssertEqual(plan.widthScannerUnits, 2544 * 1200 / 300)
        XCTAssertEqual(plan.imageSize.height, 4200)
        XCTAssertEqual(plan.heightScannerUnits, 16_800)
        XCTAssertEqual(plan.jpegQualityArgument, 5, "export quality 0.82 maps to Q5")

        options.acquisition.resolutionDPI = 150
        XCTAssertEqual(FujitsuScanPlan(options: options, profile: .ix500).imageSize, FujitsuImageSize(width: 1272, height: 2096))

        XCTAssertFalse(FujitsuScanPlan(options: options, profile: .s1500).hardwareJPEG)
        XCTAssertEqual(FujitsuScanPlan.jpegQualityArgument(forExportQuality: 0.4), 1)
        XCTAssertEqual(FujitsuScanPlan.jpegQualityArgument(forExportQuality: 0.7), 4)
        XCTAssertEqual(FujitsuScanPlan.jpegQualityArgument(forExportQuality: 0.92), 6)
        XCTAssertEqual(FujitsuScanPlan.jpegQualityArgument(forExportQuality: 1.0), 7)

        let legacy = Data(#"{"source":"ADF Front","colorMode":"Gray","resolutionDPI":200}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(AcquisitionSettings.self, from: legacy).hardwareCompression)
    }
}
