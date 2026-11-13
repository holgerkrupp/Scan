import AppKit
import CoreImage
import Foundation

nonisolated struct ProcessedPage: Sendable {
    let frame: PageFrame
    let image: CGImage
}

nonisolated enum ScanImageProcessor {
    static func process(_ frame: PageFrame, settings: ImageProcessingSettings, outputDPI: Int, automaticColor: Bool = false) throws -> PageFrame? {
        guard let image = NSImage(data: frame.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScannerError.outputFailed("Could not decode page \(frame.pageIndex).")
        }
        if settings.removeBlankPages && isBlank(image) { return nil }
        var rendered = image
        // Frame metadata can disagree with the decoded size (hardware JPEG
        // widths are block-rounded); the decoded pixels are scaled to match.
        let metadataCorrection = CGFloat(max(frame.width, 1)) / CGFloat(max(image.width, 1))
        // Straighten and crop to the page first, then optionally to the content.
        if settings.deskew, let aligned = PageAlignment.align(rendered) {
            rendered = aligned.image
            if aligned.usedPageOutline {
                rendered = fitToStandardPaper(rendered, dpi: Double(max(frame.resolutionDPI, 1)) / metadataCorrection) ?? rendered
            }
        }
        if settings.autoCrop { rendered = cropToContent(rendered) ?? rendered }
        // The text decides when it can; the landscape rule only covers pages it cannot read.
        let textRotation = settings.aiOrientation ? TextOrientationDetector.uprightRotation(for: rendered) : nil
        if let textRotation { rendered = rotate(rendered, degrees: textRotation) ?? rendered }
        else if settings.autoRotate && rendered.width > rendered.height { rendered = rotate(rendered, degrees: 90) ?? rendered }
        if settings.rotation != .degrees0 { rendered = rotate(rendered, degrees: settings.rotation.rawValue) ?? rendered }
        if settings.whitenPaper { rendered = whitenPaper(rendered) ?? rendered }
        if settings.paperCleanup > 0 { rendered = applyPaperCleanup(rendered, amount: settings.paperCleanup) ?? rendered }
        let dpi = max(outputDPI, 1)
        let requestedScale = CGFloat(dpi) / CGFloat(max(frame.resolutionDPI, 1))
        // Correct for metadata, but never rescale the result of cropping,
        // alignment or rotation back to the original width.
        var scaled = dpi == frame.resolutionDPI && metadataCorrection == 1 ? rendered : resize(rendered, scale: requestedScale * metadataCorrection) ?? rendered
        if automaticColor, !hasColor(scaled) { scaled = grayscale(scaled) ?? scaled
        let data = try encodeJPEG(scaled, quality: 1.0)
        return PageFrame(id: frame.id, pageIndex: frame.pageIndex, side: frame.side, pixelFormat: .jpeg, width: scaled.width, height: scaled.height, resolutionDPI: dpi, data: data)
    }

    /// Standard sheet sizes in millimetres, portrait: ISO A3 to A6, US Letter and Legal.
    static let standardPaperSizes: [(width: Double, height: Double)] = [(297, 420), (210, 297), (148, 210), (105, 148), (215.9, 279.4), (215.9, 355.6)]

    /// The cropped sheet set on the standard paper size it matches within
    /// 2.5% each way, centred, as ScanSnap Manager outputs an A4 letter as
    /// A4: the scanner's resolution and the edge measurement are each off by
    /// a few pixels, and a sheet that turned while it was fed comes out
    /// sheared, up to about 2% longer than it is. The nearest other size is
    /// further away (Letter is 2.8% wider than A4). Missing pixels take the
    /// paper's level, extra ones are trimmed. `nil` when no standard size
    /// matches.
    static func fitToStandardPaper(_ image: CGImage, dpi: Double) -> CGImage? {
        let width = Double(image.width), height = Double(image.height)
        for size in standardPaperSizes {
            for (paperWidth, paperHeight) in [(size.width, size.height), (size.height, size.width)] {
                let targetWidth = (paperWidth * dpi / 25.4).rounded(), targetHeight = (paperHeight * dpi / 25.4).rounded()
                guard abs(width - targetWidth) <= targetWidth * 0.025, abs(height - targetHeight) <= targetHeight * 0.025 else { continue }
                if image.width == Int(targetWidth), image.height == Int(targetHeight) { return image }
                guard let context = CGContext(data: nil, width: Int(targetWidth), height: Int(targetHeight), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                let paper = CGFloat(inkStatistics(image).paperLevel) / 255
                context.setFillColor(CGColor(red: paper, green: paper, blue: paper, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: ((targetWidth - width) / 2).rounded(), y: ((targetHeight - height) / 2).rounded(), width: width, height: height))
                return context.makeImage()
            }
        }
        return nil
    }

    /// Whether a page has any real color: at least `minimumRatio` of a small
    /// copy is tinted beyond scanner noise (neutral pages measured 14 at most).
    /// A stamp, a logo or a pale band is enough, since color lost here cannot
    /// be recovered while keeping it only costs some file size.
    /// The outer 3 percent of each edge is ignored, like for blank pages.
    static func hasColor(_ image: CGImage, minimumChroma: Int = 30, minimumRatio: Double = 0.0001) -> Bool {
        let width = 400, height = max(1, image.height * 400 / max(image.width, 1))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        var samples = 0, colored = 0
        for y in (height * 3 / 100)..<(height - height * 3 / 100) {
            for x in (width * 3 / 100)..<(width - width * 3 / 100) {
                let offset = (y * width + x) * 4
                let (r, g, b) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                samples += 1
                if max(r, g, b) - min(r, g, b) >= minimumChroma { colored += 1 }
            }
        }
        return samples > 0 && Double(colored) / Double(samples) >= minimumRatio
    }

    static func grayscale(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()

    }

    /// A page is blank when almost none of it is ink. Ink is judged relative
    /// to the page's own paper level (the median of the sampled luminance),
    /// because scanners render paper anywhere between about 235 and 255
    /// depending on the paper and the gamma curve; a fixed near-white
    /// threshold treated ordinary paper texture as content. The outer 3
    /// percent of each edge is ignored, where the sheet's edge and shadow
    /// lie, and bleed-through from the other side stays well above the ink
    /// threshold.
    static func isBlank(_ image: CGImage, inkContrast: Int = 90, inkRatio: Double = 0.002) -> Bool {
        let stats = inkStatistics(image, inkContrast: inkContrast)
        // A page whose typical tone is not paper (a photo, a dark flyer) is content by definition.
        return stats.samples > 0 && stats.paperLevel >= minimumPaperLevel && stats.inkRatio < inkRatio
    }

    /// Lowest median luminance that still counts as paper.
    static let minimumPaperLevel = 180

    struct InkStatistics {
        let samples: Int
        let paperLevel: Int
        let inkRatio: Double
    }

    /// Width the page is sampled at for ink statistics. Book type on a
    /// flatbed has strokes of one to three pixels at 300 dpi; shrinking the
    /// page to 400 pixels averaged them into paper, so whole pages of text
    /// counted as blank. A 300 dpi A4 page is read at full resolution, larger
    /// scans are halved at most, which also bounds the memory used.
    static let inkSampleWidth = 2600

    /// Luminance of the page inside a 3 percent margin, with the paper level
    /// and the fraction darker than `paperLevel - inkContrast`.
    static func inkStatistics(_ image: CGImage, inkContrast: Int = 90) -> InkStatistics {
        guard let sample = PageAlignment.downsampledGray(image, maxWidth: inkSampleWidth) else {
            return InkStatistics(samples: 0, paperLevel: 255, inkRatio: 0)
        }
        let insetX = sample.width * 3 / 100, insetY = sample.height * 3 / 100
        var histogram = [Int](repeating: 0, count: 256)
        var count = 0
        for y in insetY..<(sample.height - insetY) {
            for x in insetX..<(sample.width - insetX) {
                histogram[Int(sample.pixels[y * sample.width + x])] += 1
                count += 1
            }
        }
        guard count > 0 else { return InkStatistics(samples: 0, paperLevel: 255, inkRatio: 0) }
        var seen = 0, median = 255
        for value in 0..<256 { seen += histogram[value]; if seen >= count / 2 { median = value; break } }
        let inkLimit = max(0, median - inkContrast)
        let ink = (0..<inkLimit).reduce(0) { $0 + histogram[$1] }
        return InkStatistics(samples: count, paperLevel: median, inkRatio: Double(ink) / Double(count))
    }

    private static func cropToContent(_ image: CGImage) -> CGImage? {
        guard let provider = image.dataProvider, let data = provider.data as Data? else { return nil }
        let channels = max(image.bitsPerPixel / max(image.bitsPerComponent, 1), 1)
        let bytes = [UInt8](data); let step = max(min(image.width, image.height) / 500, 1)
        var minX = image.width, minY = image.height, maxX = 0, maxY = 0
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                let offset = y * image.bytesPerRow + x * channels
                guard offset < bytes.count else { continue }
                let r = bytes[offset]; let g = channels > 1 && offset + 1 < bytes.count ? bytes[offset + 1] : r; let b = channels > 2 && offset + 2 < bytes.count ? bytes[offset + 2] : g
                if min(r, min(g, b)) < 238 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let margin = max(4, min(image.width, image.height) / 100)
        let rect = CGRect(x: max(0, minX - margin), y: max(0, minY - margin), width: min(image.width, maxX + margin) - max(0, minX - margin), height: min(image.height, maxY + margin) - max(0, minY - margin))
        return image.cropping(to: rect)
    }

    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return image }
        let swap = normalized == 90 || normalized == 270
        let width = swap ? image.height : image.width; let height = swap ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch normalized { case 90: context.translateBy(x: CGFloat(width), y: 0); context.rotate(by: .pi / 2); case 180: context.translateBy(x: CGFloat(width), y: CGFloat(height)); context.rotate(by: .pi); case 270: context.translateBy(x: 0, y: CGFloat(height)); context.rotate(by: -.pi / 2); default: break }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return context.makeImage()
    }

    /// Stretches the page so its paper level lands on white. Scanners render
    /// plain paper anywhere from about 230 to 250; ScanSnap Home whitens it,
    /// this does the same with a per-page gain (black stays anchored). Pages
    /// whose median is not paper-like, such as photos, are left alone, and the
    /// gain is capped so nothing is pushed more than a quarter brighter.
    static let paperWhiteTarget = 253
    static func whitenPaper(_ image: CGImage) -> CGImage? {
        let stats = inkStatistics(image)
        guard stats.samples > 0, stats.paperLevel >= minimumPaperLevel, stats.paperLevel < paperWhiteTarget else { return image }
        let gain = min(1.25, Double(paperWhiteTarget) / Double(stats.paperLevel))
        return applyGain(image, gain: gain)
    }

    /// Suppresses faint paper shadows by moving the white point down by up to
    /// 12 percent. This keeps black anchored at black while clipped highlights
    /// make shallow folds and page texture less visible.
    static func applyPaperCleanup(_ image: CGImage, amount: Double) -> CGImage? {
        let strength = min(max(amount, 0), 1)
        guard strength > 0 else { return image }
        return applyGain(image, gain: 1 / (1 - 0.12 * strength))
    }

    /// Multiplies every channel by `gain`, clipping at white.
    static func applyGain(_ image: CGImage, gain: Double) -> CGImage? {
        guard gain > 1.0001 else { return image }
        let bytesPerRow = image.width * 4
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * image.height)
        for row in 0..<image.height {
            let rowStart = row * bytesPerRow
            for column in 0..<image.width {
                let offset = rowStart + column * 4
                pixels[offset] = UInt8(min(255, (Double(pixels[offset]) * gain).rounded()))
                pixels[offset + 1] = UInt8(min(255, (Double(pixels[offset + 1]) * gain).rounded()))
                pixels[offset + 2] = UInt8(min(255, (Double(pixels[offset + 2]) * gain).rounded()))
            }
        }
        return context.makeImage()
    }

    private static func resize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard scale > 0, scale != 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSImage(cgImage: image, size: NSSize(width: width, height: height)).draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: min(max(quality, 0), 1)]) else { throw ScannerError.outputFailed("Could not encode JPEG.") }
        return data
    }
}
