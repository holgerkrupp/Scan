import Foundation

/// One labelled value in the scanner details dialog.
struct ScannerDetailRow: Identifiable, Hashable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

/// A titled group of rows in the scanner details dialog.
struct ScannerDetailSection: Identifiable, Hashable, Sendable {
    let title: String
    let systemImage: String
    let rows: [ScannerDetailRow]
    var id: String { title }
}

/// Everything Scan knows about a discovered scanner without opening it:
/// discovery identity, the driver and model profile chosen for it, the
/// capabilities that driver advertises, hardware-button support, and the raw
/// IORegistry properties of the USB device. Building the sections is pure so
/// it can be tested without hardware.
struct ScannerDetails: Sendable {
    let identity: ScannerIdentity
    let driverName: String?
    let modelProfileName: String?
    let capabilities: ScannerCapabilities?
    let hardwareEvents: ScannerHardwareEventCapabilities?
    /// IORegistry properties of the USB device, already rendered as text.
    let usbRegistryProperties: [String: String]

    init(identity: ScannerIdentity, driverName: String? = nil, modelProfileName: String? = nil, capabilities: ScannerCapabilities? = nil, hardwareEvents: ScannerHardwareEventCapabilities? = nil, usbRegistryProperties: [String: String] = [:]) {
        self.identity = identity; self.driverName = driverName; self.modelProfileName = modelProfileName; self.capabilities = capabilities; self.hardwareEvents = hardwareEvents; self.usbRegistryProperties = usbRegistryProperties
    }

    var sections: [ScannerDetailSection] {
        [identitySection, driverSection, capabilitiesSection, featuresSection, hardwareButtonSection, usbRegistrySection].compactMap { $0 }
    }

    /// Plain-text rendering used by "Copy Details", e.g. for bug reports.
    var plainText: String {
        var lines = [identity.name]
        for section in sections {
            lines.append("")
            lines.append("[\(section.title)]")
            lines.append(contentsOf: section.rows.map { "\($0.label): \($0.value)" })
        }
        return lines.joined(separator: "\n")
    }

    private var identitySection: ScannerDetailSection {
        var rows = [
            ScannerDetailRow(label: "Name", value: identity.name),
            ScannerDetailRow(label: "Manufacturer", value: identity.manufacturer),
            ScannerDetailRow(label: "Model", value: identity.model),
            ScannerDetailRow(label: "Serial Number", value: Self.text(identity.serialNumber)),
            ScannerDetailRow(label: "Connection", value: identity.connectionKind.rawValue)
        ]
        if let usbDeviceID = identity.usbDeviceID {
            rows.append(ScannerDetailRow(label: "USB Vendor ID", value: String(format: "0x%04x", usbDeviceID.vendorID)))
            rows.append(ScannerDetailRow(label: "USB Product ID", value: String(format: "0x%04x", usbDeviceID.productID)))
        }
        if let locationID = identity.locationID { rows.append(ScannerDetailRow(label: "USB Location ID", value: String(format: "0x%08x", locationID))) }
        if let persistentID = identity.persistentID, !persistentID.isEmpty { rows.append(ScannerDetailRow(label: "Persistent ID", value: persistentID)) }
        rows.append(ScannerDetailRow(label: "Scan Identifier", value: identity.id))
        return ScannerDetailSection(title: "Identity", systemImage: "scanner", rows: rows)
    }

    private var driverSection: ScannerDetailSection {
        var rows = [ScannerDetailRow(label: "Driver", value: driverName ?? "No driver – discovered, unsupported")]
        if let modelProfileName { rows.append(ScannerDetailRow(label: "Model Profile", value: modelProfileName)) }
        if let reason = capabilities?.unsupportedReason { rows.append(ScannerDetailRow(label: "Limitation", value: reason)) }
        return ScannerDetailSection(title: "Driver", systemImage: "cpu", rows: rows)
    }

