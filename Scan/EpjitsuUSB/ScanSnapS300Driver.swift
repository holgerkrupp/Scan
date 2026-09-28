import Foundation

/// The direct-bulk USB ScanSnap family described by SANE's `epjitsu` backend.
///
/// This is an independent Swift implementation of the observable bootstrap
/// protocol. Fujitsu firmware is copyrighted and is never bundled here.
enum EpjitsuHardwareButtonInterpretation: Equatable, Sendable {
    case s300Byte1Bit0
    case unvalidated
}

/// Model data belongs here rather than in the protocol engine. That keeps the
/// common bootstrap/status path ready for additional epjitsu models without
/// making the engine guess from a display name.
struct EpjitsuScanSnapModelProfile: Equatable, Sendable {
    let name: String
    let usbDeviceIDs: Set<USBDeviceID>
    let expectedFirmwareFileNames: [String]
    let firmwareBookmarkKey: String
    let capabilities: ScannerCapabilities
    let supportsDuplex: Bool
    let hardwareButtonSupport: ScannerHardwareEventSupportState
    let supportsOneTouchScanning: Bool
    let hardwareButtonInterpretation: EpjitsuHardwareButtonInterpretation
    let hardwareStatusResponseLength: Int

    static let s300 = EpjitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S300",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x1156)],
        expectedFirmwareFileNames: ["300_0C00.nal"],
        firmwareBookmarkKey: "scan.epjitsu.s300FirmwareBookmark",
        supportsDuplex: true,
        hardwareButtonSupport: .supportedUnvalidated,
        supportsOneTouchScanning: false,
        hardwareButtonInterpretation: .s300Byte1Bit0
    )

    static let s300M = EpjitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S300M",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x117f)],
        expectedFirmwareFileNames: ["300M_0C00.nal"],
        firmwareBookmarkKey: "scan.epjitsu.s300MFirmwareBookmark",
        supportsDuplex: true,
        hardwareButtonSupport: .supportedUnvalidated,
        supportsOneTouchScanning: false,
        hardwareButtonInterpretation: .s300Byte1Bit0
    )

    static let s1300 = EpjitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S1300",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x11ed)],
        expectedFirmwareFileNames: ["1300_0C26.nal"],
        firmwareBookmarkKey: "scan.epjitsu.s1300FirmwareBookmark",
        supportsDuplex: true,
        hardwareButtonSupport: .supportedUnvalidated,
        supportsOneTouchScanning: false,
        hardwareButtonInterpretation: .unvalidated
    )

    static let s1300i = EpjitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S1300i",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x128d)],
        expectedFirmwareFileNames: ["1300i_0D12.nal"],
        firmwareBookmarkKey: "scan.epjitsu.s1300iFirmwareBookmark",
        supportsDuplex: true,
        hardwareButtonSupport: .supportedUnvalidated,
        supportsOneTouchScanning: false,
        hardwareButtonInterpretation: .unvalidated
    )

    static let all: [EpjitsuScanSnapModelProfile] = [.s300, .s300M, .s1300, .s1300i]

    nonisolated static func profile(for usbDeviceID: USBDeviceID) -> EpjitsuScanSnapModelProfile? {
        all.first { $0.usbDeviceIDs.contains(usbDeviceID) }
    }

    private init(
        name: String,
        usbDeviceIDs: Set<USBDeviceID>,
        expectedFirmwareFileNames: [String],
        firmwareBookmarkKey: String,
        supportsDuplex: Bool,
        hardwareButtonSupport: ScannerHardwareEventSupportState,
        supportsOneTouchScanning: Bool,
        hardwareButtonInterpretation: EpjitsuHardwareButtonInterpretation
    ) {
        self.name = name
        self.usbDeviceIDs = usbDeviceIDs
        self.expectedFirmwareFileNames = expectedFirmwareFileNames
        self.firmwareBookmarkKey = firmwareBookmarkKey
        self.supportsDuplex = supportsDuplex
        self.hardwareButtonSupport = hardwareButtonSupport
        self.supportsOneTouchScanning = supportsOneTouchScanning
        self.hardwareButtonInterpretation = hardwareButtonInterpretation
        self.hardwareStatusResponseLength = 4
        self.capabilities = ScannerCapabilities(
            sources: [.adfFront, .adfBack, .adfDuplex],
            colorModes: [.color],
            resolutionsDPI: [150, 200, 300, 600],
            scanArea: .init(width: 8.5, height: 11.5, unit: "inches"),
            supportsBlankPageRemoval: false,
            supportsDeskew: false,
            supportsAutoCrop: false,
            supportsAutoRotate: false,
            supportsDuplex: supportsDuplex,
            unsupportedReason: "Experimental: \(name) firmware bootstrap/status support exists, but calibrated epjitsu image acquisition is not implemented yet."
        )
    }
}

