import Foundation
import XCTest
@testable import Scan

/// Opt-in hardware validation for the native ScanSnap drivers.
///
/// These tests talk to a physically connected scanner and are skipped unless
/// `SCAN_HARDWARE_TESTS=1` is set in the test environment or in
/// `~/.scan-hardware-tests` (one `KEY=VALUE` per line). Optional knobs:
///
/// - `SCAN_HW_PRODUCT_ID` (hex, default `132b` for the iX500)
/// - `SCAN_HW_SOURCE` (`front`, `back`, `duplex`; default `front`)
/// - `SCAN_HW_MODE` (`color`, `gray`, `lineart`; default `color`)
/// - `SCAN_HW_DPI` (default `300`)
/// - `SCAN_HW_AUTOCROP` (`1` enables auto-crop, which turns on automatic length detection)
/// - `SCAN_HW_BUFFER` (`1` enables the scanner's ADF read-ahead buffering)
/// - `SCAN_HW_JPEG` (`1` asks the scanner for hardware JPEG), `SCAN_HW_JPEG_QUALITY` (export quality 0.4-1.0 that picks the Q argument)
/// - `SCAN_HW_OUTPUT_DIR` (directory that receives the page JPEGs and trace log)
///
/// Profile experiments on a Fujitsu SCSI-over-USB model, each optional and
/// applied on top of the registry profile so that quirks can be tried on a
/// new scanner without rebuilding: `SCAN_HW_PREREAD`, `SCAN_HW_QTABLE`,
/// `SCAN_HW_HOPPER`, `SCAN_HW_WAIT_AFTER_FEED`, `SCAN_HW_PROBE_INTERLACE`,
/// `SCAN_HW_TOLERATE_GAMMA` (`0`/`1`), `SCAN_HW_PPL_MOD` (colour width
/// modulus), `SCAN_HW_CHUNK` (bytes per image READ), `SCAN_HW_LUT_BITS`
/// (gamma table input width), `SCAN_HW_INTERNAL_GAMMA` (built-in gamma curve
/// instead of the downloaded linear table), `SCAN_HW_SANE_CANCEL` (SANE's cancel flow
/// instead of halt-then-cancel), `SCAN_HW_CAP_BUFFER` and `SCAN_HW_CAP_JPEG`
/// (`1` advertises the capability so `SCAN_HW_BUFFER`/`SCAN_HW_JPEG` take effect),
/// `SCAN_HW_NATIVE_MONO` (`1` asks the scanner for gray/line-art instead of
/// deriving them from colour), `SCAN_HW_RESOLUTIONS` (comma-separated dpi list
/// to advertise, e.g. to try 400 dpi).
///
/// An empty feeder is reported as a successful "pre-scan flow" run; every other
/// error fails the test. The full command trace is printed and written next to
/// the pages.
final class FujitsuScanSnapHardwareTests: XCTestCase {
    private final class TraceCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(forName: ScanTrace.notificationName, object: nil, queue: nil) { [weak self] note in
                guard let self, let message = note.userInfo?[ScanTrace.messageKey] as? String else { return }
                self.append(message)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func append(_ line: String) {
            let stamped = "[\(Self.formatter.string(from: Date()))] \(line)"
            lock.lock(); lines.append(stamped); lock.unlock()
            print("TRACE \(stamped)")
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }

        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()
    }

