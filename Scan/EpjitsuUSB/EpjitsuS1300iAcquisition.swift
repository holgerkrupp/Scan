import AppKit
import Foundation

// S1300i acquisition flow, following the command sequence documented by
// SANE's epjitsu backend: coarse and fine calibration against the scanner's
// white strip, a linear tone curve, then block-by-block image reads that end
// at the sheet length the scanner reports. The S300, S300M and S1300 keep the
// original flow in `ScanSnapS300Driver.swift`.

private enum EpjitsuCalibrationTargets {
    static let whiteFactor: [Float] = [1.0, 0.93, 0.98]
    /// Fine-calibration white level for the front and back sensor.
    static let fineGain: [Float] = [185, 150]
    static let coarseOffset = 15
    static let coarseGain = 88...92
    static let attempts = 8
    /// Lines averaged by one fine-calibration read.
    static let fineLines = 16
}

/// Unpacks one raw epjitsu line for one sensor into packed pixels in plane
/// order (blue, red, green), averaging neighbouring columns when the output
/// resolution is lower than the protocol resolution.
nonisolated private struct EpjitsuLineDescrambler {
    let planeStride: Int
    let planeWidth: Int
    let inputResolution: Int
    let outputResolution: Int
    let outputWidth: Int
    /// Byte offset of the green plane; the blue plane is twice as far off.
    let planeShift: Int

    func descramble(
        _ raw: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        sensor: Int,
        into output: UnsafeMutableBufferPointer<UInt8>,
        at outputStart: Int
    ) {
        var column = 0
        var sums = (0, 0, 0)
        var count = 0
        var destination = outputStart
        for k in 0...planeWidth {
            let thisColumn = k * outputResolution / inputResolution
            if count > 0, thisColumn != column {
                output[destination] = UInt8(sums.0 / count)
                output[destination + 1] = UInt8(sums.1 / count)
                output[destination + 2] = UInt8(sums.2 / count)
                destination += 3
                sums = (0, 0, 0)
                count = 0
                column = thisColumn
            }
            if k == planeWidth || thisColumn >= outputWidth { break }
            let base = lineStart + k * 3 + sensor
            sums.0 += Int(raw[base])
            sums.1 += Int(raw[base + planeStride + planeShift])
            sums.2 += Int(raw[base + 2 * planeStride + 2 * planeShift])
            count += 1
        }
    }
}

