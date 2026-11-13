import AppKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

/// Automatic page alignment as ScanSnap Home does it in software: the sheet
/// is rotated until it is straight and the visible paper edges, together
/// with the background wedges the rotation leaves behind, are cropped away.
///
/// The document feeder skews sheets by a degree or two against a white
/// backing, so a sheet's edges are often invisible. When Vision's document
/// segmentation (rectangle detection as a second attempt) finds a real page
/// outline it is used; otherwise the skew is estimated from the content: the
/// angle at which the rows of dark pixels line up best.
nonisolated enum PageAlignment {
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

    /// Above this share of the scan, an "outline" is the scan's own frame: on
    /// a white backing no sheet edge is visible and its tilt says nothing.
    static let scanFrameAreaRatio = 0.9

    static func align(_ image: CGImage) -> Result? {
        guard let result = alignSheet(image) else { return nil }
        guard result.usedPageOutline, let contents = carrierContents(result.image) else { return result }
        return Result(image: contents, angleDegrees: result.angleDegrees, usedPageOutline: true)
    }

    private static func alignSheet(_ image: CGImage) -> Result? {
        // Sheet edges are measured where the paper begins, so the whole sheet
        // is kept and only the precision of the measurement is trimmed. With
        // three or four sides they beat Vision, which outlines a print that
        // runs close to the edge rather than the paper.
        let edges = detectSheetEdges(in: image)
        func cropToSheet(_ edges: SheetEdges) -> Result? {
            straighten(image, quad: edges.quad, angleOverride: edges.tilt, margin: (Double(image.width) / Double(sheetEdgeSampleWidth)).rounded(.up), keepWholeSheet: true, usedPageOutline: true)
        }
        if let edges, edges.sides >= 3, let result = cropToSheet(edges) { return result }
        let outline = detectPageOutline(in: image)
        let imageArea = CGFloat(image.width * image.height)
        if let outline, outline.area < imageArea * scanFrameAreaRatio, let result = straighten(image, quad: outline, usedPageOutline: true) {
            return result
        }
        if let edges, let result = cropToSheet(edges) { return result }
        if let angle = estimateSkewFromContent(image) {
            guard abs(angle) >= 0.0002, let rotated = rotate(image, byRadians: -angle) else { return nil }
            // The backing is white like the canvas, so nothing needs cropping and no margin is lost.
            return Result(image: rotated, angleDegrees: angle * 180 / .pi, usedPageOutline: false)
        }
        return outline.flatMap { straighten(image, quad: $0, usedPageOutline: true) }
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

    /// Rotates the page by its tilt and crops to the straightened page: to the
    /// rectangle inside it, or with `keepWholeSheet` to the rectangle around
    /// it, whiting out what lies outside the sheet (a sheet that turned while
    /// it was fed is not quite a rectangle). `margin` is trimmed on each side.
    static func straighten(_ image: CGImage, quad: Quad, angleOverride: Double? = nil, margin: CGFloat? = nil, keepWholeSheet: Bool = false, usedPageOutline: Bool) -> Result? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let tilt = angleOverride ?? quad.tiltRadians
        guard abs(tilt) <= maximumAngleDegrees * .pi / 180 else { return nil }
        let center = CGPoint(x: width / 2, y: height / 2)
        let rotated = abs(tilt) < 0.0002 ? image : rotate(image, byRadians: -tilt)
        guard let rotated else { return nil }
        let straightQuad = quad.rotated(by: -tilt, around: center)
        let margin = margin ?? max(4, (min(width, height) * edgeMarginFraction).rounded())
        let path = CGMutablePath()
        path.addLines(between: straightQuad.corners)
        path.closeSubpath()
        var rect = (keepWholeSheet ? path.boundingBox : straightQuad.inscribedRect).insetBy(dx: margin, dy: margin)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        // Narrow documents such as receipts are fine; a sliver is a detection error.
        guard rect.width >= width * 0.2, rect.height >= height * 0.2 else { return nil }
        guard keepWholeSheet else {
            // CGImage crops in top-down coordinates.
            let cropRect = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            return rotated.cropping(to: cropRect).map { Result(image: $0, angleDegrees: tilt * 180 / .pi, usedPageOutline: usedPageOutline) }
        }
        guard let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(rotated, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        // The margin inside the outline, which the stroke straddles.
        context.addPath(path)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(margin * 2)
        context.strokePath()
        return context.makeImage().map { Result(image: $0, angleDegrees: tilt * 180 / .pi, usedPageOutline: usedPageOutline) }
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

    /// A page covers a fifth of the scan or more (a receipt runs the scan's
    /// length but not its width), is nearly axis-aligned and roughly rectangular.
    static func isPlausiblePage(_ quad: Quad, in image: CGImage) -> Bool {
        let imageArea = CGFloat(image.width * image.height)
        guard quad.area >= imageArea * 0.2 else { return false }
        guard abs(quad.tiltRadians) <= maximumAngleDegrees * .pi / 180 else { return false }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let top = length(quad.topLeft, quad.topRight), bottom = length(quad.bottomLeft, quad.bottomRight)
        let left = length(quad.bottomLeft, quad.topLeft), right = length(quad.bottomRight, quad.topRight)
        guard min(top, bottom) / max(top, bottom) > 0.9, min(left, right) / max(left, right) > 0.9 else { return false }
        return true
    }

    // MARK: - Sheet edges

    /// The sheet's outline found in the margins of the scan: the feeder's
    /// backing is a shade darker than paper and the sheet casts a thin shadow
    /// along its edges. Each side is read on many lines from the border
    /// inwards to where the backing ends, which print running to the edge of
    /// the paper does not hide, and the positions are fitted to a straight
    /// line, moved inwards by the width of the shadow where clean paper shows
    /// it. A side that shows no edge stays at the border of the scan, where
    /// the sheet runs past it; `nil` when fewer than two sides show one.
    static let sheetEdgeSampleWidth = 900

    struct SheetEdges {
        let quad: Quad
        /// The median tilt of the sides found: a sheet that turned while it
        /// was fed has its long sides at the angle of its content.
        let tilt: Double
        let sides: Int
    }

    static func detectSheetEdges(in image: CGImage) -> SheetEdges? {
        guard let sample = downsampledGray(image, maxWidth: sheetEdgeSampleWidth) else { return nil }
        let w = sample.width, h = sample.height
        let pixels = sample.pixels
        guard min(w, h) >= 100 else { return nil }
        let lines = (
            left: sideLine(length: h, depth: w * 45 / 100) { y, x in Int(pixels[y * w + x]) },
            right: sideLine(length: h, depth: w * 45 / 100) { y, x in Int(pixels[y * w + (w - 1 - x)]) },
            top: sideLine(length: w, depth: h * 45 / 100) { x, y in Int(pixels[y * w + x]) },
            bottom: sideLine(length: w, depth: h * 45 / 100) { x, y in Int(pixels[(h - 1 - y) * w + x]) }
        )
        // Each side as x = a·y + b (left, right) or y = a·x + b (top, bottom), top-down.
        let found = (
            left: lines.left,
            right: lines.right.map { (slope: -$0.slope, intercept: Double(w - 1) - $0.intercept) },
            top: lines.top,
            bottom: lines.bottom.map { (slope: -$0.slope, intercept: Double(h - 1) - $0.intercept) }
        )
        // A vertical side at slope a turns the sheet by atan(a), a horizontal one by -atan(a).
        let tilts = ([found.left, found.right].compactMap { $0.map { atan($0.slope) } } + [found.top, found.bottom].compactMap { $0.map { -atan($0.slope) } }).sorted()
        guard tilts.count >= 2 else { return nil }
        let tilt = tilts.count % 2 == 0 ? (tilts[tilts.count / 2 - 1] + tilts[tilts.count / 2]) / 2 : tilts[tilts.count / 2]
        let left = found.left ?? (0, 0), right = found.right ?? (0, Double(w))
        let top = found.top ?? (0, 0), bottom = found.bottom ?? (0, Double(h))
        func corner(_ vertical: (slope: Double, intercept: Double), _ horizontal: (slope: Double, intercept: Double)) -> CGPoint {
            let x = (vertical.slope * horizontal.intercept + vertical.intercept) / (1 - vertical.slope * horizontal.slope)
            let y = horizontal.slope * x + horizontal.intercept
            // Back to full-size pixels, y up like Core Graphics.
            return CGPoint(x: x * Double(image.width) / Double(w), y: Double(image.height) - y * Double(image.height) / Double(h))
        }
        let quad = Quad(topLeft: corner(left, top), topRight: corner(right, top), bottomRight: corner(right, bottom), bottomLeft: corner(left, bottom))
        return isPlausiblePage(quad, in: image) ? SheetEdges(quad: quad, tilt: tilt, sides: tilts.count) : nil
    }

    /// One side of a sheet lying on the backing, read on lines spread over
    /// the middle of the side: on each, from the border up to `depth` (a
    /// receipt lies far from the sides), where the backing ends and how far on
    /// paper at least as light as the backing begins, when it does so within a
    /// shadow's width (print can run to the edge). The positions are fitted to
    /// `offset = slope * position + intercept` and moved inwards by the
    /// shadow's median width.
    static func sideLine(length: Int, depth: Int, _ value: (_ line: Int, _ offset: Int) -> Int) -> (slope: Double, intercept: Double)? {
        func edge(_ value: (Int) -> Int) -> (start: Int, shadow: Int?)? {
            let backing = (value(0) + value(1) + value(2)) / 3
            guard let start = (0..<depth).first(where: { abs(value($0) - backing) > 8 }) else { return nil }
            let paperStart = (start..<min(start + 10, depth)).first { j in (j..<j + 3).allSatisfy { value($0) >= backing - 2 } }
            return (start, paperStart.map { $0 - start })
        }
        var points: [(x: Double, y: Double)] = []
        var shadows: [Int] = []
        for i in 0...80 {
            let line = length / 10 + i * (length * 8 / 10) / 80
            // Three neighbouring lines averaged against JPEG noise.
            guard let found = edge({ (value(line - 1, $0) + value(line, $0) + value(line + 1, $0)) / 3 }) else { continue }
            points.append((x: Double(line), y: Double(found.start)))
            if let shadow = found.shadow { shadows.append(shadow) }
        }
        // Most lines must agree: where the sheet runs past the border,
        // lines start on paper and their offsets are noise.
        guard let line = fitLine(points, minimumInliers: max(25, points.count * 6 / 10)) else { return nil }
        let shadow = shadows.isEmpty ? 1 : shadows.sorted()[shadows.count / 2]
        return (line.slope, line.intercept + Double(shadow))
    }

    /// The straight line through most points, within two and a half pixels
    /// (a sheet that turns while it is fed bows its sides slightly), or
    /// `nil` when fewer than `minimumInliers` agree or it is steeper than the
    /// largest plausible tilt.
    static func fitLine(_ points: [(x: Double, y: Double)], minimumInliers: Int) -> (slope: Double, intercept: Double)? {
        guard points.count >= minimumInliers else { return nil }
        var best: [(x: Double, y: Double)] = []
        for i in points.indices {
            for j in points.indices where points[j].x > points[i].x {
                let slope = (points[j].y - points[i].y) / (points[j].x - points[i].x)
                let intercept = points[i].y - slope * points[i].x
                let inliers = points.filter { abs($0.y - (slope * $0.x + intercept)) <= 2.5 }
                if inliers.count > best.count { best = inliers }
            }
        }
        guard best.count >= minimumInliers else { return nil }
        // Least squares over the points that agree.
        let n = Double(best.count)
        let mx = best.reduce(0) { $0 + $1.x } / n, my = best.reduce(0) { $0 + $1.y } / n
        let sxx = best.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        let slope = sxx > 0 ? best.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) } / sxx : 0
        guard abs(slope) <= tan(maximumAngleDegrees * .pi / 180) else { return nil }
        return (slope, my - slope * mx)
    }

    // MARK: - Carrier sheet

    /// The document inside a straightened carrier sheet, or `nil` when the
    /// image is not one. Fujitsu's transparent carrier sheet has a black
    /// band under a row of blocks across its leading edge, and sealed seams
    /// along its sides and bottom; the document lies below the band, between
    /// the seams, down to its own bottom edge when that shows on the plastic.
    static func carrierContents(_ image: CGImage) -> CGImage? {
        guard let sample = downsampledGray(image, maxWidth: sheetEdgeSampleWidth), sample.width >= 100 else { return nil }
        let w = sample.width, h = sample.height, pixels = sample.pixels
        let middle = (w / 10)..<(w * 9 / 10)
        func darkShare(_ y: Int) -> Double { Double(middle.filter { pixels[y * w + $0] < 80 }.count) / Double(middle.count) }
        // The carrier is 216 mm wide.
        let millimetre = Double(w) / 216
        /// Dark runs at least a millimetre long across the middle of a row.
        func blocks(_ y: Int) -> Int {
            var count = 0, run = 0
            for x in middle {
                if pixels[y * w + x] < 80 { run += 1 } else { if Double(run) >= millimetre { count += 1 }; run = 0 }
            }
            return count
        }
        // A black band at least 2.5 mm thick in the top eighth, under a row of blocks.
        let thickness = Int(2.5 * millimetre)
        guard let bandTop = (0..<h / 8).first(where: { darkShare($0) > 0.85 }), bandTop + thickness < h / 8,
              (bandTop..<bandTop + thickness).allSatisfy({ darkShare($0) > 0.85 }),
              (max(0, bandTop - h / 30)..<bandTop).contains(where: { blocks($0) >= 12 }),
              let bandBottom = (bandTop..<h / 8).first(where: { darkShare($0) < 0.05 }) else { return nil }

        /// Where a seam ends, read from a border: the steepest rise within
        /// 6 mm, from the darker seam to the plastic. Zero without a seam.
        func seam(length: Int, _ value: (_ line: Int, _ offset: Int) -> Int) -> Int {
            let depth = Int(6 * millimetre)
            let ends = stride(from: length / 4, to: length * 3 / 4, by: max(1, length / 40)).compactMap { line -> Int? in
                let rise = (0..<depth).map { value(line, $0 + 2) - value(line, $0) }
                guard let best = rise.indices.max(by: { rise[$0] < rise[$1] }), rise[best] >= 20 else { return nil }
                return best + 2
            }.sorted()
            return ends.count >= 5 ? ends[ends.count / 2] : 0
        }
        let left = seam(length: h) { y, x in Int(pixels[y * w + x]) }
        let right = seam(length: h) { y, x in Int(pixels[y * w + w - 1 - x]) }
        let bottomSeam = seam(length: w) { x, y in Int(pixels[(h - 1 - y) * w + x]) }
        let top = bandBottom + Int(2 * millimetre)
        // Clear of the seam's gradual shading.
        let lowest = h - 1 - bottomSeam - Int(2 * millimetre)
        guard lowest - top > h / 4, w - left - right > w / 2 else { return nil }
        // The document's bottom edge: going up from the seam, the first dark
        // line across most of the width (the carrier's own print below the
        // document covers less), within two rows either way for a document
        // lying slightly askew; then up through its shadow, the rows darker
        // than both the plastic below and the paper above.
        func lineShare(_ y: Int) -> Double {
            var count = 0
            for x in middle {
                var darkest = 255
                for row in y - 2...y + 2 { darkest = min(darkest, Int(pixels[row * w + x])) }
                if darkest + 12 < Int(pixels[(y + 6) * w + x]) { count += 1 }
            }
            return Double(count) / Double(middle.count)
        }
        func rowMedian(_ y: Int) -> Int { Int(middle.map { pixels[y * w + $0] }.sorted()[middle.count / 2]) }
        var bottom = lowest
        let shadowLimit = Int(6 * millimetre)
        if let line = stride(from: lowest - 6, to: top + h / 4, by: -1).first(where: { lineShare($0) >= 0.6 }) {
            let level = min(rowMedian(line + 6), rowMedian(line - shadowLimit - 3)) - 12
            var y = line + 2
            while y > line - 3, rowMedian(y) >= level { y -= 1 }
            while y > line - shadowLimit, rowMedian(y) < level { y -= 1 }
            // Row y is paper again.
            bottom = y + 1
        }
        let scale = Double(image.width) / Double(w)
        let rect = CGRect(x: Double(left) * scale, y: Double(top) * scale, width: Double(w - left - right) * scale, height: Double(bottom - top) * scale).integral
        return image.cropping(to: rect)
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
