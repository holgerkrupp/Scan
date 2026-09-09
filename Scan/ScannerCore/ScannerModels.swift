import Foundation

enum ScanTrace {
    static let notificationName = Notification.Name("ScanTraceNotification")
    static let messageKey = "message"
    static func post(_ message: String) { NotificationCenter.default.post(name: notificationName, object: nil, userInfo: [messageKey: message]) }
}

struct USBDeviceID: Hashable, Sendable, Codable {
    let vendorID: UInt16
    let productID: UInt16
    var displayString: String { String(format: "0x%04x/0x%04x", vendorID, productID) }
}

enum ScannerConnectionKind: String, Sendable, Codable { case usb = "USB"; case imageCapture = "Image Capture" }

struct ScannerIdentity: Identifiable, Hashable, Sendable, Codable {
    let name: String
    let manufacturer: String
    let model: String
    let serialNumber: String?
    let connectionKind: ScannerConnectionKind
    let usbDeviceID: USBDeviceID?
    let locationID: UInt32?
    let persistentID: String?
    var id: String {
        if let persistentID, !persistentID.isEmpty { return "\(connectionKind.rawValue)-\(persistentID)" }
        return "\(connectionKind.rawValue)-\(usbDeviceID?.displayString ?? name)-\(serialNumber ?? "unknown")-\(locationID ?? 0)"
    }
    init(name: String, manufacturer: String, model: String, serialNumber: String?, connectionKind: ScannerConnectionKind, usbDeviceID: USBDeviceID?, locationID: UInt32?, persistentID: String? = nil) {
        self.name = name; self.manufacturer = manufacturer; self.model = model; self.serialNumber = serialNumber; self.connectionKind = connectionKind; self.usbDeviceID = usbDeviceID; self.locationID = locationID; self.persistentID = persistentID
    }
    var subtitle: String {
        let idText = usbDeviceID?.displayString ?? connectionKind.rawValue
        if let serialNumber, !serialNumber.isEmpty { return "\(idText) - \(serialNumber)" }
        return idText
    }
}

enum ScanSource: String, CaseIterable, Identifiable, Sendable, Codable { case adfFront = "ADF Front"; case adfBack = "ADF Back"; case adfDuplex = "ADF Duplex"; case flatbed = "Flatbed"; var id: String { rawValue } }
enum ScanColorMode: String, CaseIterable, Identifiable, Sendable, Codable { case color = "Color"; case gray = "Gray"; case lineart = "Lineart"; var id: String { rawValue } }
enum ScanOutputFormat: String, CaseIterable, Identifiable, Sendable, Codable { case pdf = "PDF"; case searchablePDF = "Searchable PDF"; case jpeg = "JPEG"; case png = "PNG"; case tiff = "TIFF"; var id: String { rawValue } }
enum ScanExportMode: String, CaseIterable, Identifiable, Sendable, Codable { case combinedPDF = "One combined PDF"; case separateFiles = "Separate per-page files"; var id: String { rawValue } }

enum ScanFileSizePreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case small = "Small", balanced = "Balanced", highQuality = "High Quality", lossless = "Lossless", custom = "Custom"
    var id: String { rawValue }
    /// Preset contract: output DPI, output color, lossy quality, and lossless choice.
    var documentedMapping: (outputDPI: Int, colorMode: ScanColorMode, quality: Double, lossless: Bool) {
        switch self { case .small: (150, .gray, 0.70, false); case .balanced: (200, .gray, 0.82, false); case .highQuality: (300, .color, 0.92, false); case .lossless: (600, .color, 1.0, true); case .custom: (0, .color, 0.90, false) }
    }
}

enum PageRotation: Int, CaseIterable, Identifiable, Sendable, Codable { case degrees0 = 0, degrees90 = 90, degrees180 = 180, degrees270 = 270; var id: Int { rawValue } }

struct AcquisitionSettings: Hashable, Sendable, Codable { var source: ScanSource = .adfDuplex; var colorMode: ScanColorMode = .color; var resolutionDPI: Int = 300 }
struct ImageProcessingSettings: Hashable, Sendable, Codable {
    var removeBlankPages = false; var autoCrop = false; var deskew = false; var autoRotate = false; var rotation: PageRotation = .degrees0
}
struct ExportSettings: Hashable, Sendable, Codable {
    var outputFormat: ScanOutputFormat = .pdf
    var sizePreset: ScanFileSizePreset = .balanced
    var outputDPI: Int = 200
    var jpegQuality: Double = 0.82
    var exportMode: ScanExportMode = .combinedPDF
    var filenameTemplate = "Scan-{date}-{page}"
    var ocrLanguages: [String] = ["en-US"]
    var automaticallySaveAfterScanning = true
}

