import AppKit
import CoreImage
import Foundation

struct ProcessedPage: Sendable {
    let frame: PageFrame
    let image: CGImage
}

enum ScanImageProcessor {
    static func process(_ frame: PageFrame, settings: ImageProcessingSettings, outputDPI: Int) throws -> PageFrame? {
        guard let image = NSImage(data: frame.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScannerError.outputFailed("Could not decode page \(frame.pageIndex).")
        }
        if settings.removeBlankPages && isBlank(image) { return nil }
        var rendered = image
        // Straighten and crop to the page first, then optionally to the content.
        if settings.deskew { rendered = PageAlignment.align(rendered)?.image ?? rendered }
        if settings.autoCrop { rendered = cropToContent(rendered) ?? rendered }
        if settings.autoRotate && rendered.width > rendered.height { rendered = rotate(rendered, degrees: 90) ?? rendered }
        if settings.rotation != .degrees0 { rendered = rotate(rendered, degrees: settings.rotation.rawValue) ?? rendered }
        if settings.whitenPaper { rendered = whitenPaper(rendered) ?? rendered }
        if settings.paperCleanup > 0 { rendered = applyPaperCleanup(rendered, amount: settings.paperCleanup) ?? rendered }
        let dpi = max(outputDPI, 1)
        let requestedScale = CGFloat(dpi) / CGFloat(max(frame.resolutionDPI, 1))
        // Frame metadata can disagree with the decoded size (hardware JPEG
        // widths are block-rounded); correct for that, but never rescale the
        // result of cropping, alignment or rotation back to the original width.
        let metadataCorrection = CGFloat(max(frame.width, 1)) / CGFloat(max(image.width, 1))
        let scaled = dpi == frame.resolutionDPI && metadataCorrection == 1 ? rendered : resize(rendered, scale: requestedScale * metadataCorrection) ?? rendered
        let data = try encodeJPEG(scaled, quality: 1.0)
        return PageFrame(id: frame.id, pageIndex: frame.pageIndex, side: frame.side, pixelFormat: .jpeg, width: scaled.width, height: scaled.height, resolutionDPI: dpi, data: data)
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

    /// Luminance samples on a grid of about 200x200 points inside the page,
    /// with the paper level and the fraction darker than `paperLevel - inkContrast`.
    static func inkStatistics(_ image: CGImage, inkContrast: Int = 90) -> InkStatistics {
        guard let sample = PageAlignment.downsampledGray(image, maxWidth: 400) else {
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
