import AppKit
import CoreText
import Foundation
@preconcurrency import Vision

final class ScanOutputWriter {
    func write(frames: [PageFrame], options: ScanOptions, destinationFolder: URL) async throws -> ScanJobResult {
        let processed = try frames.compactMap { try ScanImageProcessor.process($0, settings: options.processing, outputDPI: options.export.outputDPI) }
        return try await writeProcessed(processed, options: options, destinationFolder: destinationFolder)
    }

    /// File-backed pages are read and processed one at a time. This is the path used
    /// by the workspace after a scan, so large feeder batches do not stay resident.
    func write(pages: [StoredPage], options: ScanOptions, destinationFolder: URL) async throws -> ScanJobResult {
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let date = Self.dateFormatter.string(from: Date())
        if (options.export.outputFormat == .pdf || options.export.outputFormat == .searchablePDF) && options.export.exportMode == .combinedPDF {
            let url = uniqueURL(folder: destinationFolder, name: renderName(options.export.filenameTemplate, date: date, page: nil, side: nil), ext: "pdf")
            guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ScannerError.outputFailed("Could not write PDF to \(url.path).") }
            var count = 0
            do {
                for page in pages {
                    if let frame = try process(page, options: options) {
                        let image = try decode(frame, quality: options.export.jpegQuality)
                        let lines = options.export.outputFormat == .searchablePDF ? try await recognizeText(in: image, languages: options.export.ocrLanguages) : []
                        writePDFPage(frame: frame, image: image, lines: lines, context: context)
                        count += 1
                    }
                }
                context.closePDF()
            } catch { context.closePDF(); try? FileManager.default.removeItem(at: url); throw error }
            guard count > 0 else { try? FileManager.default.removeItem(at: url); throw ScannerError.outputFailed("No non-blank pages were received from the scanner.") }
            return ScanJobResult(outputURLs: [url], pagesScanned: count, outputByteCount: fileSize(url))
        }

