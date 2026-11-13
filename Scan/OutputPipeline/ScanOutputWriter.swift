import AppKit
import CoreText
import Foundation
@preconcurrency import Vision

/// Steps of an export that take long enough to show, reported in order.
enum ExportProgress: Equatable {
    /// Vision reads page `page` of `of` for the document tokens of the filename.
    case readingText(page: Int, of: Int)
    /// Apple Intelligence proposes the document name and fields from that text.
    case proposingName
    /// Page `page` of `of` is written; `recognizingText` when a searchable
    /// PDF runs Vision on it.
    case writingPage(page: Int, of: Int, recognizingText: Bool)
}

/// What the document tokens of a filename are filled with.
struct DocumentNaming: Sendable {
    /// `{name}`; nil leaves it at `DocumentName.fallback`.
    var name: String?
    /// `{docdate}`, `{sender}`, `{type}`, `{subject}` and `{person}`.
    var metadata: DocumentMetadata?
}

final class ScanOutputWriter {
    /// The tokens filled by `DocumentAnalysis` rather than by the name suggester.
    static let analysisTokens = ["{docdate}", "{sender}", "{type}", "{subject}", "{person}"]
    /// Fills the `{name}` token of the filename template; nil leaves it at the fallback.
    private let nameSuggester: DocumentNameSuggesting?
    /// Fills the sender, type and subject; the date and person need no model.
    private let documentModel: DocumentModel
    /// Called on the main actor before each long step of `write(pages:)`.
    var onProgress: ((ExportProgress) -> Void)?

    init(nameSuggester: DocumentNameSuggesting? = FoundationModelNameSuggester(), documentModel: DocumentModel = AppleIntelligenceDocumentModel()) {
        self.nameSuggester = nameSuggester
        self.documentModel = documentModel
    }

    /// `people` is the list `{person}` is chosen from, one person per line.
    func write(frames: [PageFrame], options: ScanOptions, destinationFolder: URL, ocrLanguage: OCRLanguage = .german, people: String = "") async throws -> ScanJobResult {
        let processed = try frames.compactMap { try ScanImageProcessor.process($0, settings: options.processing, outputDPI: options.export.outputDPI) }
        return try await writeProcessed(processed, options: options, destinationFolder: destinationFolder, ocrLanguage: ocrLanguage, people: people)
    }

    /// File-backed pages are read one at a time, so large feeder batches do not
    /// stay resident. This is the workspace's path: the pages are already
    /// processed renditions, so only the output resolution and compression are
    /// applied here and the export matches what the grid shows.
    func write(pages: [StoredPage], options: ScanOptions, destinationFolder: URL, ocrLanguage: OCRLanguage = .german, people: String = "") async throws -> ScanJobResult {
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let date = Date()
        let documentName = await documentNaming(for: options.export.filenameTemplate, language: ocrLanguage, people: people, frames: pages.map { page in { try self.process(page, options: options) } })
        if (options.export.outputFormat == .pdf || options.export.outputFormat == .searchablePDF) && options.export.exportMode == .combinedPDF {
            let url = uniqueURL(folder: destinationFolder, name: Self.renderName(options.export, date: date, naming: documentName, page: nil, side: nil), ext: "pdf")
            guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ScannerError.outputFailed("Could not write PDF to \(url.path).") }
            var count = 0
            let searchable = options.export.outputFormat == .searchablePDF
            do {
                for (index, page) in pages.enumerated() {
                    onProgress?(.writingPage(page: index + 1, of: pages.count, recognizingText: searchable))
                    if let frame = try process(page, options: options) {
                        let image = try decode(frame, quality: options.export.jpegQuality)
                        let lines = searchable ? try await recognizeText(in: image, languages: options.export.ocrLanguages) : []
                        writePDFPage(frame: frame, image: image, lines: lines, context: context)
                        count += 1
                    }
                }
                context.closePDF()
            } catch { context.closePDF(); try? FileManager.default.removeItem(at: url); throw error }
            guard count > 0 else { try? FileManager.default.removeItem(at: url); throw ScannerError.outputFailed("There are no pages to export.") }
            return ScanJobResult(outputURLs: [url], pagesScanned: count, outputByteCount: fileSize(url))
        }

        var urls: [URL] = []; var count = 0; var bytes: Int64 = 0
        for (index, page) in pages.enumerated() {
            onProgress?(.writingPage(page: index + 1, of: pages.count, recognizingText: options.export.outputFormat == .searchablePDF))
            guard let frame = try process(page, options: options) else { continue }
            let ext: String
            switch options.export.outputFormat { case .pdf, .searchablePDF: ext = "pdf"; case .jpeg: ext = "jpg"; case .png: ext = "png"; case .tiff: ext = "tiff" }
            let url = uniqueURL(folder: destinationFolder, name: Self.renderName(options.export, date: date, naming: documentName, page: count + 1, side: frame.side.rawValue), ext: ext)
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
        return try ScanImageProcessor.process(frame, settings: ImageProcessingSettings(), outputDPI: options.export.outputDPI)
    }

