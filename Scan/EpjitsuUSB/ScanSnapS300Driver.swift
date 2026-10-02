import AppKit
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
    let protocolFamily: EpjitsuProtocolFamily

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
        hardwareButtonSupport: .supportedValidated,
        supportsOneTouchScanning: true,
        hardwareButtonInterpretation: .s300Byte1Bit0,
        protocolFamily: .s1300i
    )

    nonisolated static let all: [EpjitsuScanSnapModelProfile] = [.s300, .s300M, .s1300, .s1300i]

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
        hardwareButtonInterpretation: EpjitsuHardwareButtonInterpretation,
        protocolFamily: EpjitsuProtocolFamily = .s300
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
        self.protocolFamily = protocolFamily
        self.capabilities = ScannerCapabilities(
            sources: [.adfFront, .adfBack, .adfDuplex],
            colorModes: [.color],
            resolutionsDPI: [150, 200, 300, 600],
            scanArea: .init(width: 8.5, height: 11.5, unit: "inches"),
            supportsDuplex: supportsDuplex,
            unsupportedReason: "Experimental direct-USB acquisition: color ADF scanning is implemented; grayscale, line-art, and hardware-button one-touch behavior remain unavailable or unvalidated."
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
            detail = "Epjitsu GET HARDWARE STATUS 0x1b/0x33 reports the Scan button in byte 1 bit 0 for this model. Button detection is experimental."
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
            if profile.protocolFamily == .s1300i {
                await engine.discardStaleInput()
            }
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
        guard let commandEngine else {
            throw ScannerError.transportUnavailable("Open the \(profile.name) before starting a scan.")
        }

        status = .scanning(progress: 0, pagesScanned: 0)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var pageIndex = 0
                    try await commandEngine.scan(options: options) { frame in
                        pageIndex += 1
                        continuation.yield(PageFrame(
                            pageIndex: pageIndex,
                            side: frame.side,
                            pixelFormat: .jpeg,
                            width: frame.width,
                            height: frame.height,
                            resolutionDPI: frame.resolutionDPI,
                            data: frame.data
                        ))
                        self.status = .scanning(progress: nil, pagesScanned: pageIndex)
                    }
                    self.status = .idle
                    continuation.finish()
                } catch is CancellationError {
                    self.status = .idle
                    continuation.finish(throwing: ScannerError.scanCancelled)
                } catch {
                    self.status = .error(error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }
        }
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
        if profile.protocolFamily == .s1300i {
            // Let the poller finish its status exchange instead of aborting
            // the pipes: an aborted 1b 33 leaves its reply queued in the
            // scanner, and the next session would read it as the answer to its
            // own command. Concurrent callers wait for the same poller.
            guard let task = hardwareEventTask else { return }
            task.cancel()
            await task.value
            if hardwareEventTask == task { hardwareEventTask = nil }
            return
        }
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
                if bytes.count < 2, profile.protocolFamily == .s1300i {
                    // A one-byte NAK: the S1300i is busy, poll again later.
                } else {
                    guard bytes.count >= 2 else {
                        continuation.yield(.diagnostic("\(profile.name) returned a short hardware-status response."))
                        return
                    }
                    let isPressed = (bytes[1] & 0x01) != 0
                    if isPressed, !wasPressed { continuation.yield(.scanButtonPressed) }
                    wasPressed = isPressed
                }
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

nonisolated struct EpjitsuAcquiredPage: Sendable {
    let side: PageSide
    let width: Int
    let height: Int
    let resolutionDPI: Int
    let data: Data
}

/// The S300-family scanner has a small, resolution-dependent raster geometry
/// table.  These values are protocol geometry, not firmware; the scanner still
/// supplies all of the image data and calibration state at run time.
private struct EpjitsuAcquisitionProfile {
    enum WindowKind { case coarseCalibration, fineCalibration, sendCalibration, scan }

    let protocolXResolution: Int
    let protocolYResolution: Int
    let rawLineStride: Int
    let rawPlaneStride: Int
    let rawPlaneWidth: Int
    let calibrationLineStride: Int
    let calibrationPlaneStride: Int
    let calibrationPlaneWidth: Int
    let blockHeight: Int
    let gainHeader: [UInt8]
    let offsetHeader: [UInt8]

