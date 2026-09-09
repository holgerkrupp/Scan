import Foundation

/// Native, direct-bulk USB support for the ScanSnap S300 family.
///
/// The wire-level bootstrap sequence is independently implemented from the
/// public protocol behavior documented by SANE's `epjitsu` backend. The
/// scanner firmware remains Fujitsu's copyrighted software and is never
/// bundled with this app.
struct FujitsuScanSnapS300Driver: ScannerDriver {
    let name = "Fujitsu ScanSnap S300 direct USB (experimental)"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = [
        USBDeviceID(vendorID: 0x04c5, productID: 0x1156), // S300
        USBDeviceID(vendorID: 0x04c5, productID: 0x117f)  // S300M
    ]

    private let firmwareProvider: () throws -> Data?

    init(firmwareProvider: @escaping () throws -> Data? = {
        try ScanSnapS300FirmwareStore(defaults: .standard).loadFirmwarePayload()
    }) {
        self.firmwareProvider = firmwareProvider
    }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapS300Device(
            identity: identity,
            transport: transport,
            firmwareProvider: firmwareProvider
        )
    }
}

final class FujitsuScanSnapS300Device: ScannerDevice {
    let identity: ScannerIdentity
    let capabilities = ScannerCapabilities(
        sources: [.adfFront, .adfBack, .adfDuplex],
        colorModes: [.color],
        resolutionsDPI: [150, 200, 300, 600],
        scanArea: .init(width: 8.5, height: 11.5, unit: "inches"),
        supportsBlankPageRemoval: false,
        supportsDeskew: false,
        supportsAutoCrop: false,
        supportsAutoRotate: false,
        supportsDuplex: true,
        unsupportedReason: "Experimental: firmware bootstrap works, but calibrated image acquisition is not enabled yet."
    )

    private let transport: USBDeviceTransport?
    private let firmwareProvider: () throws -> Data?
    private var commandEngine: ScanSnapS300CommandEngine?
    private(set) var status: ScannerStatus = .disconnected

    init(
        identity: ScannerIdentity,
        transport: USBDeviceTransport?,
        firmwareProvider: @escaping () throws -> Data?
    ) {
        self.identity = identity
        self.transport = transport
        self.firmwareProvider = firmwareProvider
    }

    func open() async throws {
        guard let transport else {
            throw ScannerError.transportUnavailable("No USB transport was provided for \(identity.name).")
        }

        ScanTrace.post("Opening experimental S300 direct-USB session.")
        do {
            try await transport.open()
            let engine = ScanSnapS300CommandEngine(transport: transport)
            let scannerIdentity = try await engine.prepare(firmwarePayload: try firmwareProvider())
            commandEngine = engine
            status = .idle
            ScanTrace.post("S300 protocol identity: \(scannerIdentity.vendor) \(scannerIdentity.model).")
        } catch {
            await transport.close()
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func close() async {
        await transport?.close()
        commandEngine = nil
        status = .disconnected
    }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        try capabilities.validate(options)
        guard commandEngine != nil else {
            throw ScannerError.transportUnavailable("Open the S300 before starting a scan.")
        }
        throw ScannerError.protocolNotImplemented(
            "The S300 firmware and USB handshake succeeded. Calibrated image acquisition is still experimental and is not enabled in this build."
        )
    }

    func cancel() async {
        await transport?.abort()
        await close()
        status = .idle
    }
}

struct ScanSnapS300ProtocolIdentity: Equatable {
    let vendor: String
    let model: String
}

final class ScanSnapS300CommandEngine {
    static let firmwarePayloadLength = 0x10000

    private let transport: USBDeviceTransport
    private let commandTimeout: UInt32 = 10_000
    private let dataTimeout: UInt32 = 10_000

    init(transport: USBDeviceTransport) {
        self.transport = transport
    }

    func prepare(firmwarePayload: Data?) async throws -> ScanSnapS300ProtocolIdentity {
        var status = try await readStatus()
        if status & 0x10 == 0 {
            guard let firmwarePayload else {
                throw ScannerError.transportUnavailable(
                    "The ScanSnap S300 needs Fujitsu firmware. Choose 300_0C00.nal (or the S300M equivalent) in Diagnostics, then try again."
                )
            }
            try await uploadFirmware(firmwarePayload)
            status = try await readStatus()
            guard status & 0x10 != 0 else {
                throw ScannerError.transportUnavailable("The S300 did not report loaded firmware after upload.")
            }
        } else {
            ScanTrace.post("S300 firmware is already loaded.")
        }
        return try await readIdentity()
    }