/// Collects the raw blocks of one sheet into front and back pages. Both
/// sensors are read in every line; the front image starts half an inch into
/// the scan (the lead-in before the paper edge), the back image is mirrored.
nonisolated private struct EpjitsuPageAssembler {
    private let settings: EpjitsuResolutionSettings
    private let outputResolution: Int
    private let descrambler: EpjitsuLineDescrambler
    private let pageWidth: Int
    private let xStart: Int
    private let sides: [PageSide]
    private var rows: [PageSide: [UInt8]] = [:]
    private var lastRow: [PageSide: Int] = [:]
    private var line: [UInt8]

    init(settings: EpjitsuResolutionSettings, outputResolution: Int, source: ScanSource) {
        self.settings = settings
        self.outputResolution = outputResolution
        let blockWidth = settings.maxWidth * outputResolution / settings.xResolution
        descrambler = EpjitsuLineDescrambler(
            planeStride: settings.planeStride,
            planeWidth: settings.planeWidth,
            inputResolution: settings.xResolution,
            outputResolution: outputResolution,
            outputWidth: blockWidth,
            planeShift: settings.shiftsColorPlanes ? 3 : 0
        )
        pageWidth = min(blockWidth, Int((8.5 * Double(outputResolution)).rounded()))
        xStart = (blockWidth - pageWidth) / 2
        switch source {
        case .adfBack: sides = [.back]
        case .adfDuplex: sides = [.front, .back]
        default: sides = [.front]
        }
        line = [UInt8](repeating: 0, count: blockWidth * 3)
        // Reserve the longest page up front: growing a ~30 MB array while the
        // sheet is moving stalls the reads long enough for the scanner's
        // buffer to fill, and the paper visibly stops.
        let maxRows = settings.maxHeight * outputResolution / settings.yResolution
        for side in sides {
            var pixels: [UInt8] = []
            pixels.reserveCapacity(pageWidth * 3 * maxRows)
            rows[side] = pixels
            lastRow[side] = -1
        }
    }

    /// Lines the front image skips at the start of the scan.
    private var frontLeadIn: Int { settings.yResolution / 2 }

    mutating func consume(_ block: Data, firstLine: Int) {
        let lineCount = block.count / settings.lineStride
        block.withUnsafeBytes { rawBytes in
            let raw = rawBytes.bindMemory(to: UInt8.self)
            for index in 0..<lineCount {
                let inputRow = firstLine + index
                for side in sides {
                    let skip = side == .front ? frontLeadIn : 0
                    let outputRow = (inputRow - skip) * outputResolution / settings.yResolution
                    guard inputRow >= skip, outputRow > lastRow[side, default: -1] else { continue }
                    lastRow[side] = outputRow
                    let sensor = side == .front ? 0 : 1
                    line.withUnsafeMutableBufferPointer { output in
                        descrambler.descramble(raw, lineStart: index * settings.lineStride, sensor: sensor, into: output, at: 0)
                    }
                    appendRow(from: line, side: side)
                }
            }
        }
    }

    private mutating func appendRow(from line: [UInt8], side: PageSide) {
        guard var pixels = rows.removeValue(forKey: side) else { return }
        let mirrored = side == .back
        for x in 0..<pageWidth {
            let source = (xStart + (mirrored ? pageWidth - 1 - x : x)) * 3
            // Raw planes are blue, red, green.
            pixels.append(line[source + 1])
            pixels.append(line[source + 2])
            pixels.append(line[source])
        }
        rows[side] = pixels
    }

    /// Both sides are cut to the same height; the back sensor sees the
    /// lead-in that the front image skips.
    func finish() throws -> [EpjitsuAcquiredPage] {
        let rowBytes = pageWidth * 3
        let height = sides.map { (rows[$0]?.count ?? 0) / rowBytes }.min() ?? 0
        guard height > 0 else {
            throw ScannerError.outputFailed("The epjitsu scan returned no image lines.")
        }
        return try sides.map { side in
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pageWidth,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: rowBytes,
                bitsPerPixel: 24
            ), let destination = bitmap.bitmapData else {
                throw ScannerError.outputFailed("Could not create an image buffer for epjitsu acquisition.")
            }
            rows[side, default: []].withUnsafeBufferPointer { pixels in
                if let baseAddress = pixels.baseAddress {
                    destination.update(from: baseAddress, count: rowBytes * height)
                }
            }
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
                throw ScannerError.outputFailed("Could not encode the epjitsu image as JPEG.")
            }
            return EpjitsuAcquiredPage(side: side, width: pageWidth, height: height, resolutionDPI: outputResolution, data: jpeg)
        }
    }
}

/// Runs the page assembler on its own serial queue so the USB reads keep
/// pace with the paper: unpacking a block takes longer than reading it, and
/// at 300 dpi the scanner's buffer fills and stops the sheet mid-page when
/// the reads wait for it.
nonisolated private final class EpjitsuBackgroundAssembler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "de.holgerkrupp.Scan.epjitsu-assembly", qos: .userInitiated)
    private var assembler: EpjitsuPageAssembler

    init(_ assembler: EpjitsuPageAssembler) {
        self.assembler = assembler
    }

    func consume(_ block: Data, firstLine: Int) {
        queue.async { self.assembler.consume(block, firstLine: firstLine) }
    }

    /// Waits for the queued blocks, then encodes the pages.
    func finish() async throws -> [EpjitsuAcquiredPage] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.assembler.finish() }) }
        }
    }
}

