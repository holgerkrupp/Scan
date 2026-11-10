import Foundation

/// How the scanner detects two or more sheets pulled in at once, e.g. pages
/// still held together by a staple. Maps onto the Fujitsu double-feed mode
/// page 0x38 as SANE's `mode_select_df()` does.
enum MultifeedDetection: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Leaves page 0x38 zeroed, which is what Scan sent before this option
    /// existed; the scanner then applies its power-on default.
    case scannerDefault
    case off
    /// Ultrasonic overlap sensor. Catches stapled or stuck-together sheets.
    case ultrasonic
    /// Compares the length of each sheet. Flags mixed paper sizes as well.
    case length
    case ultrasonicAndLength

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scannerDefault: "Scanner default"
        case .off: "Off"
        case .ultrasonic: "Ultrasonic (overlap)"
        case .length: "Paper length"
        case .ultrasonicAndLength: "Ultrasonic and paper length"
        }
    }

    var explanation: String {
        switch self {
        case .scannerDefault: "Scan does not change the scanner's own setting."
        case .off: "Sheets that are fed together are scanned as one page."
        case .ultrasonic: "Stops when sheets overlap, for example pages that are still stapled."
        case .length: "Stops when a sheet is longer or shorter than the previous one. Mixed batches such as receipts with A4 trigger it too."
        case .ultrasonicAndLength: "Strictest check. Mixed paper sizes stop the scan as well."
        }
    }

    /// Byte 2 of mode page 0x38: enable (bit 7), thickness (bit 4) and
    /// length (bit 3), following SANE's `set_MSEL_df_*` macros.
    var modePageFlags: UInt8 {
        switch self {
        case .scannerDefault: 0x00
        case .off: 0x80
        case .ultrasonic: 0x90
        case .length: 0x88
        case .ultrasonicAndLength: 0x98
        }
    }
}

/// Per-scanner paper-path safety options, edited in the scanner details
/// dialog and read by the driver whenever a scan starts.
struct ScannerFeedSettings: Codable, Hashable, Sendable {
    var multifeedDetection: MultifeedDetection = .ultrasonic
    /// Read `GET HW STATUS` before the first sheet and refuse to start while
    /// the cover is open or the scanner still reports an error.
    var checksSensorsBeforeScan = true

    init(multifeedDetection: MultifeedDetection = .ultrasonic, checksSensorsBeforeScan: Bool = true) {
        self.multifeedDetection = multifeedDetection
        self.checksSensorsBeforeScan = checksSensorsBeforeScan
    }

    /// The command flow before these options existed, which the recorded
    /// hardware transcripts pin.
    static let legacy = ScannerFeedSettings(multifeedDetection: .scannerDefault, checksSensorsBeforeScan: false)

    private enum CodingKeys: String, CodingKey { case multifeedDetection, checksSensorsBeforeScan }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        multifeedDetection = try container.decodeIfPresent(MultifeedDetection.self, forKey: .multifeedDetection) ?? .ultrasonic
        checksSensorsBeforeScan = try container.decodeIfPresent(Bool.self, forKey: .checksSensorsBeforeScan) ?? true
    }
}

struct ScannerFeedSettingsStore {
    private let defaults: UserDefaults
    private let keyPrefix = "scan.feedSettings."

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load(for identity: ScannerIdentity) -> ScannerFeedSettings {
        guard let data = defaults.data(forKey: keyPrefix + identity.id),
              let settings = try? JSONDecoder().decode(ScannerFeedSettings.self, from: data)
        else { return ScannerFeedSettings() }
        return settings
    }

    func save(_ settings: ScannerFeedSettings, for identity: ScannerIdentity) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: keyPrefix + identity.id)
    }
}
