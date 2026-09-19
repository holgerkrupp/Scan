import AppKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

/// Automatic page alignment as ScanSnap Home does it in software: the sheet
/// is rotated until it is straight and the visible paper edges, together
/// with the background wedges the rotation leaves behind, are cropped away.
///
/// The document feeder skews sheets by a degree or two against a white
/// backing, so the page quadrilateral is found with Vision's document
/// segmentation (rectangle detection as a second attempt). When no page
/// outline can be found, the skew is estimated from the content instead:
/// the angle at which the rows of dark pixels line up best.
enum PageAlignment {
    /// Largest tilt a feeder plausibly produces; anything larger is treated
    /// as a detection error.
    static let maximumAngleDegrees = 12.0
    /// Fraction of the shorter side trimmed inside the detected page so the
    /// edge shadow disappears (about 1.3 mm on an A4 page).
    static let edgeMarginFraction = 0.006

    struct Result {
        let image: CGImage
        let angleDegrees: Double
        let usedPageOutline: Bool
    }

    static func align(_ image: CGImage) -> Result? {
        if let quad = detectPageOutline(in: image), let result = straighten(image, quad: quad, usedPageOutline: true) {
            return result
        }
        guard let angle = estimateSkewFromContent(image) else { return nil }
        let corners = Quad(
            topLeft: CGPoint(x: 0, y: CGFloat(image.height)), topRight: CGPoint(x: CGFloat(image.width), y: CGFloat(image.height)),
            bottomRight: CGPoint(x: CGFloat(image.width), y: 0), bottomLeft: .zero
        )
        return straighten(image, quad: corners, angleOverride: angle, usedPageOutline: false)
    }

    // MARK: - Geometry (pixel coordinates, y up like Core Graphics)

    struct Quad {
        var topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint

        var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

        /// Shoelace area.
        var area: CGFloat {
            let p = corners
            var sum: CGFloat = 0
            for i in 0..<4 { let a = p[i], b = p[(i + 1) % 4]; sum += a.x * b.y - b.x * a.y }
            return abs(sum) / 2
        }

        /// Mean tilt of the four edges in radians: the horizontal edges as
        /// they are, the vertical ones turned by a quarter turn.
        var tiltRadians: Double {
            func angle(_ a: CGPoint, _ b: CGPoint) -> Double { atan2(Double(b.y - a.y), Double(b.x - a.x)) }
            let top = angle(topLeft, topRight)
            let bottom = angle(bottomLeft, bottomRight)
            let left = angle(bottomLeft, topLeft) - .pi / 2
            let right = angle(bottomRight, topRight) - .pi / 2
            return (top + bottom + left + right) / 4
        }

        func rotated(by radians: Double, around center: CGPoint) -> Quad {
            func rotate(_ p: CGPoint) -> CGPoint {
                let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
                return CGPoint(x: center.x + CGFloat(dx * cos(radians) - dy * sin(radians)), y: center.y + CGFloat(dx * sin(radians) + dy * cos(radians)))
            }
            return Quad(topLeft: rotate(topLeft), topRight: rotate(topRight), bottomRight: rotate(bottomRight), bottomLeft: rotate(bottomLeft))
        }

        /// The largest axis-aligned rectangle bounded by the four corners.
        var inscribedRect: CGRect {
            let left = max(topLeft.x, bottomLeft.x), right = min(topRight.x, bottomRight.x)
            let bottom = max(bottomLeft.y, bottomRight.y), top = min(topLeft.y, topRight.y)
            return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
    }

    /// Rotates the page by its tilt and crops to the straightened page.
    static func straighten(_ image: CGImage, quad: Quad, angleOverride: Double? = nil, usedPageOutline: Bool) -> Result? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let tilt = angleOverride ?? quad.tiltRadians
        guard abs(tilt) <= maximumAngleDegrees * .pi / 180 else { return nil }
        let center = CGPoint(x: width / 2, y: height / 2)
        let rotated = abs(tilt) < 0.0002 ? image : rotate(image, byRadians: -tilt)
        guard let rotated else { return nil }
        let straightQuad = quad.rotated(by: -tilt, around: center)
        let margin = max(4, (min(width, height) * edgeMarginFraction).rounded())
        var rect = straightQuad.inscribedRect.insetBy(dx: margin, dy: margin)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard rect.width >= width * 0.5, rect.height >= height * 0.5 else { return nil }
        // CGImage crops in top-down coordinates.
        let cropRect = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        guard let cropped = rotated.cropping(to: cropRect) else { return nil }
        return Result(image: cropped, angleDegrees: tilt * 180 / .pi, usedPageOutline: usedPageOutline)
    }