/// Native, direct-bulk USB support for the epjitsu ScanSnap family.
struct EpjitsuScanSnapDriver: ScannerDriver {
    let name = "Fujitsu ScanSnap epjitsu direct USB (experimental)"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = Set(EpjitsuScanSnapModelProfile.all.flatMap(\.usbDeviceIDs))

    private let firmwareProvider: (EpjitsuScanSnapModelProfile) throws -> Data?

    /// Production initializer: resolve a separate persisted bookmark for the
    /// model identified by the connected USB product ID.
    init(defaults: UserDefaults = .standard) {
        self.firmwareProvider = { profile in
            try EpjitsuScanSnapFirmwareStore(profile: profile, defaults: defaults).loadFirmwarePayload()
        }
    }

    /// Compatibility initializer for protocol tests and callers that provide
    /// an already-extracted payload. The payload is intentionally not reused
    /// across the model-aware production stores.
    init(firmwareProvider: @escaping () throws -> Data?) {
        self.firmwareProvider = { _ in try firmwareProvider() }
    }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        let profile = identity.usbDeviceID.flatMap(EpjitsuScanSnapModelProfile.profile(for:)) ?? .s300
        return EpjitsuScanSnapDevice(
            identity: identity,
            transport: transport,
            profile: profile,
            firmwareProvider: { try firmwareProvider(profile) }
        )
    }
}

final class EpjitsuScanSnapDevice: ScannerDevice, ScannerHardwareEventSource {
    let identity: ScannerIdentity
    let profile: EpjitsuScanSnapModelProfile
    var capabilities: ScannerCapabilities { profile.capabilities }

    private let transport: USBDeviceTransport?
    private let firmwareProvider: () throws -> Data?
    private var commandEngine: EpjitsuCommandEngine?
    private(set) var status: ScannerStatus = .disconnected
    private var hardwareEventTask: Task<Void, Never>?

    var hardwareEventCapabilities: ScannerHardwareEventCapabilities {
        let detail: String
        switch profile.hardwareButtonInterpretation {
        case .s300Byte1Bit0:
            detail = "Epjitsu GET HARDWARE STATUS 0x1b/0x33 reports the Scan button in byte 1 bit 0 for this model. Button detection is experimental; image acquisition is unavailable."
        case .unvalidated:
            detail = "Epjitsu GET HARDWARE STATUS 0x1b/0x33 is exposed for this model, but the response layout and Scan-button bit have not been physically validated. One-touch scanning remains disabled."
        }
        return ScannerHardwareEventCapabilities(
            scanButton: profile.hardwareButtonSupport,
            supportsOneTouchScanning: profile.supportsOneTouchScanning,
            detail: detail
        )
    }

    init(
        identity: ScannerIdentity,
        transport: USBDeviceTransport?,
        profile: EpjitsuScanSnapModelProfile,
        firmwareProvider: @escaping () throws -> Data?
    ) {
        self.identity = identity
        self.transport = transport
        self.profile = profile
        self.firmwareProvider = firmwareProvider
    }