struct ScanOptions: Hashable, Sendable, Codable {
    var acquisition: AcquisitionSettings
    var processing: ImageProcessingSettings
    var export: ExportSettings
    init(acquisition: AcquisitionSettings = .init(), processing: ImageProcessingSettings = .init(), export: ExportSettings = .init()) { self.acquisition = acquisition; self.processing = processing; self.export = export }
    // Compatibility accessors retain the proven S1500 command code API.
    var source: ScanSource { get { acquisition.source } set { acquisition.source = newValue } }
    var colorMode: ScanColorMode { get { acquisition.colorMode } set { acquisition.colorMode = newValue } }
    var resolutionDPI: Int { get { acquisition.resolutionDPI } set { acquisition.resolutionDPI = newValue } }
    var outputFormat: ScanOutputFormat { get { export.outputFormat } set { export.outputFormat = newValue } }
    var removeBlankPages: Bool { get { processing.removeBlankPages } set { processing.removeBlankPages = newValue } }
    var deskew: Bool { get { processing.deskew } set { processing.deskew = newValue } }
    var autoCrop: Bool { get { processing.autoCrop } set { processing.autoCrop = newValue } }
    var autoRotate: Bool { get { processing.autoRotate } set { processing.autoRotate = newValue } }
    mutating func applyPreset(_ preset: ScanFileSizePreset) { export.sizePreset = preset; guard preset != .custom else { return }; let mapping = preset.documentedMapping; export.outputDPI = mapping.outputDPI; export.jpegQuality = mapping.quality; acquisition.colorMode = mapping.colorMode }
}

struct ScanProfile: Identifiable, Hashable, Sendable, Codable {
    let id: UUID; var name: String; var options: ScanOptions
    init(id: UUID = UUID(), name: String, options: ScanOptions) { self.id = id; self.name = name; self.options = options }
    static let defaults: [ScanProfile] = [
        ScanProfile(name: "Duplex PDF 300 dpi color", options: ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .color, resolutionDPI: 300), processing: ImageProcessingSettings(removeBlankPages: true, autoCrop: true, deskew: true, autoRotate: true), export: ExportSettings(outputFormat: .pdf, sizePreset: .highQuality, outputDPI: 300, jpegQuality: 0.92))),
        ScanProfile(name: "Duplex searchable PDF", options: ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .color, resolutionDPI: 300), processing: ImageProcessingSettings(removeBlankPages: true, autoCrop: true, deskew: true, autoRotate: true), export: ExportSettings(outputFormat: .searchablePDF, sizePreset: .highQuality, outputDPI: 300, jpegQuality: 0.92, ocrLanguages: ["en-US"]))),
        ScanProfile(name: "Single-sided JPEG", options: ScanOptions(acquisition: AcquisitionSettings(source: .adfFront, colorMode: .color, resolutionDPI: 300), export: ExportSettings(outputFormat: .jpeg, sizePreset: .highQuality, outputDPI: 300, jpegQuality: 0.92, exportMode: .separateFiles)))
    ]
}

struct ScannerCapabilities: Equatable, Sendable, Codable {
    struct ScanArea: Equatable, Sendable, Codable { let width: Double; let height: Double; let unit: String }
    let sources: [ScanSource]; let colorModes: [ScanColorMode]; let resolutionsDPI: [Int]; let outputFormats: [ScanOutputFormat]
    /// Some Image Capture devices expose different resolution sets for the
    /// flatbed and document feeder.  Keep that distinction rather than
    /// advertising a union that may fail after the user has selected a source.
    let resolutionsBySource: [ScanSource: [Int]]
    let scanArea: ScanArea?
    let supportsBlankPageRemoval: Bool; let supportsDeskew: Bool; let supportsAutoCrop: Bool; let supportsAutoRotate: Bool; let supportsDuplex: Bool; let unsupportedReason: String?
    init(sources: [ScanSource], colorModes: [ScanColorMode], resolutionsDPI: [Int], resolutionsBySource: [ScanSource: [Int]] = [:], outputFormats: [ScanOutputFormat] = ScanOutputFormat.allCases, scanArea: ScanArea? = nil, supportsBlankPageRemoval: Bool, supportsDeskew: Bool, supportsAutoCrop: Bool, supportsAutoRotate: Bool = true, supportsDuplex: Bool, unsupportedReason: String? = nil) {
        self.sources = sources; self.colorModes = colorModes; self.resolutionsDPI = resolutionsDPI; self.resolutionsBySource = resolutionsBySource; self.outputFormats = outputFormats; self.scanArea = scanArea; self.supportsBlankPageRemoval = supportsBlankPageRemoval; self.supportsDeskew = supportsDeskew; self.supportsAutoCrop = supportsAutoCrop; self.supportsAutoRotate = supportsAutoRotate; self.supportsDuplex = supportsDuplex; self.unsupportedReason = unsupportedReason
    }
    func resolutions(for source: ScanSource) -> [Int] { resolutionsBySource[source] ?? resolutionsDPI }
    func validate(_ options: ScanOptions) throws {
        guard sources.contains(options.acquisition.source) else { throw ScannerError.unsupportedOption("Source \(options.acquisition.source.rawValue) is not supported.") }
        guard colorModes.contains(options.acquisition.colorMode) else { throw ScannerError.unsupportedOption("Mode \(options.acquisition.colorMode.rawValue) is not supported.") }
        guard resolutions(for: options.acquisition.source).contains(options.acquisition.resolutionDPI) else { throw ScannerError.unsupportedOption("Resolution \(options.acquisition.resolutionDPI) dpi is not supported for \(options.acquisition.source.rawValue).") }
        guard outputFormats.contains(options.export.outputFormat) else { throw ScannerError.unsupportedOption("\(options.export.outputFormat.rawValue) output is not supported by this scanner backend.") }
        if options.acquisition.source == .adfDuplex && !supportsDuplex { throw ScannerError.unsupportedOption("Duplex scanning is not supported.") }
        if options.processing.removeBlankPages && !supportsBlankPageRemoval { throw ScannerError.unsupportedOption("Blank-page removal is not available for this scanner.") }
        if options.processing.deskew && !supportsDeskew { throw ScannerError.unsupportedOption("Deskew is not available for this scanner.") }
        if options.processing.autoCrop && !supportsAutoCrop { throw ScannerError.unsupportedOption("Auto-crop is not available for this scanner.") }
        if options.processing.autoRotate && !supportsAutoRotate { throw ScannerError.unsupportedOption("Automatic orientation is not available for this scanner.") }
    }
}