extension EpjitsuCommandEngine {
    /// Largest bulk read the scanner delivers in one transfer.
    private static let maximumTransfer = 0x10000
    /// Every image and calibration transfer ends with an 8-byte trailer.
    private static let trailerLength = 8
    private static let sensorCount = 2

    /// The S1300i acquisition: calibrate once, then read sheets until the
    /// feeder is empty. Each sheet yields both sides from a single pass.
    func scanS1300i(
        options: ScanOptions,
        onPage: @escaping (EpjitsuAcquiredPage) async throws -> Void
    ) async throws {
        let settings = try EpjitsuResolutionSettings.s1300i(
            usbPower: usbPower,
            requestedResolution: options.acquisition.resolutionDPI
        )
        ScanTrace.post("\(profile.name) scanning at \(settings.xResolution)x\(settings.yResolution) dpi on \(usbPower ? "USB bus" : "AC") power.")

        _ = try await readHardwareStatus()
        guard try await feedSheet() else {
            throw ScannerError.feederEmpty
        }
        try await coarseCalibrate(settings)
        try await fineCalibrate(settings)
        try await sendToneCurve()
        try await lamp(on: true)
        // Ask for the longest page; the scanner reports the real length while
        // the sheet passes (see `readSheet`).
        try await setWindow(settings.scanWindow(height: settings.maxHeight))

        var sheetCount = 0
        while true {
            if Task.isCancelled { throw ScannerError.scanCancelled }
            try await commandExpectingAcknowledgement([0x1b, 0xd6], label: "scan")
            let assembler = EpjitsuBackgroundAssembler(EpjitsuPageAssembler(
                settings: settings,
                outputResolution: options.acquisition.resolutionDPI,
                source: options.acquisition.source
            ))
            try await readSheet(settings) { block, firstLine in
                assembler.consume(block, firstLine: firstLine)
            }
            for page in try await assembler.finish() {
                try await onPage(page)
            }
            sheetCount += 1
            ScanTrace.post("Finished epjitsu sheet \(sheetCount).")

            _ = try await readHardwareStatus()
            guard try await feedSheet() else { break }
        }
        try? await lamp(on: false)
    }

    func discardStaleInput() async {
        for _ in 0..<8 {
            guard let chunk = try? await transport.bulkRead(endpoint: 0, length: Self.maximumTransfer, timeoutMilliseconds: 100),
                  !chunk.isEmpty else { return }
            ScanTrace.post("Discarded \(chunk.count) stale byte(s) from the \(profile.name).")
        }
    }

    /// The GET HARDWARE STATUS reply is read as one transfer: between sheets,
    /// while the scan window is still open, the S1300i answers with a single
    /// NAK (0x15), which callers treat as "no status now".
    func readS1300iHardwareStatusReply() async throws -> Data {
        let response = try await transport.bulkRead(
            endpoint: 0,
            length: profile.hardwareStatusResponseLength,
            timeoutMilliseconds: commandTimeout
        )
        guard !response.isEmpty else {
            throw ScannerError.transportUnavailable("\(profile.name) returned no bytes for hardware status.")
        }
        return response
    }

    // MARK: Calibration

