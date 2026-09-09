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
/// - `SCAN_HW_OUTPUT_DIR` (directory that receives the page JPEGs and trace log)
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
        return ScanOptions(
            acquisition: AcquisitionSettings(source: source, colorMode: mode, resolutionDPI: dpi, scannerBuffering: buffering),
            processing: ImageProcessingSettings(autoCrop: autoCrop)
        )
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
        let device = driver.makeDevice(identity: identity, transport: transport)
        let options = requestedOptions()
        collector.append("Options: \(options.source.rawValue), \(options.colorMode.rawValue), \(options.resolutionDPI) dpi, auto-crop \(options.autoCrop), buffering \(options.acquisition.scannerBuffering)")

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
}
