import AppKit
import Foundation

/// Shared `ScannerDevice` for Fujitsu ScanSnap models that speak the Fujitsu
/// SCSI-over-USB dialect. Model-specific behaviour is described by a
/// `FujitsuScanSnapModelProfile`; the command engine below is common.
final class FujitsuScanSnapDevice: ScannerDevice {
    let identity: ScannerIdentity
    let profile: FujitsuScanSnapModelProfile
    var capabilities: ScannerCapabilities { profile.capabilities }

    private let transport: USBDeviceTransport?
    private var commandEngine: FujitsuSCSIOverUSBCommandEngine?
    private(set) var status: ScannerStatus = .disconnected
    private var isCancelled = false

    init(identity: ScannerIdentity, transport: USBDeviceTransport?, profile: FujitsuScanSnapModelProfile) {
        self.identity = identity
        self.transport = transport
        self.profile = profile
    }

    func open() async throws {
        guard let transport else {
            throw ScannerError.transportUnavailable("No USB transport was provided for \(identity.name).")
        }
        ScanTrace.post("Opening \(identity.name) using the \(profile.name) profile.")
        try await transport.open()
        commandEngine = FujitsuSCSIOverUSBCommandEngine(transport: transport, profile: profile)
        try await commandEngine?.waitUntilReady()
        if let inquiry = try await commandEngine?.inquiry() {
            ScanTrace.post("Inquiry: \(inquiry.vendor) \(inquiry.product) \(inquiry.version).")
        }
        status = .idle
    }

    func close() async {
        ScanTrace.post("Closing USB session.")
        await transport?.close()
        commandEngine = nil
        status = .disconnected
    }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        try capabilities.validate(options)
        guard let commandEngine else {
            throw ScannerError.transportUnavailable("No USB transport was provided for \(identity.name).")
        }

