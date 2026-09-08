import AppKit
import CoreImage
import Foundation
@preconcurrency import Vision

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
        if settings.autoCrop { rendered = cropToContent(rendered) ?? rendered }
        if settings.deskew { rendered = deskew(rendered) ?? rendered }
        if settings.autoRotate && rendered.width > rendered.height { rendered = rotate(rendered, degrees: 90) ?? rendered }
        if settings.rotation != .degrees0 { rendered = rotate(rendered, degrees: settings.rotation.rawValue) ?? rendered }
        let dpi = max(outputDPI, 1)
        let requestedScale = CGFloat(dpi) / CGFloat(max(frame.resolutionDPI, 1))
        let metadataCorrection = CGFloat(max(frame.width, 1)) / CGFloat(max(rendered.width, 1))
        let scaled = dpi == frame.resolutionDPI && metadataCorrection == 1 ? rendered : resize(rendered, scale: requestedScale * metadataCorrection) ?? rendered
        let data = try encodeJPEG(scaled, quality: 1.0)
        return PageFrame(id: frame.id, pageIndex: frame.pageIndex, side: frame.side, pixelFormat: .jpeg, width: scaled.width, height: scaled.height, resolutionDPI: dpi, data: data)
    }

    static func isBlank(_ image: CGImage, threshold: UInt8 = 245, darkPixelRatio: Double = 0.004) -> Bool {
        guard let provider = image.dataProvider, let data = provider.data as Data? else { return false }
        let components = image.bitsPerPixel / max(image.bitsPerComponent, 1)
        let channels = max(components, 1)
        let bytesPerRow = image.bytesPerRow
        let bytes = [UInt8](data)
        let stepX = max(image.width / 160, 1)
        let stepY = max(image.height / 160, 1)
        var dark = 0
        var samples = 0
        for y in stride(from: 0, to: image.height, by: stepY) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                let offset = y * bytesPerRow + x * channels
                guard offset < bytes.count else { continue }
                let r = bytes[offset]
                let g = channels > 1 && offset + 1 < bytes.count ? bytes[offset + 1] : r
                let b = channels > 2 && offset + 2 < bytes.count ? bytes[offset + 2] : g
                if max(r, max(g, b)) < threshold { dark += 1 }
                samples += 1
            }
        }
        return samples > 0 && Double(dark) / Double(samples) < darkPixelRatio
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

    private static func deskew(_ image: CGImage) -> CGImage? {
        let request = VNDetectRectanglesRequest(); request.maximumObservations = 1; request.minimumConfidence = 0.45; request.minimumAspectRatio = 0.35
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil, let observation = request.results?.first else { return nil }
        let angle = atan2(observation.topRight.y - observation.topLeft.y, observation.topRight.x - observation.topLeft.x) * 180 / .pi
        guard abs(angle) > 0.01 else { return image }
        let radians = -angle * .pi / 180
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rotated = CGRect(origin: .zero, size: bounds.size).applying(CGAffineTransform(rotationAngle: radians)).standardized
        guard let context = CGContext(data: nil, width: Int(rotated.width), height: Int(rotated.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -rotated.minX, y: -rotated.minY); context.rotate(by: radians); context.draw(image, in: bounds)
        return context.makeImage()
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
