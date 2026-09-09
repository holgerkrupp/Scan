import AppKit
import XCTest
@testable import Scan

/// Covers `FujitsuScanSnapImageDecoder.finishHardwareJPEG`, the step that turns
/// a scanner-produced colour JPEG into the requested output mode.
final class FujitsuHardwareJPEGConversionTests: XCTestCase {
    private let width = 64
    private let height = 32
    private let darkRGB: (UInt8, UInt8, UInt8) = (20, 30, 40)
    private let lightRGB: (UInt8, UInt8, UInt8) = (230, 240, 250)

    /// A colour JPEG whose left half is dark and right half is light, as a
    /// scanner would deliver it in hardware compression mode.
    private func makeScannerJPEG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for row in 0..<height {
            for column in 0..<width {
                let rgb = column < width / 2 ? darkRGB : lightRGB
                let offset = row * width * 3 + column * 3
                pixels[offset] = rgb.0
                pixels[offset + 1] = rgb.1
                pixels[offset + 2] = rgb.2
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]))
    }

    /// Decodes a JPEG into 8-bit gray samples the same way the pipeline does.
    private func graySamples(_ jpeg: Data) throws -> [UInt8] {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        let cgImage = try XCTUnwrap(rep.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: rep.pixelsWide,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        let buffer = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: rep.pixelsWide * rep.pixelsHigh)
        return Array(UnsafeBufferPointer(start: buffer, count: rep.pixelsWide * rep.pixelsHigh))
    }

    /// Mean of the interior of one half, avoiding the JPEG ringing at the edge.
    private func mean(_ samples: [UInt8], leftHalf: Bool) -> Double {
        let columns = leftHalf ? 4..<(width / 2 - 4) : (width / 2 + 4)..<(width - 4)
        var total = 0, count = 0
        for row in 4..<(height - 4) {
            for column in columns {
                total += Int(samples[row * width + column])
                count += 1
            }
        }
        return Double(total) / Double(count)
    }

    func testColorOutputPassesTheScannerJPEGThroughUntouched() throws {
        let jpeg = try makeScannerJPEG()
        let result = try FujitsuScanSnapImageDecoder.finishHardwareJPEG(jpeg, outputColorMode: .color)
        XCTAssertEqual(result.data, jpeg)
        XCTAssertEqual(result.size, FujitsuImageSize(width: width, height: height))
    }

    func testGrayOutputIsASingleChannelJPEGWithMatchingLuminance() throws {
        let jpeg = try makeScannerJPEG()
        let result = try FujitsuScanSnapImageDecoder.finishHardwareJPEG(jpeg, outputColorMode: .gray)

        XCTAssertNotEqual(result.data, jpeg)
        XCTAssertEqual(result.size, FujitsuImageSize(width: width, height: height))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        XCTAssertEqual(rep.pixelsWide, width)
        XCTAssertEqual(rep.pixelsHigh, height)
        XCTAssertEqual(rep.colorSpace.colorSpaceModel, .gray, "gray output must not carry colour channels")

        let samples = try graySamples(result.data)
        let expectedDark = try mean(graySamples(jpeg), leftHalf: true)
        let expectedLight = try mean(graySamples(jpeg), leftHalf: false)
        XCTAssertEqual(mean(samples, leftHalf: true), expectedDark, accuracy: 6)
        XCTAssertEqual(mean(samples, leftHalf: false), expectedLight, accuracy: 6)
        XCTAssertLessThan(mean(samples, leftHalf: true), 60)
        XCTAssertGreaterThan(mean(samples, leftHalf: false), 220)
    }

    func testLineartOutputIsThresholdedToBlackAndWhite() throws {
        let jpeg = try makeScannerJPEG()
        let result = try FujitsuScanSnapImageDecoder.finishHardwareJPEG(jpeg, outputColorMode: .lineart)

        XCTAssertEqual(result.size, FujitsuImageSize(width: width, height: height))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        XCTAssertEqual(rep.colorSpace.colorSpaceModel, .gray)

        let samples = try graySamples(result.data)
        XCTAssertLessThan(mean(samples, leftHalf: true), 4, "dark half becomes black")
        XCTAssertGreaterThan(mean(samples, leftHalf: false), 251, "light half becomes white")
        // Apart from JPEG ringing along the edge, every sample is black or white.
        let midtones = samples.filter { $0 > 24 && $0 < 231 }.count
        XCTAssertLessThan(midtones, width * height / 20)
    }

    func testLineartThresholdSitsAtTheSANEMidpoint() throws {
        // Two flat images just below and just above the threshold of 127.
        for (value, expectsBlack) in [(UInt8(120), true), (UInt8(134), false)] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 3,
                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 48, bitsPerPixel: 24
            ))
            try XCTUnwrap(bitmap.bitmapData).update(repeating: value, count: 16 * 16 * 3)
            let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
            let result = try FujitsuScanSnapImageDecoder.finishHardwareJPEG(jpeg, outputColorMode: .lineart)
            let samples = try graySamples(result.data)
            let average = Double(samples.reduce(0) { $0 + Int($1) }) / Double(samples.count)
            if expectsBlack {
                XCTAssertLessThan(average, 4, "gray \(value) is below the threshold")
            } else {
                XCTAssertGreaterThan(average, 251, "gray \(value) is above the threshold")
            }
        }
    }

    func testUndecodableDataIsRejected() {
        XCTAssertThrowsError(try FujitsuScanSnapImageDecoder.finishHardwareJPEG(Data([0xff, 0xd8, 0x00, 0x01]), outputColorMode: .color))
        XCTAssertThrowsError(try FujitsuScanSnapImageDecoder.finishHardwareJPEG(Data(), outputColorMode: .gray))
    }
}