        var urls: [URL] = []; var count = 0; var bytes: Int64 = 0
        for page in pages {
            guard let frame = try process(page, options: options) else { continue }
            let ext: String
            switch options.export.outputFormat { case .pdf, .searchablePDF: ext = "pdf"; case .jpeg: ext = "jpg"; case .png: ext = "png"; case .tiff: ext = "tiff" }
            let url = uniqueURL(folder: destinationFolder, name: renderName(options.export.filenameTemplate, date: date, page: count + 1, side: frame.side.rawValue), ext: ext)
            switch options.export.outputFormat {
            case .pdf, .searchablePDF: try await writePDF(frames: [frame], to: url, searchable: options.export.outputFormat == .searchablePDF, options: options)
            case .jpeg: try encode(frame: frame, to: url, type: .jpeg, quality: options.export.jpegQuality)
            case .png: try encode(frame: frame, to: url, type: .png, quality: 1)
            case .tiff: try encode(frame: frame, to: url, type: .tiff, quality: 1)
            }
            count += 1; bytes += fileSize(url); urls.append(url)
        }
        guard count > 0 else { throw ScannerError.outputFailed("No non-blank pages were received from the scanner.") }
        return ScanJobResult(outputURLs: urls, pagesScanned: count, outputByteCount: bytes)
    }

    private func process(_ page: StoredPage, options: ScanOptions) throws -> PageFrame? {
        let frame = PageFrame(id: page.id, pageIndex: page.pageIndex, side: page.side, pixelFormat: page.pixelFormat, width: page.width, height: page.height, resolutionDPI: page.resolutionDPI, data: try Data(contentsOf: page.fileURL, options: .mappedIfSafe))
        return try ScanImageProcessor.process(frame, settings: options.processing, outputDPI: options.export.outputDPI)
    }

    private func decode(_ frame: PageFrame, quality: Double = 1.0) throws -> CGImage {
        var data = frame.data
        if quality < 0.999, let source = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            data = NSBitmapImageRep(cgImage: source).representation(using: .jpeg, properties: [.compressionFactor: quality]) ?? data
        }
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ScannerError.outputFailed("Could not decode page \(frame.pageIndex).") }
        return image
    }

    private func writeProcessed(_ frames: [PageFrame], options: ScanOptions, destinationFolder: URL) async throws -> ScanJobResult {
        guard !frames.isEmpty else { throw ScannerError.outputFailed("No non-blank pages were received from the scanner.") }
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let date = Self.dateFormatter.string(from: Date())
        if (options.export.outputFormat == .pdf || options.export.outputFormat == .searchablePDF) && options.export.exportMode == .combinedPDF {
            let url = uniqueURL(folder: destinationFolder, name: renderName(options.export.filenameTemplate, date: date, page: nil, side: nil), ext: "pdf")
            try await writePDF(frames: frames, to: url, searchable: options.export.outputFormat == .searchablePDF, options: options)
            return ScanJobResult(outputURLs: [url], pagesScanned: frames.count, outputByteCount: fileSize(url))
        }

        var urls: [URL] = []
        for (index, frame) in frames.enumerated() {
            let ext: String
            switch options.export.outputFormat { case .pdf, .searchablePDF: ext = "pdf"; case .jpeg: ext = "jpg"; case .png: ext = "png"; case .tiff: ext = "tiff" }
            let name = renderName(options.export.filenameTemplate, date: date, page: index + 1, side: frame.side.rawValue)
            let url = uniqueURL(folder: destinationFolder, name: name, ext: ext)
            switch options.export.outputFormat {
            case .pdf, .searchablePDF: try await writePDF(frames: [frame], to: url, searchable: options.export.outputFormat == .searchablePDF, options: options)
            case .jpeg: try encode(frame: frame, to: url, type: .jpeg, quality: options.export.jpegQuality)
            case .png: try encode(frame: frame, to: url, type: .png, quality: 1)
            case .tiff: try encode(frame: frame, to: url, type: .tiff, quality: 1)
            }
            urls.append(url)
        }
        return ScanJobResult(outputURLs: urls, pagesScanned: frames.count, outputByteCount: urls.reduce(0) { $0 + fileSize($1) })
    }

    private func encode(frame: PageFrame, to url: URL, type: NSBitmapImageRep.FileType, quality: Double) throws {
        guard let image = NSImage(data: frame.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ScannerError.outputFailed("Could not encode page \(frame.pageIndex).") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: quality] : [:]) else { throw ScannerError.outputFailed("Could not encode page \(frame.pageIndex).") }
        try data.write(to: url, options: .atomic)
    }

    private func writePDF(frames: [PageFrame], to url: URL, searchable: Bool, options: ScanOptions) async throws {
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ScannerError.outputFailed("Could not write PDF to \(url.path).") }
        do {
            for frame in frames {
                let image = try decode(frame, quality: options.export.jpegQuality)
                let lines = searchable ? try await recognizeText(in: image, languages: options.export.ocrLanguages) : []
                writePDFPage(frame: frame, image: image, lines: lines, context: context)
            }
            context.closePDF()
        } catch { context.closePDF(); try? FileManager.default.removeItem(at: url); throw error }
    }

    private func writePDFPage(frame: PageFrame, image: CGImage, lines: [RecognizedTextLine], context: CGContext) {
        let pageBounds = pageBounds(for: frame); var box = pageBounds; let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary); context.interpolationQuality = .high; context.draw(image, in: pageBounds); drawInvisibleText(lines, in: pageBounds, context: context); context.endPDFPage()
    }

    private func recognizeText(in image: CGImage, languages: [String]) async throws -> [RecognizedTextLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> RecognizedTextLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedTextLine(text: candidate.string, normalizedBounds: observation.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.recognitionLanguages = languages.isEmpty ? ["en-US"] : languages
            DispatchQueue.global(qos: .userInitiated).async { do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { continuation.resume(throwing: error) } }
        }
    }

    private func pageBounds(for frame: PageFrame) -> CGRect { let pointsPerPixel = 72.0 / CGFloat(max(frame.resolutionDPI, 1)); return CGRect(x: 0, y: 0, width: CGFloat(frame.width) * pointsPerPixel, height: CGFloat(frame.height) * pointsPerPixel) }

    private func drawInvisibleText(_ lines: [RecognizedTextLine], in pageBounds: CGRect, context: CGContext) {
        context.saveGState(); context.setTextDrawingMode(.invisible); context.textMatrix = .identity
        for lineInfo in lines where !lineInfo.text.isEmpty {
            let n = lineInfo.normalizedBounds; let bounds = CGRect(x: n.minX * pageBounds.width, y: n.minY * pageBounds.height, width: n.width * pageBounds.width, height: n.height * pageBounds.height)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, bounds.height * 0.8), nil)
            let attributed = CFAttributedStringCreate(nil, lineInfo.text as CFString, [kCTFontAttributeName: font] as CFDictionary)!; let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0; let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil)); guard width > 0 else { continue }
            context.saveGState(); context.translateBy(x: bounds.minX, y: bounds.minY); context.scaleBy(x: bounds.width / width, y: 1); context.textPosition = CGPoint(x: 0, y: max(descent, (bounds.height - ascent - descent) * 0.5 + descent)); CTLineDraw(line, context); context.restoreGState()
        }
        context.restoreGState()
    }

    private func renderName(_ template: String, date: String, page: Int?, side: String?) -> String {
        let value = template.replacingOccurrences(of: "{date}", with: date).replacingOccurrences(of: "{time}", with: Self.timeFormatter.string(from: Date())).replacingOccurrences(of: "{page}", with: page.map { String(format: "%03d", $0) } ?? "batch").replacingOccurrences(of: "{side}", with: side ?? "all")
        let safe = value.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Scan" : safe
    }
    private func uniqueURL(folder: URL, name: String, ext: String) -> URL { var url = folder.appendingPathComponent("\(name).\(ext)"); var counter = 2; while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(name)-\(counter).\(ext)"); counter += 1 }; return url }
    private func fileSize(_ url: URL) -> Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f }()
    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HHmmss"; return f }()
}

private struct RecognizedTextLine: Sendable { let text: String; let normalizedBounds: CGRect }