    static func make(model: EpjitsuScanSnapModelProfile, requestedResolution: Int) throws -> Self {
        let protocolResolution: Int
        let protocolYResolution: Int
        switch requestedResolution {
        case 150: protocolResolution = 150; protocolYResolution = 150
        case 200: protocolResolution = 225; protocolYResolution = 200
        case 300: protocolResolution = 300; protocolYResolution = 300
        case 600: protocolResolution = 600; protocolYResolution = 600
        default:
            throw ScannerError.unsupportedOption("Epjitsu color acquisition does not support \(requestedResolution) dpi.")
        }

        let values: (rawLine: Int, rawPlane: Int, rawWidth: Int, calLine: Int, calPlane: Int, calWidth: Int, block: Int)
        switch protocolResolution {
        case 150: values = (7216 * 3, 2960 * 3, 1296, 14432 * 3, 5920 * 3, 2592, 24)
        case 225: values = (10584 * 3, 4320 * 3, 1944, 14112 * 3, 5760 * 3, 2592, 16)
        case 300: values = (15872 * 3, 6640 * 3, 2592, 15872 * 3, 6640 * 3, 2592, 11)
        default: values = (16064 * 3, 5440 * 3, 5184, 16064 * 3, 5440 * 3, 5184, 10)
        }

        let is1300i = model == .s1300i
        let gainHeader: [UInt8]
        let offsetHeader: [UInt8]
        switch (is1300i, protocolResolution) {
        case (true, 150): gainHeader = Self.repeatedPair(0xc4, 0x06, count: 6); offsetHeader = Self.repeatedPair(0xd7, 0x3b, count: 3) + [0x07]
        case (true, 225): gainHeader = Self.repeatedPair(0x2f, 0x07, count: 6); offsetHeader = Self.repeatedPair(0xa5, 0x3b, count: 3) + [0x07]
        case (true, 300): gainHeader = Self.repeatedPair(0xdd, 0x06, count: 6); offsetHeader = Self.repeatedPair(0x75, 0x3c, count: 3) + [0x07]
        case (true, 600): gainHeader = Self.repeatedPair(0x4d, 0x06, count: 6); offsetHeader = Self.repeatedPair(0x8f, 0x40, count: 3) + [0x07]
        case (false, 600): gainHeader = Self.repeatedPair(0x7f, 0x0b, count: 6); offsetHeader = Self.repeatedPair(0xc7, 0x23, count: 3) + [0x07]
        default: gainHeader = Self.repeatedPair(0xe2, 0x0a, count: 6); offsetHeader = Self.repeatedPair(0x77, 0x26, count: 3) + [0x07]
        }

        return Self(
            protocolXResolution: protocolResolution,
            protocolYResolution: protocolYResolution,
            rawLineStride: values.rawLine,
            rawPlaneStride: values.rawPlane,
            rawPlaneWidth: values.rawWidth,
            calibrationLineStride: values.calLine,
            calibrationPlaneStride: values.calPlane,
            calibrationPlaneWidth: values.calWidth,
            blockHeight: values.block,
            gainHeader: gainHeader + [0x00, 0x04],
            offsetHeader: offsetHeader
        )
    }

    func window(_ kind: WindowKind, scanHeight: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 72)
        func putBE(_ offset: Int, _ value: Int, _ count: Int) {
            for index in 0..<count {
                bytes[offset + count - index - 1] = UInt8((value >> (index * 8)) & 0xff)
            }
        }
        bytes[7] = 0x40
        bytes[0x21] = 0x05 // RGB colour composition
        bytes[0x22] = 0x08 // 8 bits per component

        switch kind {
        case .coarseCalibration:
            putBE(0x0a, 300, 2); putBE(0x0c, 300, 2)
            putBE(0x16, calibrationPlaneStride / 3, 4); putBE(0x1a, 1, 4)
            bytes[0x34] = 0x01; putBE(0x39, protocolXResolution, 2)
        case .fineCalibration:
            putBE(0x0a, 300, 2); putBE(0x0c, 800, 2)
            putBE(0x16, calibrationPlaneStride / 3, 4); putBE(0x1a, 16, 4)
            bytes[0x31] = 0x80; bytes[0x32] = 0x80; bytes[0x34] = 0x10
            putBE(0x39, protocolXResolution, 2)
        case .sendCalibration:
            putBE(0x0a, 300, 2); putBE(0x0c, 800, 2)
            putBE(0x16, calibrationLineStride / 3, 4); putBE(0x1a, 1, 4)
            bytes[0x34] = 0x10; putBE(0x39, protocolXResolution, 2)
        case .scan:
            putBE(0x0a, protocolXResolution, 2); putBE(0x0c, protocolYResolution, 2)
            putBE(0x16, rawPlaneStride / 3, 4); putBE(0x1a, scanHeight, 4)
            bytes[0x31] = 0x80; bytes[0x32] = 0x80; bytes[0x33] = 0x01
            bytes[0x34] = UInt8(clamping: blockHeight)
        }
        return Data(bytes)
    }

    private static func repeatedPair(_ first: UInt8, _ second: UInt8, count: Int) -> [UInt8] {
        Array(repeating: [first, second], count: count).flatMap { $0 }
    }
}