    /// Coarse calibration searches the analogue front end's dark offset (lamp
    /// off) and gain (lamp on) per sensor by bisection over single lines.
    private func coarseCalibrate(_ settings: EpjitsuResolutionSettings) async throws {
        var payload = EpjitsuProtocolTables.coarseCalibration
        let width = settings.calibrationPlaneWidth
        let sensors = 0..<Self.sensorCount
        try await setWindow(Data(settings.coarseCalibrationWindow))

        try await lamp(on: false)
        var offset = [63, 63], low = [-64, -64], high = [63, 63], done = [false, false]
        for _ in 0..<EpjitsuCalibrationTargets.attempts {
            payload[5] = UInt8(truncatingIfNeeded: offset[0])
            payload[7] = UInt8(truncatingIfNeeded: offset[1])
            try await sendCommandWithPayload([0x1b, 0xc6], payload: Data(payload), label: "coarse calibration")
            let image = try await readCalibrationImage(settings, lines: 1)
            for sensor in sensors where !done[sensor] {
                let average = image[sensor].reduce(0) { $0 + Int($1) } / (width * 3)
                if average > EpjitsuCalibrationTargets.coarseOffset {
                    high[sensor] = offset[sensor]
                    offset[sensor] = (low[sensor] + high[sensor]) / 2
                } else if average < EpjitsuCalibrationTargets.coarseOffset {
                    low[sensor] = offset[sensor]
                    offset[sensor] = (low[sensor] + high[sensor]) / 2
                } else {
                    done[sensor] = true
                }
            }
            if !done.contains(false) { break }
        }

        try await lamp(on: true)
        var gain = [Int(payload[11]), Int(payload[13])]
        low = [0, 0]; high = [63, 63]; done = [false, false]
        for _ in 0..<EpjitsuCalibrationTargets.attempts {
            try await sendCommandWithPayload([0x1b, 0xc6], payload: Data(payload), label: "coarse calibration")
            let image = try await readCalibrationImage(settings, lines: 1)
            for sensor in sensors where !done[sensor] {
                var sums = [0, 0, 0], clipped = [0, 0, 0]
                for x in 0..<width {
                    for channel in 0..<3 {
                        let value = image[sensor][x * 3 + channel]
                        sums[channel] += Int(value)
                        if value == 255 { clipped[channel] += 1 }
                    }
                }
                let average = (0..<3).map { Int(Float(sums[$0]) * EpjitsuCalibrationTargets.whiteFactor[$0]) }.max()! / width
                let clippedPerMille = clipped.map { $0 * 1000 / width }.max()!
                if clippedPerMille > 9 || average > EpjitsuCalibrationTargets.coarseGain.upperBound {
                    high[sensor] = gain[sensor]
                    gain[sensor] = (low[sensor] + high[sensor]) / 2
                } else if average < EpjitsuCalibrationTargets.coarseGain.lowerBound {
                    low[sensor] = gain[sensor]
                    gain[sensor] = (low[sensor] + high[sensor]) / 2
                } else {
                    done[sensor] = true
                }
            }
            if !done.contains(false) { break }
            payload[11] = UInt8(truncatingIfNeeded: gain[0])
            payload[13] = UInt8(truncatingIfNeeded: gain[1])
        }
    }

    /// Fine calibration sets a gain per pixel and colour so a white reference
    /// reads the target level, iterating from the response measured at two
    /// fixed gains.
    private func fineCalibrate(_ settings: EpjitsuResolutionSettings) async throws {
        let width = settings.calibrationPlaneWidth
        let count = Self.sensorCount * width * 3
        let offsets = [UInt8](repeating: 0, count: count)
        var gains = [UInt8](repeating: 0xff, count: count)

        try await sendFineCalibration(settings, offsets: offsets, gains: gains)
        try await lamp(on: true)
        let lowGain = try await readFineCalibrationLine(settings)

        gains = [UInt8](repeating: 0xbf, count: count)
        try await sendFineCalibration(settings, offsets: offsets, gains: gains)
        var measured = try await readFineCalibrationLine(settings)

        let gainDelta = 0xff - 0xbf
        var slope = (0..<count).map { index -> Float in
            let valueDelta = Int(measured[index]) - Int(lowGain[index])
            // Limit the slope to 1 in case the reference clipped at 255.
            return valueDelta < gainDelta ? -1 : -Float(gainDelta) / Float(valueDelta)
        }
        var lastError = [Float](repeating: 0, count: count)

        for _ in 0..<EpjitsuCalibrationTargets.attempts {
            var errorSum = [[Float]](repeating: [0, 0, 0], count: Self.sensorCount)
            var errorSquares = errorSum
            for sensor in 0..<Self.sensorCount {
                for x in 0..<width {
                    for channel in 0..<3 {
                        let index = (sensor * width + x) * 3 + channel
                        let target = EpjitsuCalibrationTargets.fineGain[sensor] * EpjitsuCalibrationTargets.whiteFactor[channel]
                        let error = target - Float(measured[index])
                        // Overshot the previous correction: damp this pixel.
                        if error * lastError[index] < 0 { slope[index] *= 0.75 }
                        lastError[index] = error
                        let newGain = Int(gains[index]) + Int((error * slope[index]).rounded())
                        gains[index] = UInt8(clamping: newGain)
                        errorSum[sensor][channel] += error
                        errorSquares[sensor][channel] += error * error
                    }
                }
            }
            let converged = (0..<Self.sensorCount).allSatisfy { sensor in
                (0..<3).allSatisfy { channel in
                    let sum = errorSum[sensor][channel]
                    let mean = sum / Float(width)
                    let variance = (errorSquares[sensor][channel] - sum * sum / Float(width)) / Float(width)
                    return abs(mean) <= 1 && variance <= 3
                }
            }
            if converged { break }
            try await sendFineCalibration(settings, offsets: offsets, gains: gains)
            measured = try await readFineCalibrationLine(settings)
        }
    }

