import CoreGraphics
import Foundation
import Vision

/// Finds the rotation that makes a page's text upright with Apple's on-device
/// text recognition (Vision). Vision's accurate recogniser reads text in any
/// orientation and reports each line as a quadrilateral whose top-left to
/// top-right edge follows the reading direction. Those directions, weighted
/// by how much text each line holds, vote for the page's orientation. Unlike
/// the landscape-to-portrait rule this also fixes pages fed upside down.
nonisolated enum TextOrientationDetector {
    /// Long side of the copy that is read; enough for body text and keeps one
    /// recognition pass under a second per page.
    static let sampleLongSide = 1400

    /// Degrees to pass to `ScanImageProcessor.rotate` so the text reads
    /// upright, 0 when the page already is, or nil when the page carries too
    /// little text, or text in too many directions, to decide.
    static func uprightRotation(for image: CGImage) -> Int? {
        let sample = downscaled(image, longSide: sampleLongSide) ?? image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: sample).perform([request]) } catch { return nil }

        var votes: [Int: Double] = [:]
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  let box = try? candidate.boundingBox(for: candidate.string.startIndex..<candidate.string.endIndex)
            else { continue }
            let weight = Double(candidate.confidence) * Double(candidate.string.filter(\.isLetter).count)
            guard weight > 0 else { continue }
            // Normalised coordinates, origin bottom left; scale to pixels so
            // the angle is not distorted by the page's aspect ratio.
            let dx = Double(box.topRight.x - box.topLeft.x) * Double(sample.width)
            let dy = Double(box.topRight.y - box.topLeft.y) * Double(sample.height)
            votes[correction(forReadingAngle: atan2(dy, dx) * 180 / .pi), default: 0] += weight
        }
        return bestRotation(votes: votes)
    }

    /// `ScanImageProcessor.rotate` turns the content counter-clockwise by the
    /// given degrees, so text running at `angle` (counter-clockwise from the
    /// x axis) is upright after rotating by `360 - angle`, snapped to 90.
    static func correction(forReadingAngle angle: Double) -> Int {
        let snapped = (Int((angle / 90).rounded()) * 90 % 360 + 360) % 360
        return (360 - snapped) % 360
    }

    /// The rotation with the most text behind it, if it holds a clear majority.
    static func bestRotation(votes: [Int: Double], minimumWeight: Double = 12, majority: Double = 0.6) -> Int? {
        let total = votes.values.reduce(0, +)
        guard let best = votes.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
              best.value >= minimumWeight, best.value >= total * majority else { return nil }
        return best.key
    }

    private static func downscaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        let width = max(Int(Double(image.width) * scale), 1), height = max(Int(Double(image.height) * scale), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