    func open() async throws {
        guard let transport else {
            throw ScannerError.transportUnavailable("No USB transport was provided for \(identity.name).")
        }

        ScanTrace.post("Opening experimental \(profile.name) direct-USB session.")
        do {
            try await transport.open()
            let engine = EpjitsuCommandEngine(transport: transport, profile: profile)
            let scannerIdentity = try await engine.prepare(firmwarePayload: try firmwareProvider())
            commandEngine = engine
            status = .idle
            ScanTrace.post("\(profile.name) protocol identity: \(scannerIdentity.vendor) \(scannerIdentity.model).")
        } catch {
            await transport.close()
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func close() async {
        await stopHardwareEventObservation()
        await transport?.close()
        commandEngine = nil
        status = .disconnected
    }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        await stopHardwareEventObservation()
        try capabilities.validate(options)
        guard commandEngine != nil else {
            throw ScannerError.transportUnavailable("Open the \(profile.name) before starting a scan.")
        }
        throw ScannerError.protocolNotImplemented(
            "The \(profile.name) initialized successfully, but epjitsu image acquisition is not implemented yet."
        )
    }

    func cancel() async {
        await stopHardwareEventObservation()
        await transport?.abort()
        await close()
        status = .idle
    }

    func startHardwareEventObservation() async throws -> AsyncStream<ScannerHardwareEvent> {
        guard let commandEngine else {
            throw ScannerError.transportUnavailable("Open and initialize the \(profile.name) before observing its hardware button.")
        }
        await stopHardwareEventObservation()
        let stream = AsyncStream<ScannerHardwareEvent> { continuation in
            self.hardwareEventTask = Task { [weak self] in
                await self?.pollHardwareEvents(commandEngine: commandEngine, continuation: continuation)
            }
        }
        ScanTrace.post("Listening for the experimental \(profile.name) Scan button event.")
        return stream
    }

    func stopHardwareEventObservation() async {
        let wasObserving = hardwareEventTask != nil
        hardwareEventTask?.cancel()
        hardwareEventTask = nil
        if wasObserving { await transport?.abort() }
    }

    private func pollHardwareEvents(
        commandEngine: EpjitsuCommandEngine,
        continuation: AsyncStream<ScannerHardwareEvent>.Continuation
    ) async {
        defer { continuation.finish() }
        guard case .s300Byte1Bit0 = profile.hardwareButtonInterpretation else {
            continuation.yield(.diagnostic("\(profile.name) hardware-status response is available, but its Scan-button layout is not validated yet."))
            return
        }

        var wasPressed = false
        while !Task.isCancelled {
            do {
                let bytes = [UInt8](try await commandEngine.readHardwareStatus())
                guard bytes.count >= 2 else {
                    continuation.yield(.diagnostic("\(profile.name) returned a short hardware-status response."))
                    return
                }
                let isPressed = (bytes[1] & 0x01) != 0
                if isPressed, !wasPressed { continuation.yield(.scanButtonPressed) }
                wasPressed = isPressed
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.diagnostic("\(profile.name) hardware-button observation stopped: \(error.localizedDescription)"))
                return
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
    }
}

struct EpjitsuProtocolIdentity: Equatable {
    let vendor: String
    let model: String
}

final class EpjitsuCommandEngine {
    static let firmwarePayloadLength = 0x10000

    private let transport: USBDeviceTransport
    private let profile: EpjitsuScanSnapModelProfile
    private let commandTimeout: UInt32 = 10_000
    private let dataTimeout: UInt32 = 10_000

    init(transport: USBDeviceTransport, profile: EpjitsuScanSnapModelProfile = .s300) {
        self.transport = transport
        self.profile = profile
    }

    func prepare(firmwarePayload: Data?) async throws -> EpjitsuProtocolIdentity {
        var status = try await readStatus()
        if status & 0x10 == 0 {
            guard let firmwarePayload else {
                throw ScannerError.transportUnavailable(
                    "The \(profile.name) needs Fujitsu firmware. Choose \(profile.expectedFirmwareFileNames.joined(separator: " or ")) in Diagnostics, then try again."
                )
            }
            try await uploadFirmware(firmwarePayload)
            status = try await readStatus()
            guard status & 0x10 != 0 else {
                throw ScannerError.transportUnavailable("The \(profile.name) did not report loaded firmware after upload.")
            }
        } else {
            ScanTrace.post("\(profile.name) firmware is already loaded.")
        }
        return try await readIdentity()
    }

    func readStatus() async throws -> UInt8 {
        try await write([0x1b, 0x03])
        let response = try await readExactly(2, label: "status")
        return response[response.startIndex]
    }

    /// Epjitsu GET HARDWARE STATUS. The S300-family response is four bytes;
    /// models without a validated layout still use the common status command,
    /// but their button bits are deliberately not interpreted.
    func readHardwareStatus() async throws -> Data {
        try await write([0x1b, 0x33])
        return try await readExactly(profile.hardwareStatusResponseLength, label: "hardware status")
    }

    func readIdentity() async throws -> EpjitsuProtocolIdentity {
        try await write([0x1b, 0x13])
        let response = try await readExactly(0x20, label: "identity")
        let bytes = [UInt8](response)
        return EpjitsuProtocolIdentity(
            vendor: Self.ascii(bytes[0..<8]),
            model: Self.ascii(bytes[8..<24])
        )
    }

    func uploadFirmware(_ payload: Data) async throws {
        guard payload.count == Self.firmwarePayloadLength else {
            throw ScannerError.transportUnavailable(
                "The selected \(profile.name) firmware payload is \(payload.count) bytes; expected \(Self.firmwarePayloadLength)."
            )
        }

        ScanTrace.post("Uploading user-supplied \(profile.name) firmware.")
        try await commandExpectingAcknowledgement([0x1b, 0x06], label: "firmware start")
        try await write([0x01, 0x00, 0x01, 0x00])
        try await transport.bulkWrite(endpoint: 0, data: payload, timeoutMilliseconds: dataTimeout)

        let checksum = payload.reduce(UInt8.zero) { partial, byte in
            partial &+ byte
        }
        try await commandExpectingAcknowledgement([checksum], label: "firmware checksum")
        try await commandExpectingAcknowledgement([0x1b, 0x16], label: "firmware reinitialize")
        try await commandExpectingAcknowledgement([0x80], label: "firmware reinitialize payload")
        ScanTrace.post("\(profile.name) firmware upload acknowledged.")
    }

    private func commandExpectingAcknowledgement(_ bytes: [UInt8], label: String) async throws {
        try await write(bytes)
        let response = try await readExactly(1, label: label)
        guard response.first == 0x06 else {
            let value = response.first.map { String(format: "0x%02x", $0) } ?? "none"
            throw ScannerError.transportUnavailable("\(profile.name) \(label) returned \(value), expected ACK 0x06.")
        }
    }

    private func write(_ bytes: [UInt8]) async throws {
        try await transport.bulkWrite(endpoint: 0, data: Data(bytes), timeoutMilliseconds: commandTimeout)
    }

    private func readExactly(_ length: Int, label: String) async throws -> Data {
        let data = try await transport.bulkRead(endpoint: 0, length: length, timeoutMilliseconds: dataTimeout)
        guard data.count == length else {
            throw ScannerError.transportUnavailable(
                "\(profile.name) \(label) returned \(data.count) bytes; expected \(length)."
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

struct EpjitsuScanSnapFirmwareStore {
    static let legacyS300BookmarkKey = "scan.scansnapS300FirmwareBookmark"
    static let expectedFileNames = EpjitsuScanSnapModelProfile.all.flatMap(\.expectedFirmwareFileNames)

    let profile: EpjitsuScanSnapModelProfile
    private let defaults: UserDefaults

    init(profile: EpjitsuScanSnapModelProfile = .s300, defaults: UserDefaults) {
        self.profile = profile
        self.defaults = defaults
    }

    var selectedFilename: String? {
        resolveBookmark()?.lastPathComponent
    }

    func saveFirmware(at url: URL) throws {
        try validateFilename(url.lastPathComponent)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        _ = try Self.extractPayload(from: Data(contentsOf: url), modelName: profile.name)
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: profile.firmwareBookmarkKey)
    }

    func loadFirmwarePayload() throws -> Data? {
        guard let url = resolveBookmark() else { return nil }
        try validateFilename(url.lastPathComponent)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Self.extractPayload(from: Data(contentsOf: url), modelName: profile.name)
    }

    static func extractPayload(from firmwareFile: Data) throws -> Data {
        try extractPayload(from: firmwareFile, modelName: EpjitsuScanSnapModelProfile.s300.name)
    }

    static func extractPayload(from firmwareFile: Data, modelName: String) throws -> Data {
        let headerLength = 0x100
        let requiredLength = headerLength + EpjitsuCommandEngine.firmwarePayloadLength
        guard firmwareFile.count >= requiredLength else {
            throw ScannerError.transportUnavailable(
                "The selected file is too short to be \(modelName) firmware (\(firmwareFile.count) bytes; expected at least \(requiredLength))."
            )
        }
        return firmwareFile.subdata(in: headerLength..<requiredLength)
    }

    private func validateFilename(_ filename: String) throws {
        let expected = profile.expectedFirmwareFileNames
        guard expected.contains(where: { $0.caseInsensitiveCompare(filename) == .orderedSame }) else {
            throw ScannerError.transportUnavailable(
                "The selected firmware file \(filename) does not match \(profile.name). Expected \(expected.joined(separator: " or "))."
            )
        }
    }

    private func resolveBookmark() -> URL? {
        let keys = profile == .s300
            ? [profile.firmwareBookmarkKey, Self.legacyS300BookmarkKey]
            : [profile.firmwareBookmarkKey]
        for key in keys {
            guard let bookmark = defaults.data(forKey: key) else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            if isStale, let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(refreshed, forKey: profile.firmwareBookmarkKey)
            } else if key == Self.legacyS300BookmarkKey {
                // Migrate the old global S300 bookmark to the model-specific
                // key without deleting the legacy value.
                defaults.set(bookmark, forKey: profile.firmwareBookmarkKey)
            }
            return url
        }
        return nil
    }
}

// Source compatibility for existing callers and tests while clients migrate
// to the generic epjitsu names. These aliases do not create a second backend.
typealias FujitsuScanSnapS300Driver = EpjitsuScanSnapDriver
typealias FujitsuScanSnapS300Device = EpjitsuScanSnapDevice
typealias ScanSnapS300CommandEngine = EpjitsuCommandEngine
typealias ScanSnapS300ProtocolIdentity = EpjitsuProtocolIdentity
typealias ScanSnapS300FirmwareStore = EpjitsuScanSnapFirmwareStore
