import Foundation

/// Languages offered for OCR, with the identifiers the two OCR engines use:
/// Vision's BCP 47 code and Tesseract's (and so ocrmypdf's) ISO 639-2 code.
enum OCRLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case german, english, french, spanish, italian, dutch, polish, portuguese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .german: "German (Deutsch)"
        case .english: "English"
        case .french: "French (Français)"
        case .spanish: "Spanish (Español)"
        case .italian: "Italian (Italiano)"
        case .dutch: "Dutch (Nederlands)"
        case .polish: "Polish (Polski)"
        case .portuguese: "Portuguese (Português)"
        }
    }

    var visionCode: String {
        switch self {
        case .german: "de-DE"; case .english: "en-US"; case .french: "fr-FR"; case .spanish: "es-ES"
        case .italian: "it-IT"; case .dutch: "nl-NL"; case .polish: "pl-PL"; case .portuguese: "pt-PT"
        }
    }

    var tesseractCode: String {
        switch self {
        case .german: "deu"; case .english: "eng"; case .french: "fra"; case .spanish: "spa"
        case .italian: "ita"; case .dutch: "nld"; case .polish: "pol"; case .portuguese: "por"
        }
    }
}

/// App-wide OCR preferences from the Settings window's Language section.
struct OCRSettings: Codable, Equatable, Sendable {
    /// Default OCR language; German unless the user picks another.
    var language: OCRLanguage = .german
    /// Runs the `ocrmypdf` command-line tool on every exported PDF.
    var runOCRmyPDF = true
}

struct OCRSettingsStore {
    private let defaults: UserDefaults
    private let key = "scan.ocrSettings.v1"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> OCRSettings {
        guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(OCRSettings.self, from: data) else { return OCRSettings() }
        return settings
    }

    func save(_ settings: OCRSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Adds a text layer to exported PDFs with the `ocrmypdf` command-line tool
/// (Tesseract based). Each PDF is written to a temporary file next to it and
/// swapped in only when ocrmypdf succeeds, so a failure never damages a scan.
nonisolated struct OCRmyPDFRunner: Sendable {
    /// Where package managers install ocrmypdf; GUI apps do not inherit the
    /// shell's PATH, so these are searched explicitly. The sandboxed Release
    /// build can only see them through the read-only exception in
    /// Scan.entitlements, so keep the two lists in step.
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    let executableURL: URL

    /// Finds `ocrmypdf` in `directories` (then in `PATH`), or returns nil.
    static func locate(in directories: [String] = searchDirectories, environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> OCRmyPDFRunner? {
        let pathDirectories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in directories + pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ocrmypdf")
            if fileManager.isExecutableFile(atPath: candidate.path) { return OCRmyPDFRunner(executableURL: candidate) }
        }
        return nil
    }

    /// Arguments for one PDF. `--skip-text` leaves pages that already carry
    /// text alone (e.g. a "Searchable PDF" export made with Vision) instead
    /// of failing on them.
    static func arguments(input: URL, output: URL, language: OCRLanguage) -> [String] {
        ["--language", language.tesseractCode, "--skip-text", "--output-type", "pdf", input.path, output.path]
    }

    /// PATH for the child process: ocrmypdf itself calls tesseract and
    /// ghostscript, which live next to it rather than in the GUI app's PATH.
    func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let existing = base["PATH"].map { [$0] } ?? []
        environment["PATH"] = ([executableURL.deletingLastPathComponent().path] + Self.searchDirectories + existing + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return environment
    }

    /// OCRs each PDF in `urls` in place and returns the PDFs it processed;
    /// other files are ignored.
    @discardableResult
    func process(_ urls: [URL], language: OCRLanguage) async throws -> [URL] {
        var processed: [URL] = []
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let output = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-ocr-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await run(arguments: Self.arguments(input: url, output: output, language: language))
            guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
                let detail = result.errorOutput.split(separator: "\n").last.map(String.init) ?? "exit status \(result.status)"
                throw ScannerError.outputFailed("ocrmypdf failed for \(url.lastPathComponent): \(detail)")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
            processed.append(url)
        }
        return processed
    }

    private func run(arguments: [String]) async throws -> (status: Int32, errorOutput: String) {
        // stderr goes to a file: a pipe that is only read at exit could fill
        // up on a verbose run and block ocrmypdf forever.
        let errorLog = FileManager.default.temporaryDirectory.appendingPathComponent("ocrmypdf-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorLog) }
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment()
        process.standardError = errorHandle
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ScannerError.outputFailed("Could not start ocrmypdf: \(error.localizedDescription)"))
            }
        }
        return (status, (try? String(contentsOf: errorLog, encoding: .utf8)) ?? "")
    }
}
