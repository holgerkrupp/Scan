import CoreGraphics
import XCTest
@testable import Scan

final class PageAlignmentTests: XCTestCase {
    /// A light-gray canvas with a white sheet of `pageSize`, rotated by
    /// `degrees` (counter-clockwise, Core Graphics convention), carrying
    /// black "text" bars.
    private func syntheticScan(canvas: CGSize, pageSize: CGSize, degrees: Double, background: CGFloat = 0.82) -> CGImage {
        let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        context.rotate(by: degrees * .pi / 180)
        context.translateBy(x: -pageSize.width / 2, y: -pageSize.height / 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pageSize))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        var y = pageSize.height * 0.1
        while y < pageSize.height * 0.9 {
            context.fill(CGRect(x: pageSize.width * 0.1, y: y, width: pageSize.width * 0.8, height: 6))
            y += 28
        }
        return context.makeImage()!
    }

    private func gray(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let sample = PageAlignment.downsampledGray(image, maxWidth: image.width)!
        return sample.pixels[y * sample.width + x]
    }

    func testRotatedSheetIsStraightenedAndCroppedInsideItsEdges() throws {
        let image = syntheticScan(canvas: CGSize(width: 1200, height: 1600), pageSize: CGSize(width: 1000, height: 1400), degrees: 2)
        let result = try XCTUnwrap(PageAlignment.align(image))
        XCTAssertEqual(abs(result.angleDegrees), 2, accuracy: 0.4)
        // Inside the page (1000x1400) minus the margin and the rotation loss.
        XCTAssertLessThan(result.image.width, 1000)
        XCTAssertGreaterThan(result.image.width, 900)
        XCTAssertLessThan(result.image.height, 1400)
        XCTAssertGreaterThan(result.image.height, 1300)
        // No background wedge survives in the corners, and the bars are level.
        for (x, y) in [(2, 2), (result.image.width - 3, 2), (2, result.image.height - 3), (result.image.width - 3, result.image.height - 3)] {
            XCTAssertGreaterThan(gray(result.image, x: x, y: y), 240, "corner \(x),\(y)")
        }
        XCTAssertEqual(PageAlignment.estimateSkewFromContent(result.image) ?? 1, 0, accuracy: 0.3 * .pi / 180)
    }

    func testStraightSheetIsOnlyTrimmed() throws {
        let image = syntheticScan(canvas: CGSize(width: 1200, height: 1600), pageSize: CGSize(width: 1000, height: 1400), degrees: 0)
        let result = try XCTUnwrap(PageAlignment.align(image))
        XCTAssertEqual(result.angleDegrees, 0, accuracy: 0.3)
        XCTAssertEqual(result.image.width, 1000 - 2 * 6, accuracy: 4)
        XCTAssertEqual(result.image.height, 1400 - 2 * 6, accuracy: 4)
    }

    func testContentSkewEstimateMatchesTheRotation() {
        for degrees in [-1.5, 0, 2.5] {
            // White canvas, white page: only the bars give the angle away.
            let image = syntheticScan(canvas: CGSize(width: 900, height: 1200), pageSize: CGSize(width: 900, height: 1200), degrees: degrees, background: 1)
            let estimate = PageAlignment.estimateSkewFromContent(image)
            XCTAssertNotNil(estimate, "\(degrees)")
            XCTAssertEqual((estimate ?? 0) * 180 / .pi, degrees, accuracy: 0.3, "\(degrees)")
        }
    }

    func testEmptyPageHasNoContentSkew() {
        let image = syntheticScan(canvas: CGSize(width: 300, height: 400), pageSize: CGSize(width: 0, height: 0), degrees: 0, background: 1)
        XCTAssertNil(PageAlignment.estimateSkewFromContent(image))
    }

    func testInscribedRectangleOfATiltedQuad() {
        let quad = PageAlignment.Quad(topLeft: CGPoint(x: 10, y: 100), topRight: CGPoint(x: 110, y: 104), bottomRight: CGPoint(x: 114, y: 4), bottomLeft: CGPoint(x: 14, y: 0))
        let rect = quad.inscribedRect
        XCTAssertEqual(rect.minX, 14); XCTAssertEqual(rect.maxX, 110)
        XCTAssertEqual(rect.minY, 4); XCTAssertEqual(rect.maxY, 100)
        XCTAssertEqual(quad.tiltRadians * 180 / .pi, atan2(4, 100) * 180 / .pi, accuracy: 0.01)
        XCTAssertEqual(quad.area, 10000, accuracy: 100)
        let straight = quad.rotated(by: -quad.tiltRadians, around: CGPoint(x: 62, y: 52))
        XCTAssertEqual(straight.tiltRadians, 0, accuracy: 1e-9)
    }

    /// The existing "Deskew" option drives the alignment, so saved profiles
    /// with deskew on get it without changes.
    func testDeskewSettingDrivesTheAlignmentAndKeepsThePageSize() throws {
        let legacy = Data(#"{"removeBlankPages":false,"autoCrop":false,"deskew":true,"autoRotate":false,"rotation":0}"#.utf8)
        let settings = try JSONDecoder().decode(ImageProcessingSettings.self, from: legacy)
        XCTAssertTrue(settings.deskew)

        let image = syntheticScan(canvas: CGSize(width: 600, height: 800), pageSize: CGSize(width: 500, height: 700), degrees: 1.5)
        let frame = PageFrame(pageIndex: 1, side: .front, pixelFormat: .jpeg, width: 600, height: 800, resolutionDPI: 300, data: try ScanImageProcessor.encodeJPEG(image, quality: 0.95))
        let processed = try XCTUnwrap(ScanImageProcessor.process(frame, settings: settings, outputDPI: 300))
        // Inside the 500x700 page, and no longer scaled back up to the scan's width.
        XCTAssertLessThan(processed.width, 500)
        XCTAssertGreaterThan(processed.width, 440)
        XCTAssertLessThan(processed.height, 700)
        XCTAssertEqual(processed.resolutionDPI, 300)

        // Rotating by 90 degrees keeps the full resolution as well.
        let rotated = try XCTUnwrap(ScanImageProcessor.process(frame, settings: ImageProcessingSettings(rotation: .degrees90), outputDPI: 300))
        XCTAssertEqual(rotated.width, 800)
        XCTAssertEqual(rotated.height, 600)
    }

    /// Paper that scans as light gray with texture, an edge shadow and
    /// bleed-through is still blank; a few lines of text are not.
    func testBlankDetectionIsRelativeToThePaperLevel() {
        func page(paper: CGFloat, textLines: Int, bleedThrough: Bool = false) -> CGImage {
            let width = 1000, height = 1400
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray: paper, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Paper texture: a light speckle.
            context.setFillColor(CGColor(gray: paper - 0.04, alpha: 1))
            for i in stride(from: 0, to: width * height, by: 97) { context.fill(CGRect(x: i % width, y: (i / width * 7) % height, width: 2, height: 2)) }
            // Dark edge shadow along the left and top borders.
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 6, height: height))
            context.fill(CGRect(x: 0, y: height - 6, width: width, height: 6))
            if bleedThrough {
                context.setFillColor(CGColor(gray: paper - 0.12, alpha: 1))
                for line in 0..<20 { context.fill(CGRect(x: 100, y: 100 + line * 60, width: 800, height: 8)) }
            }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for line in 0..<textLines { context.fill(CGRect(x: 100, y: 200 + line * 40, width: 800, height: 6)) }
            return context.makeImage()!
        }
        XCTAssertTrue(ScanImageProcessor.isBlank(page(paper: 1.0, textLines: 0)))
        XCTAssertTrue(ScanImageProcessor.isBlank(page(paper: 0.94, textLines: 0)), "gray paper (about 240) is still blank")
        XCTAssertTrue(ScanImageProcessor.isBlank(page(paper: 0.94, textLines: 0, bleedThrough: true)), "bleed-through is not ink")
        XCTAssertFalse(ScanImageProcessor.isBlank(page(paper: 0.94, textLines: 3)), "three lines of text")
        XCTAssertFalse(ScanImageProcessor.isBlank(page(paper: 1.0, textLines: 3)))
        let stats = ScanImageProcessor.inkStatistics(page(paper: 0.94, textLines: 3))
        XCTAssertEqual(stats.paperLevel, 240, accuracy: 4)
        XCTAssertGreaterThan(stats.inkRatio, 0.002)
    }

    func testWhitenPaperStretchesGrayPaperToWhiteAndLeavesPhotosAlone() throws {
        func canvas(gray: CGFloat, ink: Bool) -> CGImage {
            let context = CGContext(data: nil, width: 400, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
            if ink { context.setFillColor(CGColor(gray: 0.1, alpha: 1)); for line in 0..<5 { context.fill(CGRect(x: 40, y: 80 + line * 60, width: 320, height: 6)) } }
            return context.makeImage()!
        }
        let gray = canvas(gray: 240.0 / 255.0, ink: true)
        let whitened = try XCTUnwrap(ScanImageProcessor.whitenPaper(gray))
        XCTAssertGreaterThanOrEqual(ScanImageProcessor.inkStatistics(whitened).paperLevel, 250)
        // Ink is brightened only by the same small gain (bar drawn at y 80-86 from the bottom).
        XCTAssertLessThan(PageAlignment.downsampledGray(whitened, maxWidth: 400)!.pixels[(500 - 83) * 400 + 200], 40)
        XCTAssertLessThan(PageAlignment.downsampledGray(gray, maxWidth: 400)!.pixels[(500 - 83) * 400 + 200], 60, "rows are top-down")
        XCTAssertFalse(ScanImageProcessor.isBlank(whitened))

        let white = canvas(gray: 1, ink: false)
        XCTAssertEqual(ScanImageProcessor.inkStatistics(try XCTUnwrap(ScanImageProcessor.whitenPaper(white))).paperLevel, 255)
        let photo = canvas(gray: 0.4, ink: false)
        let photoLevel = ScanImageProcessor.inkStatistics(photo).paperLevel
        XCTAssertLessThan(photoLevel, ScanImageProcessor.minimumPaperLevel)
        XCTAssertEqual(ScanImageProcessor.inkStatistics(try XCTUnwrap(ScanImageProcessor.whitenPaper(photo))).paperLevel, photoLevel, "a dark page is not paper and stays untouched")
        XCTAssertFalse(ScanImageProcessor.isBlank(photo), "a dark page is never blank")

        let legacy = try JSONDecoder().decode(ImageProcessingSettings.self, from: Data(#"{"removeBlankPages":false,"autoCrop":false,"deskew":false,"autoRotate":false,"rotation":0}"#.utf8))
        XCTAssertFalse(legacy.whitenPaper)
        XCTAssertTrue(ScanProfile.defaults.allSatisfy { $0.options.processing.whitenPaper })
    }

    /// Opt-in: aligns every JPEG in `SCAN_ALIGN_SAMPLES` (from the
    /// environment or `~/.scan-hardware-tests`) and writes the results next to
    /// a log into `SCAN_ALIGN_OUTPUT`, for checking the algorithm on real scans.
    func testAlignSampleScans() throws {
        var environment = ProcessInfo.processInfo.environment
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".scan-hardware-tests")
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
                environment[String(trimmed[..<separator])] = environment[String(trimmed[..<separator])] ?? String(trimmed[trimmed.index(after: separator)...])
            }
        }
        guard let samples = environment["SCAN_ALIGN_SAMPLES"], let output = environment["SCAN_ALIGN_OUTPUT"] else {
            throw XCTSkip("Set SCAN_ALIGN_SAMPLES and SCAN_ALIGN_OUTPUT to align real scans.")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        var report: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: samples).sorted() where name.lowercased().hasSuffix(".jpg") {
            let url = URL(fileURLWithPath: samples).appendingPathComponent(name)
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let started = Date()
            let outline = PageAlignment.detectPageOutline(in: image)
            let content = PageAlignment.estimateSkewFromContent(image)
            let result = PageAlignment.align(image)
            let elapsed = Date().timeIntervalSince(started)
            let ink = ScanImageProcessor.inkStatistics(image)
            let whitened = ScanImageProcessor.whitenPaper(image).map { ScanImageProcessor.inkStatistics($0).paperLevel } ?? -1
            var line = String(format: "%@: %dx%d, paper %d (whitened %d), ink %.3f%% -> %@", name, image.width, image.height, ink.paperLevel, whitened, ink.inkRatio * 100, ScanImageProcessor.isBlank(image) ? "BLANK" : "content")
            if let outline { line += String(format: ", outline tilt %.2f° area %.0f%%", outline.tiltRadians * 180 / .pi, outline.area * 100 / CGFloat(image.width * image.height)) } else { line += ", no outline" }
            if let content { line += String(format: ", content tilt %.2f°", content * 180 / .pi) } else { line += ", no content tilt" }
            if let result {
                line += String(format: " -> %.2f° via %@, %dx%d, %.2fs", result.angleDegrees, result.usedPageOutline ? "outline" : "content", result.image.width, result.image.height, elapsed)
                try ScanImageProcessor.encodeJPEG(result.image, quality: 0.85).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            } else {
                line += " -> no alignment"
            }
            report.append(line)
            print("ALIGN \(line)")
        }
        try report.joined(separator: "\n").write(to: URL(fileURLWithPath: output).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