private struct EpjitsuPageRasterizer {
    private let acquisition: EpjitsuAcquisitionProfile
    private let requestedResolution: Int
    private let width: Int
    private let height: Int
    private let ySkip: Int
    private let xStart: Int
    private let sides: [(PageSide, Int)]
    private var pagePixels: [[UInt8]]

    init(acquisition: EpjitsuAcquisitionProfile, requestedResolution: Int, source: ScanSource) {
        self.acquisition = acquisition
        self.requestedResolution = requestedResolution
        width = max(1, Int((8.5 * Double(requestedResolution)).rounded()))
        height = max(1, Int((11.5 * Double(requestedResolution)).rounded()))
        ySkip = Int((0.5 * Double(acquisition.protocolYResolution)).rounded())
        let desiredRawWidth = Int((Double(width) * Double(acquisition.protocolXResolution) / Double(requestedResolution)).rounded())
        xStart = max(0, (acquisition.rawPlaneWidth - desiredRawWidth) / 2)
        switch source {
        case .adfBack: sides = [(.back, 1)]
        case .adfDuplex: sides = [(.front, 0), (.back, 1)]
        default: sides = [(.front, 0)]
        }
        let pageCount = sides.count
        let pixelCount = width * height * 3
        pagePixels = Array(repeating: [UInt8](repeating: 0, count: pixelCount), count: pageCount)
    }

    mutating func consume(_ raw: Data, startingAt rawLine: Int) {
        let bytes = [UInt8](raw)
        let lineCount = bytes.count / acquisition.rawLineStride
        for line in 0..<lineCount {
            let sourceY = rawLine + line
            guard sourceY >= ySkip else { continue }
            let outputY = Int(Double(sourceY - ySkip) * Double(requestedResolution) / Double(acquisition.protocolYResolution))
            guard outputY >= 0, outputY < height else { continue }
            let row = line * acquisition.rawLineStride

            for outputX in 0..<width {
                let sourceX = min(acquisition.rawPlaneWidth - 1, xStart + Int(Double(outputX) * Double(acquisition.protocolXResolution) / Double(requestedResolution)))
                let base = row + sourceX * 3
                let destination = (outputY * width + outputX) * 3
                for pageIndex in sides.indices {
                    let page = sides[pageIndex].1
                    let blue = bytes[base + page]
                    let red = bytes[base + acquisition.rawPlaneStride + page]
                    let green = bytes[base + acquisition.rawPlaneStride * 2 + page]
                    pagePixels[pageIndex][destination] = red
                    pagePixels[pageIndex][destination + 1] = green
                    pagePixels[pageIndex][destination + 2] = blue
                }
            }
        }
    }

    func finish() throws -> [EpjitsuAcquiredPage] {
        try zip(sides, pagePixels).map { side, pixels in
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 3,
                bitsPerPixel: 24
            ), let destination = bitmap.bitmapData else {
                throw ScannerError.outputFailed("Could not create an image buffer for epjitsu acquisition.")
            }
            pixels.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    destination.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: pixels.count)
                }
            }
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
                throw ScannerError.outputFailed("Could not encode the epjitsu image as JPEG.")
            }
            return EpjitsuAcquiredPage(side: side.0, width: width, height: height, resolutionDPI: requestedResolution, data: jpeg)
        }
    }
}

final class EpjitsuCommandEngine {
    static let firmwarePayloadLength = 0x10000

    let transport: USBDeviceTransport
    let profile: EpjitsuScanSnapModelProfile
    let commandTimeout: UInt32 = 10_000
    let dataTimeout: UInt32 = 10_000
    /// Bit 0 of the status byte: powered from the USB bus instead of the AC
    /// adapter. The S1300i uses different protocol tables for each.
    private(set) var usbPower = false

