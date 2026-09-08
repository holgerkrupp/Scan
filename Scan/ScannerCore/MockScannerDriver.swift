import AppKit
import Foundation

struct MockScannerDriver: ScannerDriver {
    let name = "Scanner Simulator"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = []

    func canDrive(_ identity: ScannerIdentity) -> Bool {
        identity.connectionKind == .simulated
    }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        MockScannerDevice(identity: identity)
    }

    static let identity = ScannerIdentity(
        name: "Scanner Simulator",
        manufacturer: "Scan",
        model: "Mock ADF Duplex (mixed blank pages)",
        serialNumber: "SIMULATED",
        connectionKind: .simulated,
        usbDeviceID: nil,
        locationID: nil
    )

    static let limitedIdentity = ScannerIdentity(
        name: "Scanner Simulator (limited)", manufacturer: "Scan", model: "Mock simplex gray", serialNumber: "SIM-LIMITED", connectionKind: .simulated, usbDeviceID: nil, locationID: nil
    )
}

final class MockScannerDevice: ScannerDevice {
    let identity: ScannerIdentity
    let capabilities: ScannerCapabilities

    private(set) var status: ScannerStatus = .disconnected
    private var cancelled = false

    init(identity: ScannerIdentity) {
        self.identity = identity
        if identity.serialNumber == "SIM-LIMITED" {
            capabilities = ScannerCapabilities(sources: [.adfFront], colorModes: [.gray], resolutionsDPI: [150, 200], outputFormats: [.pdf, .jpeg, .png], supportsBlankPageRemoval: false, supportsDeskew: false, supportsAutoCrop: true, supportsAutoRotate: true, supportsDuplex: false)
        } else {
            capabilities = ScannerCapabilities(sources: [.adfFront, .adfDuplex], colorModes: [.color, .gray], resolutionsDPI: [150, 200, 300], supportsBlankPageRemoval: true, supportsDeskew: true, supportsAutoCrop: true, supportsDuplex: true)
        }
    }

    func open() async throws {
        status = .idle
        cancelled = false
    }

    func close() async {
        status = .disconnected
    }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        try capabilities.validate(options)
        cancelled = false
        status = .scanning(progress: 0, pagesScanned: 0)

        let pageCount = options.source == .adfDuplex ? 4 : 2
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for index in 0..<pageCount {
                        if Task.isCancelled || self.cancelled {
                            throw ScannerError.scanCancelled
                        }
                        try await Task.sleep(for: .milliseconds(350))
                        let side: PageSide = options.source == .adfDuplex
                            ? (index.isMultiple(of: 2) ? .front : .back)
                            : .front
                        let data = try Self.makeSampleJPEG(pageIndex: index + 1, side: side, options: options, blank: self.identity.serialNumber != "SIM-LIMITED" && index == 1)
                        self.status = .scanning(
                            progress: Double(index + 1) / Double(pageCount),
                            pagesScanned: index + 1
                        )
                        continuation.yield(
                            PageFrame(
                                pageIndex: index + 1,
                                side: side,
                                pixelFormat: .jpeg,
                                width: 1240,
                                height: 1754,
                                resolutionDPI: options.resolutionDPI,
                                data: data
                            )
                        )
                    }
                    self.status = .idle
                    continuation.finish()
                } catch {
                    self.status = .error(error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancel() async {
        cancelled = true
        status = .idle
    }

    private static func makeSampleJPEG(pageIndex: Int, side: PageSide, options: ScanOptions, blank: Bool) throws -> Data {
        let size = NSSize(width: 1240, height: 1754)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.textBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        if !blank {
            let accent = side == .front ? NSColor.systemBlue : NSColor.systemGreen
            accent.setFill()
            NSBezierPath(rect: NSRect(x: 80, y: 80, width: 18, height: size.height - 160)).fill()

            let title = "Sample page \(pageIndex)"
            let subtitle = "\(side.rawValue.capitalized) - \(options.resolutionDPI) dpi - \(options.colorMode.rawValue)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 54, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
            title.draw(at: NSPoint(x: 140, y: size.height - 220), withAttributes: attributes)
            subtitle.draw(
            at: NSPoint(x: 140, y: size.height - 300),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 28),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            )

            for row in 0..<14 {
            let y = size.height - 420 - CGFloat(row * 72)
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 140, y: y))
            path.line(to: NSPoint(x: size.width - 140, y: y))
            path.lineWidth = 2
            path.stroke()
            }
        }

        image.unlockFocus()

        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        else {
            throw ScannerError.outputFailed("Could not render simulator page.")
        }
        return data
    }
}