    func readStatus() async throws -> UInt8 {
        try await write([0x1b, 0x03])
        let response = try await readExactly(2, label: "status")
        return response[response.startIndex]
    }

    func readIdentity() async throws -> ScanSnapS300ProtocolIdentity {
        try await write([0x1b, 0x13])
        let response = try await readExactly(0x20, label: "identity")
        let bytes = [UInt8](response)
        return ScanSnapS300ProtocolIdentity(
            vendor: Self.ascii(bytes[0..<8]),
            model: Self.ascii(bytes[8..<24])
        )
    }

    func uploadFirmware(_ payload: Data) async throws {
        guard payload.count == Self.firmwarePayloadLength else {
            throw ScannerError.transportUnavailable(
                "The selected S300 firmware payload is \(payload.count) bytes; expected \(Self.firmwarePayloadLength)."
            )
        }

        ScanTrace.post("Uploading user-supplied S300 firmware.")
        try await commandExpectingAcknowledgement([0x1b, 0x06], label: "firmware start")
        try await write([0x01, 0x00, 0x01, 0x00])
        try await transport.bulkWrite(endpoint: 0, data: payload, timeoutMilliseconds: dataTimeout)

        let checksum = payload.reduce(UInt8.zero) { partial, byte in
            partial &+ byte
        }
        try await commandExpectingAcknowledgement([checksum], label: "firmware checksum")
        try await commandExpectingAcknowledgement([0x1b, 0x16], label: "firmware reinitialize")
        try await commandExpectingAcknowledgement([0x80], label: "firmware reinitialize payload")
        ScanTrace.post("S300 firmware upload acknowledged.")
    }

    private func commandExpectingAcknowledgement(_ bytes: [UInt8], label: String) async throws {
        try await write(bytes)
        let response = try await readExactly(1, label: label)
        guard response.first == 0x06 else {
            let value = response.first.map { String(format: "0x%02x", $0) } ?? "none"
            throw ScannerError.transportUnavailable("S300 \(label) returned \(value), expected ACK 0x06.")
        }
    }

    private func write(_ bytes: [UInt8]) async throws {
        try await transport.bulkWrite(endpoint: 0, data: Data(bytes), timeoutMilliseconds: commandTimeout)
    }

    private func readExactly(_ length: Int, label: String) async throws -> Data {
        let data = try await transport.bulkRead(endpoint: 0, length: length, timeoutMilliseconds: dataTimeout)
        guard data.count == length else {
            throw ScannerError.transportUnavailable(
                "S300 \(label) returned \(data.count) bytes; expected \(length)."
            )
        }
        return data
    }

    private static func ascii(_ bytes: ArraySlice<UInt8>) -> String {
        let content = bytes.prefix { $0 != 0 && $0 != 0xff }
        return String(bytes: content, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
            ?? "Unknown"
    }
}

struct ScanSnapS300FirmwareStore {
    static let expectedFileNames = ["300_0C00.nal", "300M_0C00.nal"]

    private static let bookmarkKey = "scan.scansnapS300FirmwareBookmark"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var selectedFilename: String? {
        resolveBookmark()?.lastPathComponent
    }

    func saveFirmware(at url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        _ = try Self.extractPayload(from: Data(contentsOf: url))
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    func loadFirmwarePayload() throws -> Data? {
        guard let url = resolveBookmark() else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Self.extractPayload(from: Data(contentsOf: url))
    }

    static func extractPayload(from firmwareFile: Data) throws -> Data {
        let headerLength = 0x100
        let requiredLength = headerLength + ScanSnapS300CommandEngine.firmwarePayloadLength
        guard firmwareFile.count >= requiredLength else {
            throw ScannerError.transportUnavailable(
                "The selected file is too short to be S300 firmware (\(firmwareFile.count) bytes; expected at least \(requiredLength))."
            )
        }
        return firmwareFile.subdata(in: headerLength..<requiredLength)
    }

    private func resolveBookmark() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale, let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }
}
