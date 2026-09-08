import AppKit
import Foundation

struct FujitsuScanSnapS1500Driver: ScannerDriver {
    let name = "Fujitsu ScanSnap S1500/S1500M"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = [
        USBDeviceID(vendorID: 0x04c5, productID: 0x11a2)
    ]

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapS1500Device(identity: identity, transport: transport)
    }
}

final class FujitsuScanSnapS1500Device: ScannerDevice {
    let identity: ScannerIdentity
    let capabilities = ScannerCapabilities(
        sources: [.adfFront, .adfBack, .adfDuplex],
        colorModes: [.color, .gray, .lineart],
        resolutionsDPI: [150, 200, 300, 400, 600],
        supportsBlankPageRemoval: true,
        supportsDeskew: true,
        supportsAutoCrop: true,
        supportsDuplex: true
    )

    private let transport: USBDeviceTransport?
    private var commandEngine: FujitsuSCSIOverUSBCommandEngine?
    private(set) var status: ScannerStatus = .disconnected
    private var isCancelled = false

    init(identity: ScannerIdentity, transport: USBDeviceTransport?) {
        self.identity = identity
        self.transport = transport
    }

    func open() async throws {
        guard let transport else {
            throw ScannerError.transportUnavailable("No USB transport was provided for \(identity.name).")
        }
        ScanTrace.post("Opening \(identity.name).")
        try await transport.open()
        commandEngine = FujitsuSCSIOverUSBCommandEngine(transport: transport)
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

private final class FujitsuSCSIOverUSBCommandEngine {
    private let transport: USBDeviceTransport

    private let commandTimeout: UInt32 = 30_000
    private let shortCommandTimeout: UInt32 = 500
    private let dataTimeout: UInt32 = 30_000
    private let commandWrapperLength = 0x1f
    private let commandWrapperOffset = 0x13
    private let statusLength = 0x0d
    private let statusOffset = 0x09
    // The S1500's USB image endpoint terminates data phases after 32 KiB.
    // readImage rounds this ceiling down to a whole number of scan lines
    // (30,600 bytes for 2550-pixel RGB at 300 dpi).
    private let transferChunkSize = 32 * 1024

    init(transport: USBDeviceTransport) {
        self.transport = transport
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
        let plan = FujitsuScanPlan(options: options)

        ScanTrace.post("Preparing \(plan.traceDescription).")
        do {
            try await scannerControl(function: 0x00, label: "ADF source")
        } catch {
            ScanTrace.post("ADF source selection was ignored by scanner: \(error.localizedDescription).")
        }
        try await modeSelectAuto(plan: plan)
        try await modeSelectDoubleFeedDefault()
        try await modeSelectDropoutDefault()
        try await modeSelectBufferOffAndClear()
        try await setWindow(plan: plan)
        if plan.colorMode != .lineart {
            try await sendDefaultGammaLUT()
        }
        await turnLampOnWhenReady()

        do {
            var pageCount = 0
            var sheetNumber = 0

            while sheetNumber < 500 {
                if isCancelled() {
                    throw ScannerError.scanCancelled
                }

                do {
                    try await objectPosition(action: 0x01, label: "feed", waitsForReady: true)
                } catch let error as FujitsuSCSIStatusError where error.isNoDocuments {
                    if pageCount == 0 {
                        throw ScannerError.feederEmpty
                    }
                    ScanTrace.post("Document feeder is empty; batch complete.")
                    break
                }

                try await startScan(plan: plan)
                let sheetFrames = try await readSheet(
                    plan: plan,
                    firstPageIndex: pageCount + 1,
                    isCancelled: isCancelled
                )
                for frame in sheetFrames {
                    try await onPage(frame)
                    pageCount += 1
                }
                sheetNumber += 1
                ScanTrace.post("Finished sheet \(sheetNumber).")
            }

            if sheetNumber == 500 {
                ScanTrace.post("Stopped after the 500-sheet safety limit.")
            }
            try? await modeSelectBufferOffAndClear()
            return pageCount
        } catch {
            ScanTrace.post("Scan command flow failed; halting paper transport.")
            try? await objectPosition(action: 0x04, label: "halt", waitsForReady: false)
            try? await scannerControl(function: 0x04, label: "cancel")
            throw error
        }
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

    private func modeSelectDropoutDefault() async throws {
        ScanTrace.post("Command: mode select dropout defaults.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x15
        command[1] = 0x10
        command[4] = 14

        var payload = [UInt8](repeating: 0, count: 14)
        payload[4] = 0x39
        payload[5] = 8
        try await sendSCSICommand(command, output: Data(payload))
    }

    private func modeSelectBufferOffAndClear() async throws {
        ScanTrace.post("Command: mode select buffer off and clear.")
        var command = [UInt8](repeating: 0, count: 6)
        command[0] = 0x15
        command[1] = 0x10
        command[4] = 12

        var payload = [UInt8](repeating: 0, count: 12)
        payload[4] = 0x3a
        payload[5] = 6
        payload[6] = 0x80
        payload[7] = 0xc0
        try await sendSCSICommand(command, output: Data(payload))
    }

    private func setWindow(plan: FujitsuScanPlan) async throws {
        ScanTrace.post("Command: set window.")
        var payload = [UInt8](repeating: 0, count: plan.isDuplex ? 136 : 72)
        Self.put(&payload, offset: 6, value: 64, byteCount: 2)

        var front = makeWindowDescriptor(windowID: 0x00, plan: plan, includePaperSize: true)
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

    private func makeWindowDescriptor(windowID: UInt8, plan: FujitsuScanPlan, includePaperSize: Bool) -> [UInt8] {
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
        descriptor[0x20] = 0
        descriptor[0x21] = 0

        if plan.colorMode == .color {
            descriptor[0x28] = 0xc1
            descriptor[0x29] = 0x80
            descriptor[0x2a] = 0x01
            descriptor[0x2b] = 0x00
            descriptor[0x2e] = 0
            descriptor[0x2f] = 0
            descriptor[0x32] = 0
        } else {
            descriptor[0x28] = 0x00
            descriptor[0x29] = plan.colorMode == .gray ? 0x80 : 0
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

        var payload = [UInt8](repeating: 0, count: 10 + 1024)
        payload[2] = 0x10
        Self.put(&payload, offset: 4, value: 1024, byteCount: 2)
        Self.put(&payload, offset: 6, value: 256, byteCount: 2)
        for input in 0..<1024 {
            let output = max(0, min(255, Int(Double(input) * 0.25 - 0.5)))
            payload[10 + input] = UInt8(output)
        }
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
    ) async throws -> PageFrame {
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
        let encoded = try Self.encodeImage(data: imageData, size: actualSize, plan: plan)
        return PageFrame(
            pageIndex: 1,
            side: side,
            pixelFormat: .jpeg,
            width: actualSize.width,
            height: actualSize.height,
            resolutionDPI: plan.resolutionDPI,
            data: encoded
        )
    }

    private func readSheet(
        plan: FujitsuScanPlan,
        firstPageIndex: Int,
        isCancelled: @escaping () -> Bool
    ) async throws -> [PageFrame] {
        let requestedSide: PageSide = plan.sourceWindowID == 0x80 ? .back : .front
        let frontSize = (try? await readPixelSize(side: requestedSide)) ?? plan.imageSize

        guard plan.isDuplex else {
            let frame = try await readImage(
                side: requestedSide,
                size: frontSize,
                plan: plan,
                isCancelled: isCancelled
            )
            return [Self.reindex(frame, pageIndex: firstPageIndex)]
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
                if idleAttempts >= 120 {
                    throw ScannerError.transportUnavailable("Timed out waiting for duplex image data.")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        return [
            try makeFrame(from: front, plan: plan, pageIndex: firstPageIndex),
            try makeFrame(from: back, plan: plan, pageIndex: firstPageIndex + 1)
        ]
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

    private func makeFrame(from state: FujitsuImageReadState, plan: FujitsuScanPlan, pageIndex: Int) throws -> PageFrame {
        let actualSize = try Self.actualImageSize(requested: state.size, dataCount: state.data.count, plan: plan)
        ScanTrace.post("Received \(state.data.count) bytes for \(state.side.rawValue) (\(actualSize.width)x\(actualSize.height)).")
        let encoded = try Self.encodeImage(data: state.data, size: actualSize, plan: plan)
        return PageFrame(
            pageIndex: pageIndex,
            side: state.side,
            pixelFormat: .jpeg,
            width: actualSize.width,
            height: actualSize.height,
            resolutionDPI: plan.resolutionDPI,
            data: encoded
        )
    }

    private static func reindex(_ frame: PageFrame, pageIndex: Int) -> PageFrame {
        PageFrame(
            pageIndex: pageIndex,
            side: frame.side,
            pixelFormat: frame.pixelFormat,
            width: frame.width,
            height: frame.height,
            resolutionDPI: frame.resolutionDPI,
            data: frame.data
        )
    }

    private func readImageCount(_ byteCount: Int, side: PageSide) async throws {
        ScanTrace.post("Command: read-image-count \(side.rawValue) \(byteCount) bytes.")
        var command = [UInt8](repeating: 0, count: 10)
        command[0] = 0xf1
        command[1] = 0x10
        command[2] = side == .back ? 0x80 : 0x00
        Self.put(&command, offset: 6, value: byteCount, byteCount: 3)
        ScanTrace.post("Command: read-image-count CDB \(Self.hex(command)).")

        for attempt in 1...120 {
            do {
                try await sendSCSICommand(command)
                if attempt > 1 {
                    ScanTrace.post("Scanner image data became ready after \(attempt) checks.")
                }
                return
            } catch let error as FujitsuSCSIStatusError {
                if error.isTemporaryNoData || error.isBusy {
                    if attempt == 1 || attempt % 10 == 0 {
                        ScanTrace.post("Scanner has no image data yet; waiting (\(attempt)).")
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
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

    private static func encodeImage(data: Data, size: FujitsuImageSize, plan: FujitsuScanPlan) throws -> Data {
        #if os(macOS)
        let samplesPerPixel = plan.colorMode == .color ? 3 : 1
        let bitsPerSample = 8
        let bytesPerRow = size.width * samplesPerPixel
        let sourceBytesPerRow = plan.bytesPerLine(forWidth: size.width)
        guard data.count >= sourceBytesPerRow * size.height else {
            throw ScannerError.outputFailed("Received \(data.count) image bytes, expected \(sourceBytesPerRow * size.height).")
        }
        let colorSpaceName: NSColorSpaceName = plan.colorMode == .color ? .deviceRGB : .deviceWhite
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
        if plan.colorMode == .lineart {
            data.withUnsafeBytes { rawBuffer in
                guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let destination = bitmap.bitmapData else { return }
                for row in 0..<size.height {
                    let sourceRow = source + row * sourceBytesPerRow
                    let destinationRow = destination + row * bytesPerRow
                    for column in 0..<size.width {
                        let isBlack = (sourceRow[column / 8] & (0x80 >> (column % 8))) != 0
                        destinationRow[column] = isBlack ? 0 : 255
                    }
                }
            }
        } else {
            data.withUnsafeBytes { rawBuffer in
                guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let destination = bitmap.bitmapData else { return }

                // The S1500 returns raw grayscale and RGB samples with Fujitsu's
                // inverted polarity. JPEG expects conventional sample values, so
                // normalize them here (the same mode-specific correction used by
                // SANE's Fujitsu backend). Line-art data has the opposite device
                // convention and is expanded separately above.
                for index in 0..<(bytesPerRow * size.height) {
                    destination[index] = source[index] ^ 0xff
                }
            }
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

private struct FujitsuImageSize {
    let width: Int
    let height: Int
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

private struct FujitsuScanPlan {
    let options: ScanOptions
    let resolutionDPI: Int
    let colorMode: ScanColorMode
    let isDuplex: Bool
    let sourceWindowID: UInt8
    let widthScannerUnits: Int
    let heightScannerUnits: Int
    let paperWidthScannerUnits: Int
    let paperHeightScannerUnits: Int
    let imageSize: FujitsuImageSize

    func bytesPerLine(forWidth width: Int) -> Int {
        switch colorMode {
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
        colorMode == .lineart ? 1 : 8
    }

    var composition: UInt8 {
        switch colorMode {
        case .lineart:
            0
        case .gray:
            2
        case .color:
            5
        }
    }

    var traceDescription: String {
        "\(sourceWindowID == 0x80 ? "back" : isDuplex ? "duplex" : "front") \(resolutionDPI)dpi \(colorMode.rawValue.lowercased())"
    }

    init(options: ScanOptions) {
        self.options = options
        self.resolutionDPI = options.resolutionDPI
        self.colorMode = options.colorMode
        self.isDuplex = options.source == .adfDuplex
        self.sourceWindowID = options.source == .adfBack ? 0x80 : 0x00

        let widthInches = 8.5
        let heightInches = 14.0
        self.widthScannerUnits = Int(widthInches * 1200.0)
        self.heightScannerUnits = Int(heightInches * 1200.0)
        // Match the millimetre-to-scanner-unit rounding used by SANE for the
        // physical ADF sheet while retaining the exact requested image window.
        self.paperWidthScannerUnits = 10_201
        self.paperHeightScannerUnits = 16_802
        self.imageSize = FujitsuImageSize(
            width: Int(widthInches * Double(options.resolutionDPI)),
            height: Int(heightInches * Double(options.resolutionDPI))
        )
    }
}