    init(transport: USBDeviceTransport, profile: EpjitsuScanSnapModelProfile = .s300) {
        self.transport = transport
        self.profile = profile
    }

    fileprivate func scan(
        options: ScanOptions,
        onPage: @escaping (EpjitsuAcquiredPage) async throws -> Void
    ) async throws {
        if profile.protocolFamily == .s1300i {
            try await scanS1300i(options: options, onPage: onPage)
            return
        }
        let acquisition = try EpjitsuAcquisitionProfile.make(model: profile, requestedResolution: options.acquisition.resolutionDPI)
        let rawHeight = Int((12.0 * Double(acquisition.protocolYResolution)).rounded())

        guard try await objectPosition(ingest: true) else {
            throw ScannerError.feederEmpty
        }
        try await calibrate(acquisition: acquisition)

        var sheetCount = 0
        while !Task.isCancelled {
            try await setWindow(acquisition.window(.scan, scanHeight: rawHeight))
            try await commandExpectingAcknowledgement([0x1b, 0xd6], label: "scan")
            var rasterizer = EpjitsuPageRasterizer(
                acquisition: acquisition,
                requestedResolution: options.acquisition.resolutionDPI,
                source: options.acquisition.source
            )
            try await readRawScan(acquisition: acquisition, height: rawHeight) { block, startingAt in
                rasterizer.consume(block, startingAt: startingAt)
            }
            let pages = try rasterizer.finish()
            for page in pages {
                try await onPage(page)
            }
            sheetCount += 1
            ScanTrace.post("Finished epjitsu sheet \(sheetCount).")

            guard try await objectPosition(ingest: true) else { break }
        }
        if Task.isCancelled { throw ScannerError.scanCancelled }
        try? await lamp(on: false)
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
        usbPower = status & 0x01 != 0
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
        if profile.protocolFamily == .s1300i {
            return try await readS1300iHardwareStatusReply()
        }
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

    private func calibrate(acquisition: EpjitsuAcquisitionProfile) async throws {
        // The S300-family requires a calibration exchange before the first
        // image. The default coarse/fine tables are valid scanner values; the
        // scanner then applies its own line samples while the host drains the
        // calibration transfers. This avoids bundling vendor firmware or
        // model-specific calibration blobs in the application.
        let coarse = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x2d, 0x00, 0x2b,
            0x00, 0x00, 0x00, 0x24, 0x00, 0x28, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])

        try await lamp(on: false)
        try await setWindow(acquisition.window(.coarseCalibration))
        try await sendCommandWithPayload([0x1b, 0xc6], payload: coarse, label: "coarse calibration")
        try await commandExpectingAcknowledgement([0x1b, 0xd2], label: "coarse calibration scan")
        _ = try await readTransfer(length: acquisition.calibrationLineStride + 8, label: "coarse calibration data")

        try await lamp(on: true)
        try await sendCommandWithPayload([0x1b, 0xc6], payload: coarse, label: "light calibration")
        try await commandExpectingAcknowledgement([0x1b, 0xd2], label: "light calibration scan")
        _ = try await readTransfer(length: acquisition.calibrationLineStride + 8, label: "light calibration data")

        try await setWindow(acquisition.window(.sendCalibration))
        var calibrationData = Data(count: acquisition.calibrationLineStride * 2)
        calibrationData.withUnsafeMutableBytes { rawBuffer in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in stride(from: 1, to: acquisition.calibrationLineStride * 2, by: 2) {
                pointer[index] = 0xff
            }
        }
        try await sendCommandWithPayload(
            [0x1b, 0xc3],
            payload: Data(acquisition.gainHeader) + calibrationData,
            label: "gain calibration"
        )
        try await sendCommandWithPayload(
            [0x1b, 0xc4],
            payload: Data(acquisition.offsetHeader) + calibrationData,
            label: "offset calibration"
        )

        try await setWindow(acquisition.window(.fineCalibration))
        try await commandExpectingAcknowledgement([0x1b, 0xd2], label: "fine calibration scan")
        _ = try await readTransfer(length: acquisition.calibrationLineStride * 16 + 8, label: "fine calibration data")