        status = .scanning(progress: 0, pagesScanned: 0)
        isCancelled = false

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    _ = try await commandEngine.scan(options: options, isCancelled: { self.isCancelled }) { frame in
                        continuation.yield(frame)
                        self.status = .scanning(progress: nil, pagesScanned: frame.pageIndex)
                    }
                    guard !self.isCancelled else { throw ScannerError.scanCancelled }
                    self.status = .idle
                    continuation.finish()
                } catch {
                    // Cancellation is terminal and must not be overwritten by a
                    // transport error arriving after the USB pipes are aborted.
                    if self.isCancelled || error is CancellationError {
                        self.status = .idle
                        continuation.finish(throwing: ScannerError.scanCancelled)
                    } else {
                        self.status = .error(error.localizedDescription)
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    func cancel() async {
        isCancelled = true
        ScanTrace.post("Aborting USB transfers.")
        await transport?.abort()
        try? await commandEngine?.cancel()
        await close()
        status = .idle
    }
}

private struct FujitsuInquiry {
    let vendor: String
    let product: String
    let version: String
}

/// How the scanner interleaves colour samples on the wire. Mirrors SANE's
/// `COLOR_INTERLACE_RGB`, `_BGR` and `_RRGGBB`.
enum FujitsuColorInterlace: CaseIterable, Sendable {
    /// Pixel-interleaved `r g b r g b ...` (scanning order "dot", argument RGB).
    case rgb
    /// Pixel-interleaved `b g r b g r ...` (scanning order "dot", argument BGR).
    case bgr
    /// Line-interleaved `rrr...ggg...bbb...` (scanning order "line", argument RGB).
    case rrggbb

    /// Window descriptor byte 0x2a.
    var scanningOrder: UInt8 {
        self == .rrggbb ? 0x00 : 0x01
    }

    /// Window descriptor byte 0x2b.
    var scanningOrderArgument: UInt8 {
        self == .bgr ? 0x05 : 0x00
    }

    var traceName: String {
        switch self {
        case .rgb: "RGB dot"
        case .bgr: "BGR dot"
        case .rrggbb: "RRGGBB line"
        }
    }
}

private final class FujitsuSCSIOverUSBCommandEngine {
    private let transport: USBDeviceTransport
    private let profile: FujitsuScanSnapModelProfile

    private let commandTimeout: UInt32 = 30_000
    private let shortCommandTimeout: UInt32 = 500
    private let dataTimeout: UInt32 = 30_000
    private let commandWrapperLength = 0x1f
    private let commandWrapperOffset = 0x13
    private let statusLength = 0x0d
    private let statusOffset = 0x09
    // Per-model ceiling for one image READ. readImage/readNextChunk round it
    // down to a whole number of scan lines (30,600 bytes for 2550-pixel RGB at
    // 300 dpi with the S1500's 32 KiB).
    private var transferChunkSize: Int { profile.transferChunkSize }
    // "Image data ready?" polling: 100 ms granularity, 60 s overall budget.
    // With scanner buffering the next sheet is usually ready within one poll.
    private static let imageDataPollInterval: UInt64 = 100_000_000
    private static let imageDataPollAttempts = 600

    /// Colour interlacing accepted by the scanner. Determined once by probing
    /// `SET WINDOW` (models with `probesColorInterlace`) and reused for the
    /// rest of the session. Defaults to RGB dot order.
    private var colorInterlace: FujitsuColorInterlace?

    /// Set by `sendSCSICommand` when the last data phase ended with the benign
    /// end-of-medium sense, which is how JPEG transfers signal their end.
    private var lastReadHitEndOfMedium = false

    init(transport: USBDeviceTransport, profile: FujitsuScanSnapModelProfile) {
        self.transport = transport
        self.profile = profile
    }

    func waitUntilReady() async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await sendSCSICommand([0x00, 0, 0, 0, 0, 0], shortTimeout: true)
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? ScannerError.transportUnavailable("Scanner did not become ready.")
    }

    func inquiry() async throws -> FujitsuInquiry {
        let data = try await sendSCSICommand([0x12, 0, 0, 0, 96, 0], expectedReadLength: 96)
        guard data.count >= 36 else {
            throw ScannerError.transportUnavailable("Scanner returned a short inquiry response.")
        }

        let bytes = [UInt8](data)
        let vendor = Self.ascii(bytes, 8, 8)
        let product = Self.ascii(bytes, 16, 16)
        let version = Self.ascii(bytes, 32, 4)

        guard bytes[0] & 0x1f == 0x06 else {
            throw ScannerError.unsupportedDevice("The connected USB device did not identify as a scanner.")
        }
        return FujitsuInquiry(vendor: vendor, product: product, version: version)
    }

    func scan(options: ScanOptions, isCancelled: @escaping () -> Bool, onPage: @escaping (PageFrame) async throws -> Void) async throws -> Int {
        let plan = FujitsuScanPlan(options: options, profile: profile)

        ScanTrace.post("Preparing \(plan.traceDescription).")
        do {
            try await scannerControl(function: 0x00, label: "ADF source")
        } catch {
            ScanTrace.post("ADF source selection was ignored by scanner: \(error.localizedDescription).")
        }
        if profile.sendsDiagnosticPreread {
            await sendDiagnosticPreread(plan: plan)
        }
        try await modeSelectAuto(plan: plan)
        try await modeSelectDoubleFeedDefault()
        try await modeSelectDropoutDefault(tolerateFailure: profile.toleratesModeSelectFailures)
        try await modeSelectBuffer(mode: plan.scannerBuffering ? .on : .off, tolerateFailure: profile.toleratesModeSelectFailures)
        try await setWindow(plan: plan)
        if plan.scannerColorMode != .lineart {
            try await sendDefaultGammaLUT()
        }
        if profile.sendsJPEGQuantizationTable {
            await sendJPEGQuantizationTable()
        }
        await turnLampOnWhenReady()

        // Encoding of sheet N runs on a background task while the scanner is
        // already feeding and transferring sheet N+1, so the paper path never
        // waits for JPEG work. Pages are still delivered in order, one sheet
        // behind the transfer.
        var pendingSheet: Task<[PageFrame], Error>?
        let interlace = colorInterlace ?? .rgb

        do {
            var assignedPageCount = 0
            var deliveredPageCount = 0
            var sheetNumber = 0

            if profile.checksHopperBeforeFirstFeed {
                try await ensureHopperHasPaper()
            }

            while sheetNumber < 500 {
                if isCancelled() {
                    throw ScannerError.scanCancelled
                }

                do {
                    try await objectPosition(action: 0x01, label: "feed", waitsForReady: profile.waitsForReadyAfterFeed)
                } catch let error as FujitsuSCSIStatusError where error.isNoDocuments {
                    if assignedPageCount == 0 {
                        throw ScannerError.feederEmpty
                    }
                    ScanTrace.post("Document feeder is empty; batch complete.")
                    break
                }

                try await startScan(plan: plan)
                let rawImages = try await readSheet(plan: plan, isCancelled: isCancelled)
                sheetNumber += 1
                ScanTrace.post("Finished transferring sheet \(sheetNumber).")

                let firstPageIndex = assignedPageCount + 1
                assignedPageCount += rawImages.count
                let encodeTask = Task {
                    try await Self.encodeSheetInBackground(rawImages, plan: plan, interlace: interlace, firstPageIndex: firstPageIndex)
                }

                if let previous = pendingSheet {
                    for frame in try await previous.value {
                        try await onPage(frame)
                        deliveredPageCount += 1
                    }
                }
                pendingSheet = encodeTask
            }

            if sheetNumber == 500 {
                ScanTrace.post("Stopped after the 500-sheet safety limit.")
            }
            if let pendingSheet {
                for frame in try await pendingSheet.value {
                    try await onPage(frame)
                    deliveredPageCount += 1
                }
            }
            try? await modeSelectBuffer(mode: .off, tolerateFailure: true)
            return deliveredPageCount
        } catch {
            ScanTrace.post("Scan command flow failed; halting paper transport.")
            try? await objectPosition(action: 0x04, label: "halt", waitsForReady: false)
            try? await scannerControl(function: 0x04, label: "cancel")
            if plan.scannerBuffering {
                // Drop any sheets the scanner read ahead into its buffer.
                try? await modeSelectBuffer(mode: .off, tolerateFailure: true)
            }
            // Keep already transferred pages available for review.
            if let pendingSheet, let frames = try? await pendingSheet.value {
                for frame in frames {
                    try? await onPage(frame)
                }
            }
            throw error
        }
    }

    /// Runs `encodeSheet` on a utility-priority GCD thread so the CPU-bound
    /// decode/JPEG work never competes with the transport's I/O continuations.
    private static func encodeSheetInBackground(
        _ rawImages: [FujitsuRawImage],
        plan: FujitsuScanPlan,
        interlace: FujitsuColorInterlace,
        firstPageIndex: Int
    ) async throws -> [PageFrame] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try encodeSheet(rawImages, plan: plan, interlace: interlace, firstPageIndex: firstPageIndex)
                })
            }
        }
    }

    private static func encodeSheet(
        _ rawImages: [FujitsuRawImage],
        plan: FujitsuScanPlan,
        interlace: FujitsuColorInterlace,
        firstPageIndex: Int
    ) throws -> [PageFrame] {
        var frames: [PageFrame] = []
        for (offset, raw) in rawImages.enumerated() {
            let encoded: Data
            var size = raw.size
            if raw.isJPEG {
                let converted = try FujitsuScanSnapImageDecoder.finishHardwareJPEG(raw.data, outputColorMode: plan.colorMode)
                encoded = converted.data
                size = converted.size
            } else {
                encoded = try encodeImage(data: raw.data, size: raw.size, plan: plan, interlace: interlace)
            }
            frames.append(
                PageFrame(
                    pageIndex: firstPageIndex + offset,
                    side: raw.side,
                    pixelFormat: .jpeg,
                    width: size.width,
                    height: size.height,
                    resolutionDPI: plan.resolutionDPI,
                    data: encoded
                )
            )
        }
        ScanTrace.post("Encoded page\(frames.count == 1 ? "" : "s") \(firstPageIndex)-\(firstPageIndex + frames.count - 1).")
        return frames
    }

    func cancel() async throws {
        try? await objectPosition(action: 0x04, label: "halt", waitsForReady: false)
        try await scannerControl(function: 0x04, label: "cancel")
    }

    private func scannerControl(function: UInt8, label: String, logCommand: Bool = true) async throws {
        if logCommand {
            ScanTrace.post("Command: scanner control \(label).")
        }
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0xf1
        command[1] = function & 0x0f
        command[2] = function >> 4
        try await sendSCSICommand(command)
    }

    private func objectPosition(action: UInt8, label: String, waitsForReady: Bool) async throws {
        ScanTrace.post("Command: object position \(label).")
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x31
        command[1] = action & 0x07
        try await sendSCSICommand(command)
        if waitsForReady {
            try await waitUntilReady()
        }
    }

    private func startScan(plan: FujitsuScanPlan) async throws {
        ScanTrace.post("Command: start scan.")
        var command = [UInt8](repeating: 0, count: 6)
        let windowIDs: [UInt8] = plan.isDuplex ? [0x00, 0x80] : [plan.sourceWindowID]
        command[0] = 0x1b
        command[4] = UInt8(windowIDs.count)
        try await sendSCSICommand(command, output: Data(windowIDs))
    }

    /// `SEND DIAGNOSTIC` with the "SET PRE READMODE" page. SANE sends this on the
    /// iX500/iX100 before the mode selects; without it the scanner rejects
    /// resolutions above 300 dpi. Failures are logged and ignored, as in SANE.
    private func sendDiagnosticPreread(plan: FujitsuScanPlan) async {
        ScanTrace.post("Command: send diagnostic pre-read mode.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x1d
        Self.put(&command, offset: 3, value: 32, byteCount: 2)

        var payload = [UInt8](repeating: 0, count: 32)
        payload.replaceSubrange(0..<16, with: Array("SET PRE READMODE".utf8))
        Self.put(&payload, offset: 0x10, value: plan.resolutionDPI, byteCount: 2)
        Self.put(&payload, offset: 0x12, value: plan.resolutionDPI, byteCount: 2)
        Self.put(&payload, offset: 0x14, value: plan.paperWidthScannerUnits, byteCount: 4)
        Self.put(&payload, offset: 0x18, value: plan.paperHeightScannerUnits, byteCount: 4)
        payload[0x1c] = plan.composition

        do {
            try await sendSCSICommand(command, output: Data(payload))
        } catch {
            ScanTrace.post("Diagnostic pre-read mode was ignored by scanner: \(error.localizedDescription).")
        }
    }

    /// `SEND` data type 0x88 (JPEG quantisation table). The iX500 needs this
    /// even for uncompressed transfers. Table values are the ones SANE ships.
    private func sendJPEGQuantizationTable() async {
        ScanTrace.post("Command: send JPEG quantisation table.")
        let luminance: [UInt8] = [
            0x04, 0x03, 0x03, 0x04, 0x03, 0x03, 0x04, 0x04,
            0x03, 0x04, 0x05, 0x05, 0x04, 0x05, 0x07, 0x0c,
            0x07, 0x07, 0x06, 0x06, 0x07, 0x0e, 0x0a, 0x0b,
            0x08, 0x0c, 0x11, 0x0f, 0x12, 0x12, 0x11, 0x0f,
            0x10, 0x10, 0x13, 0x15, 0x1b, 0x17, 0x13, 0x14,
            0x1a, 0x14, 0x10, 0x10, 0x18, 0x20, 0x18, 0x1a,
            0x1c, 0x1d, 0x1e, 0x1f, 0x1e, 0x12, 0x17, 0x21,
            0x24, 0x21, 0x1e, 0x24, 0x1b, 0x1e, 0x1e, 0x1d
        ]
        let chrominance: [UInt8] = [
            0x05, 0x05, 0x05, 0x07, 0x06, 0x07, 0x0e, 0x07,
            0x07, 0x0e, 0x1d, 0x13, 0x10, 0x13, 0x1d, 0x1d,
            0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d,
            0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d,
            0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d,
            0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d,
            0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d,
            0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d, 0x1d
        ]

        let headerLength = 10
        var payload = [UInt8](repeating: 0, count: headerLength + luminance.count + chrominance.count)
        Self.put(&payload, offset: 4, value: luminance.count, byteCount: 2)
        Self.put(&payload, offset: 6, value: chrominance.count, byteCount: 2)
        payload.replaceSubrange(headerLength..<(headerLength + luminance.count), with: luminance)
        payload.replaceSubrange((headerLength + luminance.count)..<payload.count, with: chrominance)

        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x2a
        command[2] = 0x88
        Self.put(&command, offset: 6, value: payload.count, byteCount: 3)

        do {
            try await sendSCSICommand(command, output: Data(payload))
        } catch {
            ScanTrace.post("JPEG quantisation table was ignored by scanner: \(error.localizedDescription).")
        }
    }

    /// `GET HW STATUS` hopper sensor. Throws `feederEmpty` when the scanner
    /// reports no paper; an unreadable status is logged and the feed proceeds
    /// so that the scanner's own no-documents sense still ends the batch.
    private func ensureHopperHasPaper() async throws {
        ScanTrace.post("Command: get hardware status.")
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0xc2
        Self.put(&command, offset: 7, value: 12, byteCount: 2)

        let data: Data
        do {
            data = try await sendSCSICommand(command, expectedReadLength: 12, allowShortRead: true)
        } catch {
            ScanTrace.post("Hardware status was unavailable: \(error.localizedDescription).")
            return
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            ScanTrace.post("Hardware status response was too short (\(bytes.count) bytes).")
            return
        }
        // SANE: get_GHS_hopper(in) = !bit 7 of byte 3.
        let hopperHasPaper = (bytes[3] & 0x80) == 0
        if !hopperHasPaper {
            ScanTrace.post("Hardware status reports an empty hopper.")
            throw ScannerError.feederEmpty
        }
    }

    private func modeSelectAuto(plan: FujitsuScanPlan) async throws {
        ScanTrace.post("Command: mode select automatic document length.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x15
        command[1] = 0x10
        command[4] = 12

        var payload = [UInt8](repeating: 0, count: 12)
        payload[4] = 0x3c
        payload[5] = 6

        // The S1500 exposes automatic length detection (ALD), but not
        // automatic width detection or hardware deskew. ALD prevents a short
        // document from being treated as a failed 14-inch transfer.
        if plan.options.autoCrop || plan.options.deskew {
            payload[7] |= 0x80
        }

        do {
            try await sendSCSICommand(command, output: Data(payload))
        } catch {
            ScanTrace.post("Automatic sizing mode select was ignored by scanner: \(error.localizedDescription).")
        }
    }

    private func modeSelectDoubleFeedDefault() async throws {
        ScanTrace.post("Command: mode select double-feed defaults.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x15
        command[1] = 0x10
        command[4] = 12

        var payload = [UInt8](repeating: 0, count: 12)
        payload[4] = 0x38
        payload[5] = 6

        do {
            try await sendSCSICommand(command, output: Data(payload))
        } catch {
            ScanTrace.post("Double-feed mode select was ignored by scanner: \(error.localizedDescription).")
        }
    }

    private func modeSelectDropoutDefault(tolerateFailure: Bool) async throws {
        ScanTrace.post("Command: mode select dropout defaults.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x15
        command[1] = 0x10
        command[4] = 14

        var payload = [UInt8](repeating: 0, count: 14)
        payload[4] = 0x39
        payload[5] = 8
        do {
            try await sendSCSICommand(command, output: Data(payload))
        } catch where tolerateFailure {
            ScanTrace.post("Dropout mode select was ignored by scanner: \(error.localizedDescription).")
        }
    }

    /// Fujitsu "scan buffer control" mode page 0x3a. Values follow SANE:
    /// byte 2 bits 6-7 = buffer mode (2 off, 3 on), byte 3 bits 6-7 = clear (3).
    enum BufferMode: UInt8 {
        case off = 2
        case on = 3
    }

    private func modeSelectBuffer(mode: BufferMode, tolerateFailure: Bool) async throws {
        ScanTrace.post("Command: mode select buffer \(mode == .on ? "on" : "off") and clear.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x15
        command[1] = 0x10
        command[4] = 12

        var payload = [UInt8](repeating: 0, count: 12)
        payload[4] = 0x3a
        payload[5] = 6
        payload[6] = mode.rawValue << 6
        payload[7] = 0xc0
        do {
            try await sendSCSICommand(command, output: Data(payload))
        } catch where tolerateFailure {
            ScanTrace.post("Buffer mode select was ignored by scanner: \(error.localizedDescription).")
        }
    }

    private func setWindow(plan: FujitsuScanPlan) async throws {
        guard plan.scannerColorMode == .color, profile.probesColorInterlace else {
            try await sendSetWindow(plan: plan, interlace: .rgb)
            return
        }

        if let colorInterlace {
            try await sendSetWindow(plan: plan, interlace: colorInterlace)
            return
        }

        // Mirror SANE's init_interlace(): try each colour interlacing until the
        // scanner accepts the window, then keep using that one.
        var lastError: Error?
        for candidate in FujitsuColorInterlace.allCases {
            do {
                try await sendSetWindow(plan: plan, interlace: candidate)
                colorInterlace = candidate
                ScanTrace.post("Scanner accepted \(candidate.traceName) colour interlacing.")
                return
            } catch let error as FujitsuSCSIStatusError {
                ScanTrace.post("Scanner rejected \(candidate.traceName) colour interlacing: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError ?? ScannerError.unsupportedDevice("The scanner rejected every colour window layout.")
    }

    private func sendSetWindow(plan: FujitsuScanPlan, interlace: FujitsuColorInterlace) async throws {
        ScanTrace.post("Command: set window.")
        var payload = [UInt8](repeating: 0, count: plan.isDuplex ? 136 : 72)
        Self.put(&payload, offset: 6, value: 64, byteCount: 2)

        var front = makeWindowDescriptor(windowID: 0x00, plan: plan, interlace: interlace, includePaperSize: true)
        payload.replaceSubrange(8..<72, with: front)

        if plan.isDuplex {
            var back = front
            back[0] = 0x80
            back[0x35] = 0
            Self.put(&back, offset: 0x36, value: 0, byteCount: 4)
            Self.put(&back, offset: 0x3a, value: 0, byteCount: 4)
            payload.replaceSubrange(72..<136, with: back)
        } else if plan.sourceWindowID == 0x80 {
            front[0] = 0x80
            payload.replaceSubrange(8..<72, with: front)
        }

        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x24
        Self.put(&command, offset: 6, value: payload.count, byteCount: 3)
        try await sendSCSICommand(command, output: Data(payload))
    }

    private func makeWindowDescriptor(
        windowID: UInt8,
        plan: FujitsuScanPlan,
        interlace: FujitsuColorInterlace,
        includePaperSize: Bool
    ) -> [UInt8] {
        var descriptor = [UInt8](repeating: 0, count: 64)
        descriptor[0] = windowID
        Self.put(&descriptor, offset: 0x02, value: plan.resolutionDPI, byteCount: 2)
        Self.put(&descriptor, offset: 0x04, value: plan.resolutionDPI, byteCount: 2)
        Self.put(&descriptor, offset: 0x06, value: 0, byteCount: 4)
        Self.put(&descriptor, offset: 0x0a, value: 0, byteCount: 4)
        Self.put(&descriptor, offset: 0x0e, value: plan.widthScannerUnits, byteCount: 4)
        Self.put(&descriptor, offset: 0x12, value: plan.heightScannerUnits, byteCount: 4)
        descriptor[0x16] = 0
        descriptor[0x17] = 0
        descriptor[0x18] = 0
        descriptor[0x19] = plan.composition
        descriptor[0x1a] = plan.bitsPerPixel
        descriptor[0x1d] = 0
        descriptor[0x20] = plan.hardwareJPEG ? 0x81 : 0x00
        descriptor[0x21] = plan.hardwareJPEG ? plan.jpegQualityArgument : 0x00

        if plan.scannerColorMode == .color {
            descriptor[0x28] = 0xc1
            descriptor[0x29] = 0x80
            descriptor[0x2a] = interlace.scanningOrder
            descriptor[0x2b] = interlace.scanningOrderArgument
            descriptor[0x2e] = 0
            descriptor[0x2f] = 0
            descriptor[0x32] = 0
        } else {
            descriptor[0x28] = 0x00
            descriptor[0x29] = plan.scannerColorMode == .gray ? 0x80 : 0
            descriptor[0x2b] = 0
            descriptor[0x2f] = 0
            descriptor[0x30] = 0
            descriptor[0x32] = 0
            descriptor[0x3e] = 0
        }

        if includePaperSize {
            descriptor[0x35] = 0xc0
            Self.put(&descriptor, offset: 0x36, value: plan.paperWidthScannerUnits, byteCount: 4)
            Self.put(&descriptor, offset: 0x3a, value: plan.paperHeightScannerUnits, byteCount: 4)
        }
        return descriptor
    }

    private func sendDefaultGammaLUT() async throws {
        ScanTrace.post("Command: send default gamma table.")
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x2a
        command[2] = 0x83
        let payload = FujitsuGammaTable.payload(inputBits: profile.lookupTableInputBits)
        Self.put(&command, offset: 6, value: payload.count, byteCount: 3)
        try await sendSCSICommand(command, output: Data(payload))
    }

    private func turnLampOnWhenReady() async {
        for attempt in 1...120 {
            do {
                try await scannerControl(function: 0x05, label: "lamp on", logCommand: attempt == 1)
                if attempt > 1 {
                    ScanTrace.post("Scanner lamp became ready after \(attempt) attempts.")
                }
                return
            } catch let error as FujitsuSCSIStatusError where error.isBusy {
                if attempt == 1 || attempt % 10 == 0 {
                    ScanTrace.post("Scanner lamp is warming up; waiting (\(attempt)).")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                ScanTrace.post("Lamp-on was ignored by scanner: \(error.localizedDescription).")
                return
            }
        }
        ScanTrace.post("Scanner lamp did not report ready after 60 seconds; continuing.")
    }

    private func readPixelSize(side: PageSide) async throws -> FujitsuImageSize {
        ScanTrace.post("Command: read \(side.rawValue) pixel size.")
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x28
        command[2] = 0x80
        command[5] = side == .back ? 0x80 : 0x00
        Self.put(&command, offset: 6, value: 0x20, byteCount: 3)
        let data = try await sendSCSICommand(command, expectedReadLength: 0x20)
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else {
            throw ScannerError.transportUnavailable("Scanner returned a short pixel-size response.")
        }
        let width = Self.read(bytes, offset: 0, byteCount: 4)
        let height = Self.read(bytes, offset: 4, byteCount: 4)
        guard width > 0, height > 0 else {
            throw ScannerError.transportUnavailable("Scanner returned an invalid pixel size.")
        }
        ScanTrace.post("Scanner reports \(side.rawValue) size \(width)x\(height).")
        return FujitsuImageSize(width: width, height: height)
    }

    private func readImage(
        side: PageSide,
        size: FujitsuImageSize,
        plan: FujitsuScanPlan,
        isCancelled: @escaping () -> Bool
    ) async throws -> FujitsuRawImage {
        var remaining = plan.expectedByteCount(for: size)
        var imageData = Data()
        imageData.reserveCapacity(remaining)
        ScanTrace.post("Reading \(side.rawValue) image data, up to \(remaining) bytes.")
        var didReadImageCount = false

        while remaining > 0 {
            if isCancelled() {
                try await cancel()
                throw ScannerError.scanCancelled
            }

            var length = min(remaining, transferChunkSize)
            let bytesPerLine = plan.bytesPerLine(forWidth: size.width)
            if length > bytesPerLine {
                length -= length % bytesPerLine
            }
            if length == 0 {
                length = min(remaining, transferChunkSize)
            }

            if !didReadImageCount {
                try await readImageCount(length, side: side)
                didReadImageCount = true
            }

            var command = [UInt8](repeating: 0, count: 10)
            command[0] = 0x28
            command[2] = 0x00
            command[5] = side == .back ? 0x80 : 0x00
            Self.put(&command, offset: 6, value: length, byteCount: 3)
            if imageData.isEmpty {
                ScanTrace.post("Command: read \(side.rawValue) image CDB \(Self.hex(command)).")
            }

            let chunk = try await sendSCSICommand(command, expectedReadLength: length, allowShortRead: true)
            if chunk.isEmpty {
                break
            }
            imageData.append(chunk)
            remaining -= chunk.count
            if chunk.count < length {
                break
            }
        }

        let actualSize = try Self.actualImageSize(requested: size, dataCount: imageData.count, plan: plan)
        ScanTrace.post("Received \(imageData.count) bytes for \(side.rawValue) (\(actualSize.width)x\(actualSize.height)).")
        return FujitsuRawImage(side: side, size: actualSize, data: imageData)
    }

    private func readSheet(
        plan: FujitsuScanPlan,
        isCancelled: @escaping () -> Bool
    ) async throws -> [FujitsuRawImage] {
        if plan.hardwareJPEG {
            return try await readJPEGSheet(plan: plan, isCancelled: isCancelled)
        }
        let requestedSide: PageSide = plan.sourceWindowID == 0x80 ? .back : .front
        let frontSize = (try? await readPixelSize(side: requestedSide)) ?? plan.imageSize

        guard plan.isDuplex else {
            return [
                try await readImage(
                    side: requestedSide,
                    size: frontSize,
                    plan: plan,
                    isCancelled: isCancelled
                )
            ]
        }

        let backSize = (try? await readPixelSize(side: .back)) ?? frontSize
        let front = FujitsuImageReadState(
            side: .front,
            size: frontSize,
            byteCount: plan.expectedByteCount(for: frontSize)
        )
        let back = FujitsuImageReadState(
            side: .back,
            size: backSize,
            byteCount: plan.expectedByteCount(for: backSize)
        )
        var idleAttempts = 0

        ScanTrace.post("Reading duplex image data with interleaved front/back transfers.")
        while !front.isFinished || !back.isFinished {
            if isCancelled() {
                try await cancel()
                throw ScannerError.scanCancelled
            }

            var madeProgress = false
            if !front.isFinished {
                madeProgress = try await readNextChunk(into: front, plan: plan) || madeProgress
            }
            if !back.isFinished {
                madeProgress = try await readNextChunk(into: back, plan: plan) || madeProgress
            }

            if madeProgress {
                idleAttempts = 0
            } else {
                idleAttempts += 1
                if idleAttempts >= Self.imageDataPollAttempts {
                    throw ScannerError.transportUnavailable("Timed out waiting for duplex image data.")
                }
                try await Task.sleep(nanoseconds: Self.imageDataPollInterval)
            }
        }

        return [
            try Self.makeRawImage(from: front, plan: plan),
            try Self.makeRawImage(from: back, plan: plan)
        ]
    }

    /// Hardware JPEG. The requested window is read first; if its SOF reports a
    /// double-width frame the stream carries both sides and is split by
    /// `FujitsuJPEGStreamSplitter`. Otherwise (the iX500 case) each side is its
    /// own stream and both windows are read interleaved, like the raw path.
    private func readJPEGSheet(
        plan: FujitsuScanPlan,
        isCancelled: @escaping () -> Bool
    ) async throws -> [FujitsuRawImage] {
        let requestedSide: PageSide = plan.sourceWindowID == 0x80 ? .back : .front
        let size = (try? await readPixelSize(side: requestedSide)) ?? plan.imageSize
        if plan.isDuplex {
            _ = try? await readPixelSize(side: .back)
        }

        let front = FujitsuJPEGReadState(
            side: requestedSide,
            splitter: FujitsuJPEGStreamSplitter(requestedWidth: size.width, resolutionDPI: plan.resolutionDPI, duplex: plan.isDuplex),
            byteCap: plan.expectedByteCount(for: plan.imageSize) + 1024 * 1024
        )
        ScanTrace.post("Reading \(requestedSide.rawValue) JPEG stream in \(transferChunkSize)-byte reads.")

        // Read the first chunk(s) of the requested side until SOF tells us
        // whether the scanner interlaces both sides into this stream.
        try await readImageCount(transferChunkSize, side: requestedSide)
        front.didCheckImageCount = true
        while !front.isFinished && front.splitter.frameWidth == 0 {
            if isCancelled() {
                try await cancel()
                throw ScannerError.scanCancelled
            }
            _ = try await readJPEGChunk(into: front)
        }

        guard plan.isDuplex, !front.splitter.isInterlaced else {
            try await readJPEGStream(front, isCancelled: isCancelled)
            var images = [front.image(front.splitter.front)]
            if plan.isDuplex {
                ScanTrace.post("Received \(front.splitter.back.count) JPEG bytes for back (interlaced).")
                images.append(FujitsuRawImage(side: .back, size: front.frameSize, data: front.splitter.back, isJPEG: true))
            }
            return images
        }

        // Separate streams per side: alternate reads so the scanner's output
        // for both sides is drained while it is still producing it.
        let back = FujitsuJPEGReadState(
            side: .back,
            splitter: FujitsuJPEGStreamSplitter(requestedWidth: size.width, resolutionDPI: plan.resolutionDPI, duplex: false),
            byteCap: front.byteCap
        )
        ScanTrace.post("Reading front and back JPEG streams interleaved.")
        var idleAttempts = 0
        while !front.isFinished || !back.isFinished {
            if isCancelled() {
                try await cancel()
                throw ScannerError.scanCancelled
            }
            var madeProgress = false
            if !front.isFinished {
                madeProgress = try await readJPEGChunk(into: front) || madeProgress
            }
            if !back.isFinished {
                if !back.didCheckImageCount {
                    back.didCheckImageCount = try await imageDataIsReady(transferChunkSize, side: .back)
                }
                if back.didCheckImageCount {
                    madeProgress = try await readJPEGChunk(into: back) || madeProgress
                }
            }
            if madeProgress {
                idleAttempts = 0
            } else {
                idleAttempts += 1
                if idleAttempts >= Self.imageDataPollAttempts {
                    throw ScannerError.transportUnavailable("Timed out waiting for duplex JPEG data.")
                }
                try await Task.sleep(nanoseconds: Self.imageDataPollInterval)
            }
        }
        return [front.image(front.splitter.front), back.image(back.splitter.front)]
    }

    private func readJPEGStream(_ state: FujitsuJPEGReadState, isCancelled: @escaping () -> Bool) async throws {
        while !state.isFinished {
            if isCancelled() {
                try await cancel()
                throw ScannerError.scanCancelled
            }
            _ = try await readJPEGChunk(into: state)
        }
    }

    /// One READ for a JPEG side. Returns whether any bytes arrived; marks the
    /// side finished on EOI, end-of-medium, an empty read, or the byte cap.
    private func readJPEGChunk(into state: FujitsuJPEGReadState) async throws -> Bool {
        let length = transferChunkSize
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x28
        command[2] = 0x00
        command[5] = state.side == .back ? 0x80 : 0x00
        Self.put(&command, offset: 6, value: length, byteCount: 3)
        let chunk = try await sendSCSICommand(command, expectedReadLength: length, allowShortRead: true)
        if !chunk.isEmpty {
            state.splitter.feed(chunk)
            state.totalBytes += chunk.count
        }
        if chunk.isEmpty || lastReadHitEndOfMedium || state.splitter.hasReachedEndOfImage || state.totalBytes >= state.byteCap {
            state.isFinished = true
            if state.totalBytes == 0 {
                throw ScannerError.outputFailed("The scanner returned no JPEG data for the \(state.side.rawValue) side.")
            }
            if !state.splitter.hasReachedEndOfImage {
                ScanTrace.post("JPEG stream for \(state.side.rawValue) ended without an EOI marker after \(state.totalBytes) bytes.")
            }
            ScanTrace.post("Received \(state.splitter.front.count) JPEG bytes for \(state.side.rawValue) (SOF \(state.splitter.frameWidth)x\(state.splitter.frameHeight)\(state.splitter.isInterlaced ? ", interlaced duplex" : "")).")
        }
        return !chunk.isEmpty
    }

    private func readNextChunk(into state: FujitsuImageReadState, plan: FujitsuScanPlan) async throws -> Bool {
        let bytesPerLine = plan.bytesPerLine(forWidth: state.size.width)
        var length = min(state.remaining, transferChunkSize)
        if length > bytesPerLine {
            length -= length % bytesPerLine
        }
        if length == 0 {
            length = min(state.remaining, transferChunkSize)
        }

        if !state.didCheckImageCount {
            let ready = try await imageDataIsReady(length, side: state.side)
            guard ready else { return false }
            state.didCheckImageCount = true
        }

        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0x28
        command[2] = 0x00
        command[5] = state.side == .back ? 0x80 : 0x00
        Self.put(&command, offset: 6, value: length, byteCount: 3)
        if state.data.isEmpty {
            ScanTrace.post("Command: read \(state.side.rawValue) image CDB \(Self.hex(command)).")
        }

        let chunk = try await sendSCSICommand(command, expectedReadLength: length, allowShortRead: true)
        state.data.append(chunk)
        state.remaining = max(0, state.remaining - chunk.count)
        if chunk.isEmpty || chunk.count < length || state.remaining == 0 {
            state.isFinished = true
        }
        return !chunk.isEmpty
    }

    private func imageDataIsReady(_ byteCount: Int, side: PageSide) async throws -> Bool {
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0xf1
        command[1] = 0x10
        command[2] = side == .back ? 0x80 : 0x00
        Self.put(&command, offset: 6, value: byteCount, byteCount: 3)

        do {
            try await sendSCSICommand(command)
            return true
        } catch let error as FujitsuSCSIStatusError {
            if error.isTemporaryNoData || error.isBusy {
                return false
            }
            if error.isUnsupportedCommand {
                ScanTrace.post("Read-image-count is unsupported; continuing without it.")
                return true
            }
            throw error
        }
    }

    private static func makeRawImage(from state: FujitsuImageReadState, plan: FujitsuScanPlan) throws -> FujitsuRawImage {
        let actualSize = try actualImageSize(requested: state.size, dataCount: state.data.count, plan: plan)
        ScanTrace.post("Received \(state.data.count) bytes for \(state.side.rawValue) (\(actualSize.width)x\(actualSize.height)).")
        return FujitsuRawImage(side: state.side, size: actualSize, data: state.data)
    }

    private func readImageCount(_ byteCount: Int, side: PageSide) async throws {
        ScanTrace.post("Command: read-image-count \(side.rawValue) \(byteCount) bytes.")
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0xf1
        command[1] = 0x10
        command[2] = side == .back ? 0x80 : 0x00
        Self.put(&command, offset: 6, value: byteCount, byteCount: 3)
        ScanTrace.post("Command: read-image-count CDB \(Self.hex(command)).")

        for attempt in 1...Self.imageDataPollAttempts {
            do {
                try await sendSCSICommand(command)
                if attempt > 1 {
                    ScanTrace.post("Scanner image data became ready after \(attempt) checks.")
                }
                return
            } catch let error as FujitsuSCSIStatusError {
                if error.isTemporaryNoData || error.isBusy {
                    if attempt == 1 || attempt % 50 == 0 {
                        ScanTrace.post("Scanner has no image data yet; waiting (\(attempt)).")
                    }
                    try await Task.sleep(nanoseconds: Self.imageDataPollInterval)
                    continue
                }
                if error.isUnsupportedCommand {
                    ScanTrace.post("Read-image-count is unsupported by scanner: \(error.localizedDescription)")
                    return
                }
                throw error
            } catch {
                throw error
            }
        }

        throw ScannerError.transportUnavailable("Timed out waiting for scanner image data.")
    }

    @discardableResult
    private func sendSCSICommand(
        _ scsiCommand: [UInt8],
        output: Data? = nil,
        expectedReadLength: Int? = nil,
        allowShortRead: Bool = false,
        requestSenseOnError: Bool = true,
        shortTimeout: Bool = false
    ) async throws -> Data {
        lastReadHitEndOfMedium = false
        var wrapper = [UInt8](repeating: 0, count: commandWrapperLength)
        wrapper[0] = 0x43
        wrapper.replaceSubrange(commandWrapperOffset..<(commandWrapperOffset + scsiCommand.count), with: scsiCommand)
        try await transport.bulkWrite(endpoint: 0, data: Data(wrapper), timeoutMilliseconds: shortTimeout ? shortCommandTimeout : commandTimeout)

        if let output, !output.isEmpty {
            try await transport.bulkWrite(endpoint: 0, data: output, timeoutMilliseconds: dataTimeout)
        }

        var input = Data()
        var shortRead = false
        if let expectedReadLength {
            do {
                let data = try await transport.bulkRead(endpoint: 0, length: expectedReadLength, timeoutMilliseconds: dataTimeout)
                input = data
                shortRead = data.count != expectedReadLength
                if shortRead, !allowShortRead {
                    throw ScannerError.transportUnavailable("USB short read \(data.count)/\(expectedReadLength).")
                }
            } catch {
                ScanTrace.post("Image data phase failed; attempting to recover scanner status.")
                if let recovered = try? await transport.bulkRead(
                    endpoint: 0,
                    length: statusLength,
                    timeoutMilliseconds: commandTimeout
                ), recovered.count == statusLength {
                    let recoveredStatus = [UInt8](recovered)[statusOffset]
                    ScanTrace.post("Recovered SCSI status \(recoveredStatus) after failed data phase.")
                    if recoveredStatus > 0 {
                        if requestSenseOnError, let sense = try? await requestSenseData() {
                            throw FujitsuSCSIStatusError(statusByte: recoveredStatus, sense: sense)
                        }
                        throw FujitsuSCSIStatusError(statusByte: recoveredStatus, sense: nil)
                    }
                } else {
                    ScanTrace.post("No scanner status packet was recoverable after the failed data phase.")
                }
                throw error
            }
        }

        let status = try await transport.bulkRead(endpoint: 0, length: statusLength, timeoutMilliseconds: shortTimeout ? shortCommandTimeout : commandTimeout)
        guard status.count == statusLength else {
            throw ScannerError.transportUnavailable("USB status packet had invalid length \(status.count).")
        }
        let statusByte = [UInt8](status)[statusOffset]
        if statusByte == 8 {
            throw FujitsuSCSIStatusError(statusByte: statusByte, sense: nil)
        }
        if statusByte > 0 {
            if requestSenseOnError, let sense = try? await requestSenseData() {
                if sense.isBenignEndOfPage {
                    ScanTrace.post(sense.traceDescription)
                    lastReadHitEndOfMedium = sense.endOfMedium
                    if sense.incorrectLength, expectedReadLength != nil, input.count == expectedReadLength {
                        input = Data(input.prefix(max(0, input.count - sense.information)))
                    }
                    return input
                }
                throw FujitsuSCSIStatusError(statusByte: statusByte, sense: sense)
            }
            throw FujitsuSCSIStatusError(statusByte: statusByte, sense: nil)
        }
        if shortRead, input.isEmpty {
            throw ScannerError.transportUnavailable("Scanner returned no image data.")
        }
        return input
    }

    private func requestSense() async throws -> String {
        try await requestSenseData().traceDescription
    }

    private func requestSenseData() async throws -> FujitsuSenseData {
        let data = try await sendSCSICommand(
            [0x03, 0, 0, 0, 0x12, 0],
            expectedReadLength: 0x12,
            requestSenseOnError: false
        )
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else {
            return FujitsuSenseData(shortResponseLength: bytes.count)
        }
        return FujitsuSenseData(bytes: bytes)
    }

    private static func encodeImage(
        data: Data,
        size: FujitsuImageSize,
        plan: FujitsuScanPlan,
        interlace: FujitsuColorInterlace
    ) throws -> Data {
        #if os(macOS)
        let sourceBytesPerRow = plan.bytesPerLine(forWidth: size.width)
        guard data.count >= sourceBytesPerRow * size.height else {
            throw ScannerError.outputFailed("Received \(data.count) image bytes, expected \(sourceBytesPerRow * size.height).")
        }

        let samples = FujitsuScanSnapImageDecoder.normalizedSamples(
            data: data,
            width: size.width,
            height: size.height,
            scannerColorMode: plan.scannerColorMode,
            outputColorMode: plan.colorMode,
            interlace: interlace
        )
        let samplesPerPixel = samples.samplesPerPixel
        let bitsPerSample = 8
        let bytesPerRow = size.width * samplesPerPixel
        let colorSpaceName: NSColorSpaceName = samplesPerPixel == 3 ? .deviceRGB : .deviceWhite
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size.width,
            pixelsHigh: size.height,
            bitsPerSample: bitsPerSample,
            samplesPerPixel: samplesPerPixel,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: colorSpaceName,
            bytesPerRow: bytesPerRow,
            bitsPerPixel: samplesPerPixel * bitsPerSample
        ) else {
            throw ScannerError.outputFailed("Could not create bitmap image from scanner data.")
        }
        guard let destination = bitmap.bitmapData else {
            throw ScannerError.outputFailed("Could not access bitmap storage for scanner data.")
        }
        samples.bytes.withUnsafeBufferPointer { buffer in
            guard let source = buffer.baseAddress else { return }
            destination.update(from: source, count: bytesPerRow * size.height)
        }
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw ScannerError.outputFailed("Could not encode scanner data as JPEG.")
        }
        return jpeg
        #endif
    }

    private static func actualImageSize(
        requested: FujitsuImageSize,
        dataCount: Int,
        plan: FujitsuScanPlan
    ) throws -> FujitsuImageSize {
        let bytesPerRow = plan.bytesPerLine(forWidth: requested.width)
        let rows = min(requested.height, dataCount / bytesPerRow)
        guard rows > 0 else {
            throw ScannerError.outputFailed("The scanner returned no complete image rows.")
        }
        return FujitsuImageSize(width: requested.width, height: rows)
    }

    private static func put(_ bytes: inout [UInt8], offset: Int, value: Int, byteCount: Int) {
        for index in 0..<byteCount {
            let shift = (byteCount - index - 1) * 8
            bytes[offset + index] = UInt8((value >> shift) & 0xff)
        }
    }

    private static func read(_ bytes: [UInt8], offset: Int, byteCount: Int) -> Int {
        var value = 0
        for index in 0..<byteCount {
            value = (value << 8) | Int(bytes[offset + index])
        }
        return value
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard bytes.count >= offset + length else { return "" }
        return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// Converts raw Fujitsu sample data into conventional 8-bit gray or RGB rows.
///
/// Fujitsu scanners return grayscale and RGB samples with inverted polarity
/// (SANE `reverse_by_mode`), line-art as packed 1-bit rows with 1 = black, and
/// colour in one of several interlacings. Models that only scan in colour get
/// grayscale and line-art derived here, the same way SANE's
/// `downsample_from_buffer()` does it: average of the three channels, and a
/// fixed mid-range threshold for line-art.
enum FujitsuScanSnapImageDecoder {
    nonisolated struct Samples: Equatable, Sendable {
        let bytes: [UInt8]
        let samplesPerPixel: Int
    }

    static let lineartThreshold: UInt8 = 127

    static func normalizedSamples(
        data: Data,
        width: Int,
        height: Int,
        scannerColorMode: ScanColorMode,
        outputColorMode: ScanColorMode,
        interlace: FujitsuColorInterlace
    ) -> Samples {
        switch scannerColorMode {
        case .lineart:
            return Samples(bytes: expandLineart(data: data, width: width, height: height), samplesPerPixel: 1)
        case .gray:
            return Samples(bytes: invert(data: data, count: width * height), samplesPerPixel: 1)
        case .color:
            let rgb = deinterlacedInvertedRGB(data: data, width: width, height: height, interlace: interlace)
            switch outputColorMode {
            case .color:
                return Samples(bytes: rgb, samplesPerPixel: 3)
            case .gray:
                return Samples(bytes: averageToGray(rgb: rgb, pixelCount: width * height), samplesPerPixel: 1)
            case .lineart:
                let gray = averageToGray(rgb: rgb, pixelCount: width * height)
                return Samples(bytes: gray.map { $0 < lineartThreshold ? 0 : 255 }, samplesPerPixel: 1)
            }
        }
    }

    /// Validates a scanner-produced JPEG and converts it to the requested
    /// output mode. Colour output is passed through untouched; grayscale and
    /// line-art are derived by decoding once and re-encoding as gray JPEG.
    static func finishHardwareJPEG(_ jpeg: Data, outputColorMode: ScanColorMode) throws -> (data: Data, size: FujitsuImageSize) {
        guard let source = NSBitmapImageRep(data: jpeg), source.pixelsWide > 0, source.pixelsHigh > 0 else {
            throw ScannerError.outputFailed("The scanner's JPEG data could not be decoded.")
        }
        let size = FujitsuImageSize(width: source.pixelsWide, height: source.pixelsHigh)
        if outputColorMode == .color {
            return (jpeg, size)
        }

        guard let cgImage = source.cgImage,
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            throw ScannerError.outputFailed("Could not convert the scanner's JPEG data to grayscale.")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let gray = context.data else {
            throw ScannerError.outputFailed("Could not access grayscale conversion output.")
        }
        let pixels = gray.bindMemory(to: UInt8.self, capacity: size.width * size.height)
        if outputColorMode == .lineart {
            for index in 0..<(size.width * size.height) {
                pixels[index] = pixels[index] < lineartThreshold ? 0 : 255
            }
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: size.width, bitsPerPixel: 8
        ), let destination = bitmap.bitmapData else {
            throw ScannerError.outputFailed("Could not create grayscale bitmap from scanner JPEG.")
        }
        destination.update(from: pixels, count: size.width * size.height)
        guard let encoded = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw ScannerError.outputFailed("Could not re-encode the converted page as JPEG.")
        }
        return (encoded, size)
    }

    private static func expandLineart(data: Data, width: Int, height: Int) -> [UInt8] {
        let sourceBytesPerRow = (width + 7) / 8
        var output = [UInt8](repeating: 255, count: width * height)
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<height {
                let sourceRow = source + row * sourceBytesPerRow
                let destinationOffset = row * width
                for column in 0..<width {
                    let isBlack = (sourceRow[column / 8] & (0x80 >> (column % 8))) != 0
                    output[destinationOffset + column] = isBlack ? 0 : 255
                }
            }
        }
        return output
    }

    private static func invert(data: Data, count: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: count)
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<count {
                output[index] = source[index] ^ 0xff
            }
        }
        return output
    }

    private static func deinterlacedInvertedRGB(data: Data, width: Int, height: Int, interlace: FujitsuColorInterlace) -> [UInt8] {
        let bytesPerRow = width * 3
        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            switch interlace {
            case .rgb:
                for index in 0..<(bytesPerRow * height) {
                    output[index] = source[index] ^ 0xff
                }
            case .bgr:
                for row in 0..<height {
                    let base = row * bytesPerRow
                    for column in 0..<width {
                        let pixel = base + column * 3
                        output[pixel] = source[pixel + 2] ^ 0xff
                        output[pixel + 1] = source[pixel + 1] ^ 0xff
                        output[pixel + 2] = source[pixel] ^ 0xff
                    }
                }
            case .rrggbb:
                for row in 0..<height {
                    let base = row * bytesPerRow
                    for column in 0..<width {
                        let pixel = base + column * 3
                        output[pixel] = source[base + column] ^ 0xff
                        output[pixel + 1] = source[base + width + column] ^ 0xff
                        output[pixel + 2] = source[base + 2 * width + column] ^ 0xff
                    }
                }
            }
        }
        return output
    }

    private static func averageToGray(rgb: [UInt8], pixelCount: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: pixelCount)
        rgb.withUnsafeBufferPointer { buffer in
            guard let source = buffer.baseAddress else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 3
                let sum = Int(source[offset]) + Int(source[offset + 1]) + Int(source[offset + 2])
                output[pixel] = UInt8(sum / 3)
            }
        }
        return output
    }
}

/// Downloadable gamma table (SEND data type 0x83), built like SANE's
/// `send_lut()` with brightness and contrast at their defaults: a straight line
/// from `1 << inputBits` input values onto 8-bit output.
enum FujitsuGammaTable {
    static let headerLength = 10

    static func payload(inputBits: Int) -> [UInt8] {
        let entries = 1 << inputBits
        let slope = 256.0 / Double(entries)
        var payload = [UInt8](repeating: 0, count: headerLength + entries)
        payload[2] = 0x10
        payload[4] = UInt8(truncatingIfNeeded: entries >> 8)
        payload[5] = UInt8(truncatingIfNeeded: entries)
        payload[6] = 0x01
        payload[7] = 0x00
        for input in 0..<entries {
            let output = max(0, min(255, Int(Double(input) * slope - 0.5)))
            payload[headerLength + input] = UInt8(output)
        }
        return payload
    }
}

private struct FujitsuSenseData {
    let senseKey: UInt8
    let asc: UInt8
    let ascq: UInt8
    let information: Int
    let endOfMedium: Bool
    let incorrectLength: Bool
    let shortResponseLength: Int?

    init(bytes: [UInt8]) {
        self.senseKey = bytes[2] & 0x0f
        self.asc = bytes[12]
        self.ascq = bytes[13]
        self.information = FujitsuSenseData.read(bytes, offset: 3, byteCount: 4)
        self.endOfMedium = (bytes[2] & 0x40) != 0
        self.incorrectLength = (bytes[2] & 0x20) != 0
        self.shortResponseLength = nil
    }

    init(shortResponseLength: Int) {
        self.senseKey = 0xff
        self.asc = 0xff
        self.ascq = 0xff
        self.information = 0
        self.endOfMedium = false
        self.incorrectLength = false
        self.shortResponseLength = shortResponseLength
    }

    var isBenignEndOfPage: Bool {
        senseKey == 0x00 && asc == 0x00 && ascq == 0x00 && (endOfMedium || incorrectLength)
    }

    var isBusy: Bool {
        senseKey == 0x02 && asc == 0x00 && ascq == 0x00
    }

    var isTemporaryNoData: Bool {
        senseKey == 0x03 && asc == 0x80 && ascq == 0x13
    }

    var isNoDocuments: Bool {
        senseKey == 0x03 && asc == 0x80 && [0x03, 0x20, 0x30].contains(ascq)
    }

    var isPaperJam: Bool {
        senseKey == 0x03 && asc == 0x80 && [0x01, 0x04, 0x07, 0x08].contains(ascq)
    }

    var isCoverOpen: Bool {
        senseKey == 0x03 && asc == 0x80 && ascq == 0x02
    }

    var isIllegalRequestInvalidField: Bool {
        senseKey == 0x05 && asc == 0x26
    }

    var traceDescription: String {
        if let shortResponseLength {
            return "Request sense returned a short response (\(shortResponseLength) bytes)."
        }
        return String(
            format: "Sense key 0x%02x ASC 0x%02x ASCQ 0x%02x EOM %@ ILI %@ info %d.",
            senseKey,
            asc,
            ascq,
            endOfMedium ? "yes" : "no",
            incorrectLength ? "yes" : "no",
            information
        )
    }

    private static func read(_ bytes: [UInt8], offset: Int, byteCount: Int) -> Int {
        guard bytes.count >= offset + byteCount else { return 0 }
        var value = 0
        for index in 0..<byteCount {
            value = (value << 8) | Int(bytes[offset + index])
        }
        return value
    }
}

private struct FujitsuSCSIStatusError: LocalizedError {
    let statusByte: UInt8
    let sense: FujitsuSenseData?

    var isBusy: Bool {
        statusByte == 8 || sense?.isBusy == true
    }

    var isTemporaryNoData: Bool {
        sense?.isTemporaryNoData == true
    }

    var isNoDocuments: Bool {
        sense?.isNoDocuments == true
    }

    var isUnsupportedCommand: Bool {
        sense?.isIllegalRequestInvalidField == true
    }

    var errorDescription: String? {
        if let sense {
            if sense.isNoDocuments {
                return "The document feeder is empty."
            }
            if sense.isPaperJam {
                return "The scanner reported a paper jam or double feed."
            }
            if sense.isCoverOpen {
                return "The scanner cover is open."
            }
            return "Scanner reported SCSI status \(statusByte). \(sense.traceDescription)"
        }
        return "Scanner reported SCSI status \(statusByte)."
    }
}

nonisolated struct FujitsuImageSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// One side of a sheet as delivered by the scanner, before decoding.
private struct FujitsuRawImage: Sendable {
    let side: PageSide
    let size: FujitsuImageSize
    let data: Data
    /// `data` is a complete JPEG file from the scanner rather than raw samples.
    var isJPEG = false
}

private final class FujitsuJPEGReadState {
    let side: PageSide
    let splitter: FujitsuJPEGStreamSplitter
    let byteCap: Int
    var totalBytes = 0
    var didCheckImageCount = false
    var isFinished = false

    init(side: PageSide, splitter: FujitsuJPEGStreamSplitter, byteCap: Int) {
        self.side = side
        self.splitter = splitter
        self.byteCap = byteCap
    }

    var frameSize: FujitsuImageSize {
        FujitsuImageSize(width: splitter.frameWidth, height: splitter.frameHeight)
    }

    func image(_ data: Data) -> FujitsuRawImage {
        FujitsuRawImage(side: side, size: frameSize, data: data, isJPEG: true)
    }
}

private final class FujitsuImageReadState {
    let side: PageSide
    let size: FujitsuImageSize
    var data = Data()
    var remaining: Int
    var didCheckImageCount = false
    var isFinished = false

    init(side: PageSide, size: FujitsuImageSize, byteCount: Int) {
        self.side = side
        self.size = size
        self.remaining = byteCount
        self.data.reserveCapacity(byteCount)
    }
}

/// Resolved acquisition parameters for one batch.
///
/// `colorMode` is what the user asked for and what the emitted `PageFrame`
/// contains. `scannerColorMode` is what the scanner is asked to produce; the
/// two differ on models that emulate grayscale/line-art in software.
struct FujitsuScanPlan: Sendable {
    let options: ScanOptions
    let resolutionDPI: Int
    let colorMode: ScanColorMode
    let scannerColorMode: ScanColorMode
    let scannerBuffering: Bool
    /// Ask the scanner for JPEG output (window compression type 0x81).
    let hardwareJPEG: Bool
    /// Fujitsu JPEG "Q" argument, 1 (smallest file) to 7 (largest); 0 means 4.
    let jpegQualityArgument: UInt8
    let isDuplex: Bool
    let sourceWindowID: UInt8
    let widthScannerUnits: Int
    let heightScannerUnits: Int
    let paperWidthScannerUnits: Int
    let paperHeightScannerUnits: Int
    let imageSize: FujitsuImageSize

    func bytesPerLine(forWidth width: Int) -> Int {
        switch scannerColorMode {
        case .color:
            width * 3
        case .gray:
            width
        case .lineart:
            (width + 7) / 8
        }
    }

    func expectedByteCount(for size: FujitsuImageSize) -> Int {
        bytesPerLine(forWidth: size.width) * size.height
    }

    var bitsPerPixel: UInt8 {
        scannerColorMode == .lineart ? 1 : 8
    }

    var composition: UInt8 {
        switch scannerColorMode {
        case .lineart:
            0
        case .gray:
            2
        case .color:
            5
        }
    }

    var traceDescription: String {
        let side = sourceWindowID == 0x80 ? "back" : isDuplex ? "duplex" : "front"
        let mode = colorMode == scannerColorMode
            ? colorMode.rawValue.lowercased()
            : "\(colorMode.rawValue.lowercased()) (scanned as \(scannerColorMode.rawValue.lowercased()))"
        return "\(side) \(resolutionDPI)dpi \(mode)\(scannerBuffering ? " with scanner buffering" : "")\(hardwareJPEG ? " as hardware JPEG q\(jpegQualityArgument)" : "")"
    }

    init(options: ScanOptions, profile: FujitsuScanSnapModelProfile) {
        self.options = options
        self.resolutionDPI = options.resolutionDPI
        self.colorMode = options.colorMode
        self.scannerColorMode = profile.emulatesMonochromeInSoftware ? .color : options.colorMode
        self.scannerBuffering = options.acquisition.scannerBuffering && profile.capabilities.supportsScannerBuffering
        self.hardwareJPEG = options.acquisition.hardwareCompression && profile.capabilities.supportsHardwareCompression
        self.jpegQualityArgument = Self.jpegQualityArgument(forExportQuality: options.export.jpegQuality)
        self.isDuplex = options.source == .adfDuplex
        self.sourceWindowID = options.source == .adfBack ? 0x80 : 0x00

        let widthInches = 8.5
        let heightInches = 14.0
        // Pixels per line are rounded down to the model's modulus (SANE
        // ppl_mod_by_mode) and the window width is derived from that, exactly
        // as SANE does. With a modulus of 1 this is 8.5 * 1200 = 10200 units.
        // JPEG needs whole 8x8 blocks (SANE rounds both dimensions to 8).
        let modulus = max(1, profile.pixelsPerLineModulus, hardwareJPEG ? 8 : 1)
        var pixelsWide = Int(widthInches * Double(options.resolutionDPI))
        pixelsWide -= pixelsWide % modulus
        var lines = Int(heightInches * Double(options.resolutionDPI))
        if hardwareJPEG {
            lines -= lines % 8
        }
        self.widthScannerUnits = pixelsWide * 1200 / options.resolutionDPI
        self.heightScannerUnits = lines * 1200 / options.resolutionDPI
        // Match the millimetre-to-scanner-unit rounding used by SANE for the
        // physical ADF sheet while retaining the exact requested image window.
        self.paperWidthScannerUnits = 10_201
        self.paperHeightScannerUnits = 16_802
        self.imageSize = FujitsuImageSize(width: pixelsWide, height: lines)
    }

    /// Maps the export JPEG quality (0.4...1.0) onto Fujitsu's 1...7 argument.
    /// The steps are deliberately flat at the top: on the iX500, Q5 yields
    /// ~2 MB per A4 colour page at 300 dpi and Q6 already ~6 MB with no visible
    /// gain, so only the lossless preset asks for Q7.
    static func jpegQualityArgument(forExportQuality quality: Double) -> UInt8 {
        switch quality {
        case ..<0.5: 1
        case ..<0.65: 2
        case ..<0.78: 3
        case ..<0.88: 4
        case ..<0.97: 5
        case ..<1.0: 6
        default: 7
        }
    }
}