    private var capabilitiesSection: ScannerDetailSection? {
        guard let capabilities else { return nil }
        var rows = [
            ScannerDetailRow(label: "Sources", value: Self.list(capabilities.sources.map(\.rawValue))),
            ScannerDetailRow(label: "Color Modes", value: Self.list(capabilities.colorModes.map(\.rawValue))),
            ScannerDetailRow(label: "Resolutions", value: Self.dpiList(capabilities.resolutionsDPI))
        ]
        for source in capabilities.sources {
            if let resolutions = capabilities.resolutionsBySource[source] { rows.append(ScannerDetailRow(label: "Resolutions (\(source.rawValue))", value: Self.dpiList(resolutions))) }
        }
        rows.append(ScannerDetailRow(label: "Output Formats", value: Self.list(capabilities.outputFormats.map(\.rawValue))))
        if let area = capabilities.scanArea {
            rows.append(ScannerDetailRow(label: "Scan Area", value: "\(Self.number(area.width)) × \(Self.number(area.height)) \(area.unit)"))
        }
        return ScannerDetailSection(title: "Capabilities", systemImage: "slider.horizontal.3", rows: rows)
    }

    private var featuresSection: ScannerDetailSection? {
        guard let capabilities else { return nil }
        let features: [(String, Bool)] = [
            ("Duplex", capabilities.supportsDuplex),
            ("Scanner Buffering", capabilities.supportsScannerBuffering),
            ("Hardware JPEG Compression", capabilities.supportsHardwareCompression)
        ]
        return ScannerDetailSection(title: "Features", systemImage: "checklist", rows: features.map { ScannerDetailRow(label: $0.0, value: $0.1 ? "Yes" : "No") })
    }

    private var hardwareButtonSection: ScannerDetailSection? {
        guard let hardwareEvents else { return nil }
        return ScannerDetailSection(title: "Hardware Button", systemImage: "button.programmable", rows: [
            ScannerDetailRow(label: "Scan Button", value: hardwareEvents.scanButton.label),
            ScannerDetailRow(label: "One-Touch Scanning", value: hardwareEvents.supportsOneTouchScanning ? "Yes" : "No"),
            ScannerDetailRow(label: "Detail", value: hardwareEvents.detail)
        ])
    }

    private var usbRegistrySection: ScannerDetailSection? {
        guard !usbRegistryProperties.isEmpty else { return nil }
        let rows = usbRegistryProperties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ScannerDetailRow(label: $0, value: usbRegistryProperties[$0] ?? "") }
        return ScannerDetailSection(title: "USB Registry", systemImage: "cable.connector", rows: rows)
    }

    private static func text(_ value: String?) -> String { (value?.isEmpty == false ? value : nil) ?? "—" }
    private static func list(_ values: [String]) -> String { values.isEmpty ? "—" : values.joined(separator: ", ") }
    private static func dpiList(_ values: [Int]) -> String { values.isEmpty ? "—" : values.sorted().map(String.init).joined(separator: ", ") + " dpi" }
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
}

extension ScannerDriverRegistry {
    /// Collects the details for `identity` without opening the device, so it
    /// never competes with a running scan or hardware-button session.
    func details(for identity: ScannerIdentity, usbRegistryProperties: [String: String] = [:]) -> ScannerDetails {
        guard let driver = driver(for: identity) else { return ScannerDetails(identity: identity, usbRegistryProperties: usbRegistryProperties) }
        let device = driver.makeDevice(identity: identity, transport: nil)
        let modelProfileName: String? = switch device {
        case let fujitsu as FujitsuScanSnapDevice: fujitsu.profile.name
        case let epjitsu as EpjitsuScanSnapDevice: epjitsu.profile.name
        default: nil
        }
        return ScannerDetails(
            identity: identity,
            driverName: driver.name,
            modelProfileName: modelProfileName,
            capabilities: device.capabilities,
            hardwareEvents: (device as? ScannerHardwareEventSource)?.hardwareEventCapabilities,
            usbRegistryProperties: usbRegistryProperties
        )
    }
}

extension ScannerDetails: Identifiable {
    var id: String { identity.id }
}