    /// Rotates about the centre onto a white canvas of the same size.
    static func rotate(_ image: CGImage, byRadians radians: Double) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
        context.rotate(by: CGFloat(radians))
        context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Page outline

    /// The sheet's outline from Vision, or `nil` when neither the document
    /// segmentation nor rectangle detection returns a plausible page.
    static func detectPageOutline(in image: CGImage) -> Quad? {
        let handler = VNImageRequestHandler(cgImage: image)
        let segmentation = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 1
        rectangles.minimumConfidence = 0.5
        rectangles.minimumAspectRatio = 0.3
        rectangles.quadratureTolerance = 15
        try? handler.perform([segmentation, rectangles])
        let candidates = (segmentation.results ?? []) + (rectangles.results ?? [])
        for observation in candidates {
            let quad = Quad(
                topLeft: pixel(observation.topLeft, in: image), topRight: pixel(observation.topRight, in: image),
                bottomRight: pixel(observation.bottomRight, in: image), bottomLeft: pixel(observation.bottomLeft, in: image)
            )
            if isPlausiblePage(quad, in: image) { return quad }
        }
        return nil
    }

    private static func pixel(_ normalized: CGPoint, in image: CGImage) -> CGPoint {
        CGPoint(x: normalized.x * CGFloat(image.width), y: normalized.y * CGFloat(image.height))
    }

    /// A page covers most of the scan, is nearly axis-aligned and roughly rectangular.
    static func isPlausiblePage(_ quad: Quad, in image: CGImage) -> Bool {
        let imageArea = CGFloat(image.width * image.height)
        guard quad.area >= imageArea * 0.3 else { return false }
        guard abs(quad.tiltRadians) <= maximumAngleDegrees * .pi / 180 else { return false }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let top = length(quad.topLeft, quad.topRight), bottom = length(quad.bottomLeft, quad.bottomRight)
        let left = length(quad.bottomLeft, quad.topLeft), right = length(quad.bottomRight, quad.topRight)
        guard min(top, bottom) / max(top, bottom) > 0.9, min(left, right) / max(left, right) > 0.9 else { return false }
        return true
    }

    // MARK: - Content-based skew

    /// The angle (radians, same sign convention as `Quad.tiltRadians`) at
    /// which the dark pixels line up into rows best, found by maximising the
    /// variance of the horizontal projection over a range of trial angles.
    /// `nil` when the page is too empty to judge.
    static func estimateSkewFromContent(_ image: CGImage) -> Double? {
        guard let sample = downsampledGray(image, maxWidth: 600) else { return nil }
        let width = sample.width, height = sample.height
        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(width * height / 10)
        for y in 0..<height {
            for x in 0..<width where sample.pixels[y * width + x] < 160 {
                points.append((Double(x), Double(y)))
            }
        }
        guard points.count >= width * height / 500 else { return nil }
        let cx = Double(width) / 2, cy = Double(height) / 2
        var best = (angle: 0.0, score: -1.0)
        let stepDegrees = 0.2
        for step in stride(from: -5.0, through: 5.0, by: stepDegrees) {
            let radians = step * .pi / 180
            let s = sin(radians), c = cos(radians)
            var rows = [Int](repeating: 0, count: height + 2)
            for p in points {
                let y = -(p.x - cx) * s + (p.y - cy) * c + cy
                let row = Int(y.rounded())
                if row >= 0 && row < rows.count { rows[row] += 1 }
            }
            let mean = Double(points.count) / Double(rows.count)
            let variance = rows.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
            if variance > best.score { best = (step, variance) }
        }
        // Rows run top-down, Core Graphics angles counter-clockwise with y up,
        // so the levelling angle is the negated tilt (verified on synthetic pages).
        let tilt = -best.angle * .pi / 180
        return abs(best.angle) < stepDegrees / 2 ? 0 : tilt
    }

    struct GraySample {
        let width: Int, height: Int
        let pixels: [UInt8]
    }

    /// Luminance (channel mean) of the image scaled to at most `maxWidth`
    /// pixels wide, with row 0 at the top. The values stay in the image's own
    /// encoding: an RGB bitmap is used rather than a gray colour space, whose
    /// conversion would shift the levels away from the pixel values that
    /// `ScanImageProcessor` later multiplies.
    static func downsampledGray(_ image: CGImage, maxWidth: Int) -> GraySample? {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        let bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        // Bitmap memory starts with the top row, so no flip is needed.
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let offset = row + x * 4
                pixels[y * width + x] = UInt8((Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2])) / 3)
            }
        }
        return GraySample(width: width, height: height, pixels: pixels)
    }
}