    private func decode(_ frame: PageFrame, quality: Double = 1.0) throws -> CGImage {
        var data = frame.data
        if quality < 0.999, let source = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            data = NSBitmapImageRep(cgImage: source).representation(using: .jpeg, properties: [.compressionFactor: quality]) ?? data
        }
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ScannerError.outputFailed("Could not decode page \(frame.pageIndex).") }
        return image
    }

    private func writeProcessed(_ frames: [PageFrame], options: ScanOptions, destinationFolder: URL, ocrLanguage: OCRLanguage, people: String) async throws -> ScanJobResult {
        guard !frames.isEmpty else { throw ScannerError.outputFailed("No non-blank pages were received from the scanner.") }
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let date = Date()
        let documentName = await documentNaming(for: options.export.filenameTemplate, language: ocrLanguage, people: people, frames: frames.map { frame in { frame } })
        if (options.export.outputFormat == .pdf || options.export.outputFormat == .searchablePDF) && options.export.exportMode == .combinedPDF {
            let url = uniqueURL(folder: destinationFolder, name: Self.renderName(options.export, date: date, naming: documentName, page: nil, side: nil), ext: "pdf")
            try await writePDF(frames: frames, to: url, searchable: options.export.outputFormat == .searchablePDF, options: options)
            return ScanJobResult(outputURLs: [url], pagesScanned: frames.count, outputByteCount: fileSize(url))
        }

        var urls: [URL] = []
        for (index, frame) in frames.enumerated() {
            let ext: String
            switch options.export.outputFormat { case .pdf, .searchablePDF: ext = "pdf"; case .jpeg: ext = "jpg"; case .png: ext = "png"; case .tiff: ext = "tiff" }
            let name = Self.renderName(options.export, date: date, naming: documentName, page: index + 1, side: frame.side.rawValue)
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

    /// Vision calls back on its own queue, so neither this nor its closures may be tied to the main actor.
    nonisolated private func recognizeText(in image: CGImage, languages: [String]) async throws -> [RecognizedTextLine] {
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

    /// The document tokens for the whole batch, from the text Vision reads on
    /// the first pages. Only runs for the tokens the template asks for; any
    /// failure leaves them empty so the export itself is never held up.
    private func documentNaming(for template: String, language: OCRLanguage, people: String, frames: [() throws -> PageFrame?]) async -> DocumentNaming {
        let wantsName = template.contains("{name}") && nameSuggester != nil
        let wantsAnalysis = Self.analysisTokens.contains(where: template.contains)
        guard wantsName || wantsAnalysis else { return DocumentNaming() }
        var pageTexts: [String] = []
        let pagesToRead = min(frames.count, 3)
        for (index, frame) in frames.prefix(pagesToRead).enumerated() {
            onProgress?(.readingText(page: index + 1, of: pagesToRead))
            guard let frame = try? frame(), let image = try? decode(frame), let lines = try? await recognizeText(in: image, languages: [language.visionCode]) else { continue }
            pageTexts.append(lines.map(\.text).joined(separator: "\n"))
            // {name} only needs the start; the document's date can be further down.
            if !wantsAnalysis, pageTexts.joined().count >= 400 { break }
        }
        onProgress?(.proposingName)
        var naming = DocumentNaming()
        if wantsName { naming.name = await nameSuggester?.suggestName(forText: pageTexts.joined(separator: "\n")) }
        // Pages are separated by form feeds, so the first page's dates count more.
        if wantsAnalysis { naming.metadata = await DocumentAnalysis.analyze(text: pageTexts.joined(separator: "\u{c}"), scanDate: Date(), people: people, model: documentModel) }
        return naming
    }

    /// `{date}` and `{time}` come from `date`, `{docdate}` from the document
    /// when its date was found; all use the profile's date and time formats.
    static func renderName(_ export: ExportSettings, date: Date, naming: DocumentNaming, page: Int?, side: String?) -> String {
        let metadata = naming.metadata ?? DocumentMetadata()
        let day = text(for: date, pattern: export.dateFormat, fallback: ExportSettings.defaultDateFormat)
        let time = text(for: date, pattern: export.timeFormat, fallback: ExportSettings.defaultTimeFormat)
        let documentDate = documentDay(metadata.date).map { text(for: $0, pattern: export.dateFormat, fallback: ExportSettings.defaultDateFormat) } ?? day
        var value = export.filenameTemplate
        for (token, text) in [("{date}", day), ("{time}", time), ("{name}", naming.name ?? DocumentName.fallback), ("{docdate}", documentDate), ("{sender}", metadata.sender), ("{type}", metadata.type), ("{subject}", metadata.subject), ("{person}", metadata.person), ("{page}", page.map { String(format: "%03d", $0) } ?? "batch"), ("{side}", side ?? "all")] {
            value = value.replacingOccurrences(of: token, with: text)
        }
        // A token that stayed empty must not leave doubled separators behind.
        value = value.replacing(/\ {2,}/, with: " ").replacing(/-{2,}/, with: "-").replacing(/_{2,}/, with: "_")
        let safe = value.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: " -_.").union(.whitespacesAndNewlines))
        return safe.isEmpty ? "Scan" : safe
    }

    private static func text(for date: Date, pattern: String, fallback: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : pattern
        return formatter.string(from: date)
    }

    /// `DocumentMetadata.date` is `yyyy-MM-dd`; noon keeps the day in every time zone.
    private static func documentDay(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
    private func uniqueURL(folder: URL, name: String, ext: String) -> URL { var url = folder.appendingPathComponent("\(name).\(ext)"); var counter = 2; while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(name)-\(counter).\(ext)"); counter += 1 }; return url }
    private func fileSize(_ url: URL) -> Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
}

private struct RecognizedTextLine: Sendable { let text: String; let normalizedBounds: CGRect }