        var lut = Data(count: 0x6000)
        lut.withUnsafeMutableBytes { rawBuffer in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let width = 0x1000
            for index in 0..<width {
                let value = index << 4
                for plane in 0..<3 {
                    let offset = plane * width * 2 + index * 2
                    pointer[offset] = UInt8(value & 0xff)
                    pointer[offset + 1] = UInt8((value >> 8) & 0x0f)
                }
            }
        }
        try await sendCommandWithPayload([0x1b, 0xc5], payload: lut, label: "tone curve")
        try await lamp(on: true)
    }

    func setWindow(_ payload: Data) async throws {
        try await commandExpectingAcknowledgement([0x1b, 0xd1], label: "set window command")
        try await writeAndExpectAcknowledgement(payload, label: "set window payload")
    }

    func lamp(on: Bool) async throws {
        try await commandExpectingAcknowledgement([0x1b, 0xd0], label: "lamp command")
        try await writeAndExpectAcknowledgement(Data([on ? 1 : 0]), label: "lamp payload")
    }

    private func objectPosition(ingest: Bool) async throws -> Bool {
        try await commandExpectingAcknowledgement([0x1b, 0xd4], label: "paper position command")
        try await write([UInt8(ingest ? 5 : 1)])
        let response = try await readExactly(1, label: "paper position response")
        switch response.first {
        case 0x06: return true
        case 0x00, 0x15: return false
        default:
            throw ScannerError.transportUnavailable("\(profile.name) returned an unexpected paper-position status.")
        }
    }

    private func readRawScan(
        acquisition: EpjitsuAcquisitionProfile,
        height: Int,
        consume: (Data, Int) -> Void
    ) async throws {
        let total = acquisition.rawLineStride * height
        let maxPayload = 512 * 1024 - 8
        let linesPerBlock = max(1, maxPayload / acquisition.rawLineStride)
        var remaining = total
        var startingLine = 0

        while remaining > 0 {
            try await commandExpectingAcknowledgement([0x1b, 0xd3], label: "image block")
            let payloadLength = min(remaining, linesPerBlock * acquisition.rawLineStride)
            let packet = try await readTransfer(length: payloadLength + 8, label: "image data")
            guard packet.count >= payloadLength + 8 else {
                throw ScannerError.transportUnavailable("\(profile.name) returned a short image block.")
            }
            consume(Data(packet.prefix(payloadLength)), startingLine)
            startingLine += payloadLength / acquisition.rawLineStride
            remaining -= payloadLength
        }
    }

    func sendCommandWithPayload(_ command: [UInt8], payload: Data, label: String) async throws {
        try await commandExpectingAcknowledgement(command, label: "\(label) command")
        try await writeAndExpectAcknowledgement(payload, label: "\(label) payload")
    }

    func writeAndExpectAcknowledgement(_ payload: Data, label: String) async throws {
        try await transport.bulkWrite(endpoint: 0, data: payload, timeoutMilliseconds: dataTimeout)
        let response = try await readExactly(1, label: label)
        guard response.first == 0x06 else {
            let value = response.first.map { String(format: "0x%02x", $0) } ?? "none"
            throw ScannerError.transportUnavailable("\(profile.name) \(label) returned \(value), expected ACK 0x06.")
        }
    }

    private func readTransfer(length: Int, label: String) async throws -> Data {
        var result = Data(); result.reserveCapacity(length)
        while result.count < length {
            let remaining = length - result.count
            let chunk = try await transport.bulkRead(endpoint: 0, length: remaining, timeoutMilliseconds: dataTimeout)
            guard !chunk.isEmpty else {
                throw ScannerError.transportUnavailable("\(profile.name) returned no bytes for \(label).")
            }
            result.append(chunk.prefix(remaining))
        }
        return result
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

    func commandExpectingAcknowledgement(_ bytes: [UInt8], label: String) async throws {
        try await write(bytes)
        let response = try await readExactly(1, label: label)
        guard response.first == 0x06 else {
            let value = response.first.map { String(format: "0x%02x", $0) } ?? "none"
            throw ScannerError.transportUnavailable("\(profile.name) \(label) returned \(value), expected ACK 0x06.")
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        try await transport.bulkWrite(endpoint: 0, data: Data(bytes), timeoutMilliseconds: commandTimeout)
    }

    func readExactly(_ length: Int, label: String) async throws -> Data {
        try await readTransfer(length: length, label: label)
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