    /// Sends per-pixel dark offsets and gains (both indexed sensor, pixel,
    /// colour) interleaved into the scanner's raw line layout.
    private func sendFineCalibration(_ settings: EpjitsuResolutionSettings, offsets: [UInt8], gains: [UInt8]) async throws {
        let width = settings.calibrationPlaneWidth
        let planeStride = settings.calibrationPlaneStride * 2
        var raw = [UInt8](repeating: 0, count: settings.calibrationLineStride * 2)
        for sensor in 0..<Self.sensorCount {
            for x in 0..<width {
                for channel in 0..<3 {
                    let source = (sensor * width + x) * 3 + channel
                    let destination = channel * planeStride + x * 6 + sensor * 2
                    raw[destination] = offsets[source]
                    raw[destination + 1] = gains[source]
                }
            }
        }
        let data = Data(raw)
        try await setWindow(Data(settings.sendCalibrationWindow))
        try await commandExpectingAcknowledgement([0x1b, 0xc3], label: "gain calibration command")
        try await write(settings.gainHeader)
        try await writeAndExpectAcknowledgement(data, label: "gain calibration payload")
        try await commandExpectingAcknowledgement([0x1b, 0xc4], label: "offset calibration command")
        try await write(settings.offsetHeader)
        try await writeAndExpectAcknowledgement(data, label: "offset calibration payload")
    }

    /// Reads 16 calibration lines and returns their per-column average,
    /// indexed sensor, pixel, colour.
    private func readFineCalibrationLine(_ settings: EpjitsuResolutionSettings) async throws -> [UInt8] {
        let lines = EpjitsuCalibrationTargets.fineLines
        try await setWindow(Data(settings.fineCalibrationWindow))
        let image = try await readCalibrationImage(settings, lines: lines)
        let rowBytes = settings.calibrationPlaneWidth * 3
        var average = [UInt8](repeating: 0, count: Self.sensorCount * rowBytes)
        for sensor in 0..<Self.sensorCount {
            for column in 0..<rowBytes {
                var total = 0
                for row in 0..<lines { total += Int(image[sensor][row * rowBytes + column]) }
                average[sensor * rowBytes + column] = UInt8((total + lines / 2) / lines)
            }
        }
        return average
    }

