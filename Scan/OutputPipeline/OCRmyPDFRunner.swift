import Foundation

/// Languages offered for OCR, with the identifiers the two OCR engines use:
/// Vision's BCP 47 code and Tesseract's (and so ocrmypdf's) ISO 639-2 code.
nonisolated enum OCRLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
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

/// Which recognizer ocrmypdf uses for the text layer.
nonisolated enum OCRmyPDFEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Apple Live Text when the ocrmypdf-appleocr plugin is installed, Tesseract otherwise.
    case automatic = "Automatic"
    /// Apple Live Text through the ocrmypdf-appleocr plugin.
    case appleLiveText = "Apple Live Text"
    case tesseract = "Tesseract"
    var id: String { rawValue }
}

/// App-wide OCR preferences from the Settings window's Language section.
nonisolated struct OCRSettings: Codable, Equatable, Sendable {
    /// Default OCR language; German unless the user picks another.
    var language: OCRLanguage = .german
    /// Runs the `ocrmypdf` command-line tool on every exported PDF.
    var runOCRmyPDF = true
    var engine: OCRmyPDFEngine = .automatic
    /// Full path to `ocrmypdf` when it is not in a usual place; empty searches for it.
    var ocrmypdfPath = ""
    /// For `{person}`: one per line, `Shown name = text to find, other text`.
    var people = ""

    init(language: OCRLanguage = .german, runOCRmyPDF: Bool = true, engine: OCRmyPDFEngine = .automatic, ocrmypdfPath: String = "", people: String = "") {
        self.language = language; self.runOCRmyPDF = runOCRmyPDF; self.engine = engine; self.ocrmypdfPath = ocrmypdfPath; self.people = people
    }

    // Settings saved before a field existed must keep decoding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(OCRLanguage.self, forKey: .language) ?? .german
        runOCRmyPDF = try container.decodeIfPresent(Bool.self, forKey: .runOCRmyPDF) ?? true
        engine = try container.decodeIfPresent(OCRmyPDFEngine.self, forKey: .engine) ?? .automatic
        ocrmypdfPath = try container.decodeIfPresent(String.self, forKey: .ocrmypdfPath) ?? ""
        people = try container.decodeIfPresent(String.self, forKey: .people) ?? ""
    }
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
    /// `~/.local/bin` is where pipx installs it.
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", realHomeDirectory + "/.local/bin"]
    /// The user's own home: inside the sandbox `NSHomeDirectory()` is the app container.
    private static var realHomeDirectory: String { getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory() }

    let executableURL: URL

    /// Finds `ocrmypdf` at `customPath`, then in `directories` and `PATH`, or returns nil.
    static func locate(customPath: String = "", in directories: [String] = searchDirectories, environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> OCRmyPDFRunner? {
        let custom = (customPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !custom.isEmpty, fileManager.isExecutableFile(atPath: custom) { return OCRmyPDFRunner(executableURL: URL(fileURLWithPath: custom)) }
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
    /// `usesAppleOCR` recognizes with Apple Live Text through the
    /// ocrmypdf-appleocr plugin instead of Tesseract.
    static func arguments(input: URL, output: URL, language: OCRLanguage, usesAppleOCR: Bool = false) -> [String] {
        var arguments = ["--language", language.tesseractCode, "--skip-text", "--output-type", "pdf"]
        if usesAppleOCR { arguments += ["--ocr-engine", "appleocr", "--appleocr-recognition-mode", "livetext"] }
        return arguments + [input.path, output.path]
    }

    /// Whether the ocrmypdf-appleocr plugin is installed next to this ocrmypdf.
    func hasAppleOCR() async -> Bool {
        guard let result = try? await run(arguments: ["--help"], capturingOutput: true), result.status == 0 else { return false }
        return result.output.contains("appleocr")
    }

    /// Apple Live Text gave no answer in time, as happens while macOS
    /// prepares its text recognition models after an update.
    struct LiveTextTimeout: LocalizedError {
        var errorDescription: String? { "Apple Live Text did not respond." }
    }

    /// The error for a run of ocrmypdf on `fileName` that failed.
    static func failure(errorOutput: String, status: Int32, fileName: String) -> Error {
        if errorOutput.contains("Timeout in VKCImageAnalyzerRequest") { return LiveTextTimeout() }
        let detail = errorOutput.split(separator: "\n").last.map(String.init) ?? "exit status \(status)"
        return ScannerError.outputFailed("ocrmypdf failed for \(fileName): \(detail)")
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
    /// other files are ignored. `onFile` is told which PDF (1-based, of the
    /// PDFs in `urls`) is about to be processed.
    @discardableResult
    func process(_ urls: [URL], language: OCRLanguage, usesAppleOCR: Bool = false, onFile: (@MainActor @Sendable (Int, Int, URL) -> Void)? = nil) async throws -> [URL] {
        var processed: [URL] = []
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        for (index, url) in pdfs.enumerated() {
            await onFile?(index + 1, pdfs.count, url)
            let output = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-ocr-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await run(arguments: Self.arguments(input: url, output: output, language: language, usesAppleOCR: usesAppleOCR))
            guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
                throw Self.failure(errorOutput: result.errorOutput, status: result.status, fileName: url.lastPathComponent)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
            processed.append(url)
        }
        return processed
    }

    private func run(arguments: [String], capturingOutput: Bool = false) async throws -> (status: Int32, errorOutput: String, output: String) {
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
        let outputLog = FileManager.default.temporaryDirectory.appendingPathComponent("ocrmypdf-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: outputLog) }
        if capturingOutput {
            FileManager.default.createFile(atPath: outputLog.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: outputLog)
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ScannerError.outputFailed("Could not start ocrmypdf: \(error.localizedDescription)"))
            }
        }
        return (status, (try? String(contentsOf: errorLog, encoding: .utf8)) ?? "", (try? String(contentsOf: outputLog, encoding: .utf8)) ?? "")
    }
}