    /// Process environment merged with `~/.scan-hardware-tests` (KEY=VALUE per
    /// line). The file fallback exists because app-hosted test bundles do not
    /// reliably inherit `TEST_RUNNER_*` variables from `xcodebuild`.
    private var environment: [String: String] {
        var merged: [String: String] = [:]
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".scan-hardware-tests")
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
                merged[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
            }
        }
        merged.merge(ProcessInfo.processInfo.environment) { _, process in process }
        return merged
    }

    private func requireHardwareOptIn() throws {
        guard environment["SCAN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set SCAN_HARDWARE_TESTS=1 to run against a connected scanner.")
        }
    }

    private func connectedIdentity() async throws -> ScannerIdentity {
        let productID = UInt16(environment["SCAN_HW_PRODUCT_ID"] ?? "132b", radix: 16) ?? 0x132b
        let identities = await USBScannerDiscovery().discover()
        guard let identity = identities.first(where: { $0.usbDeviceID?.productID == productID }) else {
            throw XCTSkip("No Fujitsu scanner with product ID 0x\(String(productID, radix: 16)) is connected. Found: \(identities.map(\.subtitle)).")
        }
        return identity
    }

    private func requestedOptions() -> ScanOptions {
        let source: ScanSource = switch environment["SCAN_HW_SOURCE"]?.lowercased() {
        case "back": .adfBack
        case "duplex": .adfDuplex
        default: .adfFront
        }
        let mode: ScanColorMode = switch environment["SCAN_HW_MODE"]?.lowercased() {
        case "gray": .gray
        case "lineart": .lineart
        default: .color
        }
        let dpi = Int(environment["SCAN_HW_DPI"] ?? "") ?? 300
        // Auto-crop enables the scanner's automatic length detection (ALD),
        // so short documents come back with their real height instead of 14 in.
        let autoCrop = environment["SCAN_HW_AUTOCROP"] == "1"
        let buffering = environment["SCAN_HW_BUFFER"] == "1"
        let hardwareJPEG = environment["SCAN_HW_JPEG"] == "1"
        var options = ScanOptions(
            acquisition: AcquisitionSettings(source: source, colorMode: mode, resolutionDPI: dpi, scannerBuffering: buffering, hardwareCompression: hardwareJPEG),
            processing: ImageProcessingSettings(autoCrop: autoCrop)
        )
        if let quality = Double(environment["SCAN_HW_JPEG_QUALITY"] ?? "") {
            options.export.jpegQuality = quality
        }
        return options
    }

    private func flag(_ key: String) -> Bool? {
        guard let value = environment[key] else { return nil }
        return value == "1"
    }

    private func integer(_ key: String) -> Int? {
        environment[key].flatMap { Int($0) }
    }

    /// The registry profile with the `SCAN_HW_*` profile experiments applied,
    /// or `nil` when none is set.
    private func experimentalProfile(basedOn base: FujitsuScanSnapModelProfile) -> FujitsuScanSnapModelProfile? {
        let keys = ["SCAN_HW_PREREAD", "SCAN_HW_QTABLE", "SCAN_HW_HOPPER", "SCAN_HW_WAIT_AFTER_FEED", "SCAN_HW_PROBE_INTERLACE",
                    "SCAN_HW_TOLERATE_GAMMA", "SCAN_HW_PPL_MOD", "SCAN_HW_CHUNK", "SCAN_HW_LUT_BITS", "SCAN_HW_CAP_BUFFER", "SCAN_HW_CAP_JPEG",
                    "SCAN_HW_NATIVE_MONO", "SCAN_HW_RESOLUTIONS", "SCAN_HW_SANE_CANCEL", "SCAN_HW_INTERNAL_GAMMA"]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }
        let capabilities = base.capabilities
        return FujitsuScanSnapModelProfile(
            name: base.name + " (experiment)",
            usbDeviceIDs: base.usbDeviceIDs,
            capabilities: ScannerCapabilities(
                sources: capabilities.sources,
                colorModes: capabilities.colorModes,
                resolutionsDPI: environment["SCAN_HW_RESOLUTIONS"]?.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? capabilities.resolutionsDPI,
                resolutionsBySource: capabilities.resolutionsBySource,
                outputFormats: capabilities.outputFormats,
                scanArea: capabilities.scanArea,
                supportsBlankPageRemoval: capabilities.supportsBlankPageRemoval,
                supportsDeskew: capabilities.supportsDeskew,
                supportsAutoCrop: capabilities.supportsAutoCrop,
                supportsAutoRotate: capabilities.supportsAutoRotate,
                supportsDuplex: capabilities.supportsDuplex,
                supportsScannerBuffering: flag("SCAN_HW_CAP_BUFFER") ?? capabilities.supportsScannerBuffering,
                supportsHardwareCompression: flag("SCAN_HW_CAP_JPEG") ?? capabilities.supportsHardwareCompression,
                unsupportedReason: capabilities.unsupportedReason
            ),
            sendsDiagnosticPreread: flag("SCAN_HW_PREREAD") ?? base.sendsDiagnosticPreread,
            sendsJPEGQuantizationTable: flag("SCAN_HW_QTABLE") ?? base.sendsJPEGQuantizationTable,
            checksHopperBeforeFirstFeed: flag("SCAN_HW_HOPPER") ?? base.checksHopperBeforeFirstFeed,
            waitsForReadyAfterFeed: flag("SCAN_HW_WAIT_AFTER_FEED") ?? base.waitsForReadyAfterFeed,
            emulatesMonochromeInSoftware: flag("SCAN_HW_NATIVE_MONO").map { !$0 } ?? base.emulatesMonochromeInSoftware,
            pixelsPerLineModulus: integer("SCAN_HW_PPL_MOD") ?? base.pixelsPerLineModulus,
            lineartPixelsPerLineModulus: base.lineartPixelsPerLineModulus,
            probesColorInterlace: flag("SCAN_HW_PROBE_INTERLACE") ?? base.probesColorInterlace,
            toleratesModeSelectFailures: base.toleratesModeSelectFailures,
            toleratesGammaTableFailure: flag("SCAN_HW_TOLERATE_GAMMA") ?? base.toleratesGammaTableFailure,
            usesSANECancelFlow: flag("SCAN_HW_SANE_CANCEL") ?? base.usesSANECancelFlow,
            usesInternalGammaTable: flag("SCAN_HW_INTERNAL_GAMMA") ?? base.usesInternalGammaTable,
            transferChunkSize: integer("SCAN_HW_CHUNK") ?? base.transferChunkSize,
            lookupTableInputBits: integer("SCAN_HW_LUT_BITS") ?? base.lookupTableInputBits
        )
    }

    private func makeDevice(driver: ScannerDriver, identity: ScannerIdentity, transport: USBDeviceTransport, collector: TraceCollector) -> ScannerDevice {
        let device = driver.makeDevice(identity: identity, transport: transport)
        guard let fujitsu = device as? FujitsuScanSnapDevice, let profile = experimentalProfile(basedOn: fujitsu.profile) else {
            return device
        }
        collector.append("Profile experiment: native-mono \(!profile.emulatesMonochromeInSoftware), resolutions \(profile.capabilities.resolutionsDPI), preread \(profile.sendsDiagnosticPreread), q-table \(profile.sendsJPEGQuantizationTable), hopper \(profile.checksHopperBeforeFirstFeed), wait-after-feed \(profile.waitsForReadyAfterFeed), ppl-mod \(profile.pixelsPerLineModulus), probe-interlace \(profile.probesColorInterlace), tolerate-gamma \(profile.toleratesGammaTableFailure), sane-cancel \(profile.usesSANECancelFlow), internal-gamma \(profile.usesInternalGammaTable), chunk \(profile.transferChunkSize), lut-bits \(profile.lookupTableInputBits), cap-buffer \(profile.capabilities.supportsScannerBuffering), cap-jpeg \(profile.capabilities.supportsHardwareCompression)")
        return FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }

    private func outputDirectory() throws -> URL {
        let base = environment["SCAN_HW_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScanHardwareTests", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = base.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testOpenInquiryAndScanBatch() async throws {
        try requireHardwareOptIn()
        let identity = try await connectedIdentity()
        let collector = TraceCollector()
        let folder = try outputDirectory()
        collector.append("Output folder: \(folder.path)")
        collector.append("Identity: \(identity.name) \(identity.subtitle) location \(identity.locationID ?? 0)")

        let registry = ScannerDriverRegistry.live
        guard let driver = registry.driver(for: identity) else {
            return XCTFail("No native driver claims \(identity.subtitle).")
        }
        collector.append("Driver: \(driver.name)")

        let transport = IOKitUSBDeviceTransport(identity: identity)
        let device = makeDevice(driver: driver, identity: identity, transport: transport, collector: collector)
        let options = requestedOptions()
        collector.append("Options: \(options.source.rawValue), \(options.colorMode.rawValue), \(options.resolutionDPI) dpi, auto-crop \(options.autoCrop), buffering \(options.acquisition.scannerBuffering), hardware JPEG \(options.acquisition.hardwareCompression) (export quality \(options.export.jpegQuality))")

        defer {
            let logURL = folder.appendingPathComponent("trace.log")
            try? collector.text.write(to: logURL, atomically: true, encoding: .utf8)
            print("Trace written to \(logURL.path)")
        }

        do {
            try await device.open()
            collector.append("Endpoints: \(await transport.endpointSummary)")
        } catch {
            await device.close()
            return XCTFail("Open failed: \(error.localizedDescription)")
        }

        var pages: [PageFrame] = []
        var outcome = "completed"
        do {
            let stream = try await device.startScan(options: options)
            for try await frame in stream {
                pages.append(frame)
                let url = folder.appendingPathComponent(String(format: "page-%02d-%@.jpg", frame.pageIndex, frame.side.rawValue))
                try frame.data.write(to: url)
                collector.append("Page \(frame.pageIndex) \(frame.side.rawValue): \(frame.width)x\(frame.height) @ \(frame.resolutionDPI) dpi, \(frame.data.count) bytes JPEG -> \(url.lastPathComponent)")
            }
        } catch let error as ScannerError where error == .feederEmpty {
            outcome = "feeder empty (pre-scan command flow succeeded)"
        } catch {
            await device.close()
            return XCTFail("Scan failed after \(pages.count) page(s): \(error.localizedDescription)")
        }
        await device.close()

        collector.append("Result: \(outcome), \(pages.count) page(s).")
        if outcome == "completed" {
            XCTAssertFalse(pages.isEmpty, "Scan completed without any pages.")
            for frame in pages {
                XCTAssertNotNil(NSImage(data: frame.data), "Page \(frame.pageIndex) did not decode as an image.")
                XCTAssertEqual(frame.resolutionDPI, options.resolutionDPI)
            }
        }
    }

    /// Dumps the scanner's vital product data (INQUIRY EVPD page 0xf0) so a
    /// new model's capabilities can be compared with its profile.
    func testDumpVitalProductData() async throws {
        try requireHardwareOptIn()
        let identity = try await connectedIdentity()
        let collector = TraceCollector()
        let folder = try outputDirectory()
        guard let driver = ScannerDriverRegistry.live.driver(for: identity) else {
            return XCTFail("No native driver claims \(identity.subtitle).")
        }
        let transport = IOKitUSBDeviceTransport(identity: identity)
        guard let device = driver.makeDevice(identity: identity, transport: transport) as? FujitsuScanSnapDevice else {
            throw XCTSkip("\(driver.name) is not a Fujitsu SCSI-over-USB driver.")
        }
        defer {
            try? collector.text.write(to: folder.appendingPathComponent("vpd.log"), atomically: true, encoding: .utf8)
        }
        try await device.open()
        do {
            let vpd = try await device.readVitalProductData()
            collector.append("Identity: \(identity.name) \(identity.subtitle)")
            collector.append(vpd.summary)
            collector.append("\n" + vpd.hexDump)
            XCTAssertGreaterThanOrEqual(vpd.bytes.count, 0x5f, "VPD shorter than SANE's minimum")
        } catch {
            await device.close()
            return XCTFail("VPD inquiry failed: \(error.localizedDescription)")
        }
        await device.close()
    }
}
