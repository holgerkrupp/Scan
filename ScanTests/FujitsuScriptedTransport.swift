import Foundation
@testable import Scan

/// A `USBDeviceTransport` that behaves like a Fujitsu ScanSnap on the wire
/// without any hardware: it understands the 31-byte command wrapper, answers
/// data-in commands (inquiry, request sense, pixel size, image reads, hardware
/// status) with plausible data, accepts data-out payloads, and returns SCSI
/// status packets. Every bulk write and every bulk read request is recorded in
/// `transcript`, which makes the exact command sequence of a driver testable.
///
/// Image data is synthetic: each sheet has the configured pixel size, the
/// bytes-per-line follow the composition byte of the last SET WINDOW, and the
/// feeder holds `sheets` sheets before OBJECT POSITION reports "no documents".
final class FujitsuScriptedTransport: USBDeviceTransport, @unchecked Sendable {
    let identity: ScannerIdentity
    var endpointSummary: String { get async { "scripted bulk out 0x02, bulk in 0x81" } }

    private(set) var transcript: [String] = []

    private let pixelWidth: Int
    private let pixelHeight: Int
    private var sheetsRemaining: Int
    private var composition: UInt8 = 5
    private var awaitingPayloadBytes = 0
    private var pendingDataIn: Data?
    private var pendingStatus: UInt8 = 0
    private var pendingSense: (key: UInt8, asc: UInt8, ascq: UInt8)?
    private var imageRemaining: [Bool: Int] = [false: 0, true: 0]

    init(identity: ScannerIdentity, pixelWidth: Int, pixelHeight: Int, sheets: Int) {
        self.identity = identity
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sheetsRemaining = sheets
    }

    func open() async throws {
        transcript.append("OPEN")
    }

    func close() async {
        transcript.append("CLOSE")
    }

    func abort() async {
        transcript.append("ABORT")
    }

    func controlTransfer(request: USBControlRequest) async throws -> Data {
        throw ScannerError.protocolNotImplemented("Control transfers are not scripted.")
    }

    func bulkWrite(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws {
        transcript.append("W " + Self.hex(data))
        if awaitingPayloadBytes > 0 {
            awaitingPayloadBytes = 0
            handlePayload(data)
            return
        }
        guard data.count == 0x1f, data[0] == 0x43 else {
            throw ScannerError.transportUnavailable("Unexpected write of \(data.count) bytes outside a command wrapper.")
        }
        handleCommand([UInt8](data[0x13..<0x1f]))
    }

    func bulkRead(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        transcript.append("R \(length)")
        if let data = pendingDataIn {
            pendingDataIn = nil
            return data.prefix(length)
        }
        var status = Data(repeating: 0, count: 13)
        status[9] = pendingStatus
        pendingStatus = 0
        return status.prefix(length)
    }

    // MARK: - Scanner model

    private var bytesPerLine: Int {
        switch composition {
        case 0, 1: (pixelWidth + 7) / 8
        case 2: pixelWidth
        default: pixelWidth * 3
        }
    }

    private func handleCommand(_ cdb: [UInt8]) {
        switch cdb[0] {
        case 0x00: // TEST UNIT READY
            break
        case 0x12: // INQUIRY
            var response = [UInt8](repeating: 0, count: 96)
            response[0] = 0x06
            response.replaceSubrange(8..<16, with: Array("FUJITSU ".utf8))
            response.replaceSubrange(16..<32, with: Array("ScanSnap S1500  ".utf8))
            response.replaceSubrange(32..<36, with: Array("0M00".utf8))
            pendingDataIn = Data(response.prefix(Int(cdb[4])))
        case 0x03: // REQUEST SENSE
            var response = [UInt8](repeating: 0, count: 18)
            if let sense = pendingSense {
                response[2] = sense.key
                response[12] = sense.asc
                response[13] = sense.ascq
                pendingSense = nil
            }
            pendingDataIn = Data(response.prefix(Int(cdb[4])))
        case 0x15: // MODE SELECT
            awaitingPayloadBytes = Int(cdb[4])
        case 0x24: // SET WINDOW
            awaitingPayloadBytes = Self.int(cdb, 6, 3)
        case 0x2a: // SEND
            awaitingPayloadBytes = Self.int(cdb, 6, 3)
        case 0x1d: // SEND DIAGNOSTIC
            awaitingPayloadBytes = Self.int(cdb, 3, 2)
        case 0x1b: // SCAN
            awaitingPayloadBytes = Int(cdb[4])
        case 0x31: // OBJECT POSITION
            if cdb[1] & 0x07 == 0x01 {
                if sheetsRemaining == 0 {
                    pendingStatus = 2
                    pendingSense = (0x03, 0x80, 0x03)
                } else {
                    sheetsRemaining -= 1
                    imageRemaining = [false: bytesPerLine * pixelHeight, true: bytesPerLine * pixelHeight]
                }
            }
        case 0x28: // READ
            let back = cdb[5] & 0x80 != 0
            let length = Self.int(cdb, 6, 3)
            if cdb[2] == 0x80 {
                var response = [UInt8](repeating: 0, count: 32)
                Self.put(&response, 0, pixelWidth, 4)
                Self.put(&response, 4, pixelHeight, 4)
                pendingDataIn = Data(response.prefix(length))
            } else {
                let available = imageRemaining[back] ?? 0
                let count = min(length, available)
                imageRemaining[back] = available - count
                pendingDataIn = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
            }
        case 0xc2: // GET HW STATUS
            var response = [UInt8](repeating: 0, count: 12)
            response[3] = sheetsRemaining == 0 ? 0x80 : 0x00
            pendingDataIn = Data(response.prefix(Self.int(cdb, 7, 2)))
        case 0xf1: // SCANNER CONTROL (incl. read-image-count)
            break
        default:
            pendingStatus = 2
            pendingSense = (0x05, 0x20, 0x00)
        }
    }

    private func handlePayload(_ payload: Data) {
        // SET WINDOW: remember the composition of the first descriptor.
        if payload.count >= 8 + 0x1a, payload[6] == 0, payload[7] == 64 {
            composition = payload[8 + 0x19]
        }
    }

    private static func int(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
    }

    private static func put(_ bytes: inout [UInt8], _ offset: Int, _ value: Int, _ count: Int) {
        for index in 0..<count {
            bytes[offset + index] = UInt8((value >> ((count - index - 1) * 8)) & 0xff)
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