    /// Triggers a calibration read (1b d2) and returns one packed image per
    /// sensor at full calibration width.
    private func readCalibrationImage(_ settings: EpjitsuResolutionSettings, lines: Int) async throws -> [[UInt8]] {
        try await commandExpectingAcknowledgement([0x1b, 0xd2], label: "calibration scan")
        let raw = try await readPayload(settings.calibrationLineStride * lines, label: "calibration data")
        let width = settings.calibrationPlaneWidth
        let descrambler = EpjitsuLineDescrambler(
            planeStride: settings.calibrationPlaneStride,
            planeWidth: width,
            inputResolution: settings.xResolution,
            outputResolution: settings.xResolution,
            outputWidth: width,
            planeShift: 0
        )
        return (0..<Self.sensorCount).map { sensor in
            var image = [UInt8](repeating: 0, count: width * 3 * lines)
            raw.withUnsafeBytes { rawBytes in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                image.withUnsafeMutableBufferPointer { output in
                    for line in 0..<lines {
                        descrambler.descramble(bytes, lineStart: line * settings.calibrationLineStride, sensor: sensor, into: output, at: line * width * 3)
                    }
                }
            }
            return image
        }
    }

    /// Linear 12-bit tone curve for the three colour planes, little endian.
    private func sendToneCurve() async throws {
        let entries = 0x1000
        var curve = [UInt8](repeating: 0, count: entries * 2 * 3)
        for plane in 0..<3 {
            for value in 0..<entries {
                curve[plane * entries * 2 + value * 2] = UInt8(value & 0xff)
                curve[plane * entries * 2 + value * 2 + 1] = UInt8((value >> 8) & 0x0f)
            }
        }
        try await sendCommandWithPayload([0x1b, 0xc5], payload: Data(curve), label: "tone curve")
    }

    // MARK: Image transfer

    /// Reads one sheet block by block (1b d3). After each block the scanner
    /// reports in 1b 43 how many lines the sheet has, which ends the transfer
    /// at the paper's trailing edge.
    private func readSheet(
        _ settings: EpjitsuResolutionSettings,
        consume: (Data, Int) -> Void
    ) async throws {
        var totalLines = settings.maxHeight
        var line = 0
        while line < totalLines {
            if Task.isCancelled { throw ScannerError.scanCancelled }
            let lines = min(settings.blockHeight, totalLines - line)
            try await commandExpectingAcknowledgement([0x1b, 0xd3], label: "image block")
            let block = try await readPayload(lines * settings.lineStride, label: "image data")
            try await write([0x1b, 0x43])
            let status = [UInt8](try await readExactly(10, label: "image block status"))
            consume(block, line)
            line += lines

            var reported = Int(status[6]) << 8 | Int(status[7])
            if reported % settings.blockHeight != 0 {
                reported += settings.blockHeight - reported % settings.blockHeight
            }
            if reported < settings.maxHeight { totalLines = reported }
        }
    }

    /// Reads a data transfer of `length` bytes plus its trailer and returns
    /// the data without the trailer. The S1300i expects full-size read
    /// requests even for the final, shorter part of a transfer.
    private func readPayload(_ length: Int, label: String) async throws -> Data {
        let expected = length + Self.trailerLength
        var result = Data()
        result.reserveCapacity(expected)
        while result.count < expected {
            let remaining = expected - result.count
            let chunk = try await transport.bulkRead(endpoint: 0, length: Self.maximumTransfer, timeoutMilliseconds: dataTimeout)
            guard !chunk.isEmpty else {
                throw ScannerError.transportUnavailable("\(profile.name) returned no bytes for \(label).")
            }
            result.append(chunk.prefix(remaining))
        }
        return result.prefix(length)
    }

    /// Pulls a sheet from the feeder (1b d4, payload 1), retrying a few times
    /// while the scanner reports no paper. Returns false when the feeder stays
    /// empty.
    private func feedSheet() async throws -> Bool {
        for _ in 0..<5 {
            try await write([0x1b, 0xd4])
            guard try await readExactly(1, label: "paper position command").first == 0x06 else { continue }
            try await write([0x01])
            switch try await readExactly(1, label: "paper position response").first {
            case 0x06: return true
            case 0x00, 0x15: continue
            default:
                throw ScannerError.transportUnavailable("\(profile.name) returned an unexpected paper-position status.")
            }
        }
        return false
    }
}