enum PageSide: String, Sendable, Codable { case front, back, unknown }
enum PagePixelFormat: String, Sendable, Codable { case jpeg, png, tiff, rgb8, gray8, unknown }
struct PageFrame: Identifiable, Sendable, Codable { let id: UUID; let pageIndex: Int; let side: PageSide; let pixelFormat: PagePixelFormat; let width: Int; let height: Int; let resolutionDPI: Int; let data: Data; init(id: UUID = UUID(), pageIndex: Int, side: PageSide, pixelFormat: PagePixelFormat, width: Int, height: Int, resolutionDPI: Int, data: Data) { self.id = id; self.pageIndex = pageIndex; self.side = side; self.pixelFormat = pixelFormat; self.width = width; self.height = height; self.resolutionDPI = resolutionDPI; self.data = data } }
struct StoredPage: Identifiable, Sendable { let id: UUID; let pageIndex: Int; let side: PageSide; let pixelFormat: PagePixelFormat; let width: Int; let height: Int; let resolutionDPI: Int; let fileURL: URL; nonisolated init(frame: PageFrame, fileURL: URL) { id = frame.id; pageIndex = frame.pageIndex; side = frame.side; pixelFormat = frame.pixelFormat; width = frame.width; height = frame.height; resolutionDPI = frame.resolutionDPI; self.fileURL = fileURL } }

enum ScannerStatus: Equatable, Sendable {
    case disconnected, idle, scanning(progress: Double?, pagesScanned: Int), error(String)
    var displayText: String { switch self { case .disconnected: "No scanner connected"; case .idle: "Ready"; case let .scanning(progress, pages): if let progress { "Scanning \(pages) page\(pages == 1 ? "" : "s") - \(Int(progress * 100))%" } else { "Scanning \(pages) page\(pages == 1 ? "" : "s")" }; case let .error(message): message } }
}
struct ScanJobResult: Sendable { let outputURLs: [URL]; let pagesScanned: Int; let outputByteCount: Int64 }
enum ScannerError: LocalizedError, Equatable {
    case deviceNotFound, feederEmpty, unsupportedDevice(String), unsupportedOption(String), transportUnavailable(String), protocolNotImplemented(String), scanCancelled, outputFailed(String)
    var errorDescription: String? { switch self { case .deviceNotFound: "No compatible scanner was found."; case .feederEmpty: "The document feeder is empty."; case let .unsupportedDevice(message), let .unsupportedOption(message), let .transportUnavailable(message), let .protocolNotImplemented(message), let .outputFailed(message): message; case .scanCancelled: "The scan was cancelled." } }
}

struct ScanProfileStore {
    private let defaults: UserDefaults; private let key = "scan.profiles.v2"; private let selectedKey = "scan.selectedProfile"
    init(defaults: UserDefaults) { self.defaults = defaults }
    func load() -> [ScanProfile] { guard let data = defaults.data(forKey: key), let profiles = try? JSONDecoder().decode([ScanProfile].self, from: data), !profiles.isEmpty else { return ScanProfile.defaults }; return profiles }
    func save(_ profiles: [ScanProfile]) { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: key) } }
    var selectedProfileID: UUID? { get { defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)) } set { defaults.set(newValue?.uuidString, forKey: selectedKey) } }
}
