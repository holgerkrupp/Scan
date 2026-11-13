import Foundation

/// Wire format of the ScanSnap iX500 Wi-Fi protocol ("VENS"). Pure functions, no I/O.
///
/// Sources, for interoperability: the protocol description of ScanSnack
/// (github.com/elte0/scansnack, `docs/protocol-ix500.md`, MIT) and a discovery
/// exchange with a real iX500 (interface version 6). Integers are big-endian.
nonisolated enum VENS {
    static let magic = Array("VENS".utf8)
    static let discoveryPort: UInt16 = 52217
    static let heartbeatSourcePort: UInt16 = 55264
    static let scanPort: UInt16 = 53218
    static let controlPort: UInt16 = 53219
    static let notificationPort: UInt32 = 55265
    static let serverHeaderLength = 16
    static let scsiReplyHeaderLength = 40
    static let maximumFrameLength = 0x400000
    static let readLength = 0x300000
    static let maximumImageLength = 64 << 20
    static let supportedResolutions = [150, 200, 300, 600]
    /// The image index is one byte and counts sides: start a new transfer well before it wraps.
    static let maximumSheetsPerTransfer = 120

    static let discoveryFlag: UInt16 = 0x0010
    static let heartbeatFlag: UInt16 = 0x1000
    private static let registrationBodyLength = 96
    private static let scannerTimeout: UInt8 = 0x1e
    private static let passwordKey = Array("pFusCANsNapFiPfu".utf8)
    /// Automatic page size, in 1/1200 inch.
    private static let autoPageWidth: UInt32 = 0x28d0
    private static let autoPageHeight: UInt32 = 0x44dc

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    static func probe(hostIP: [UInt8], hostMAC: [UInt8], replyPort: UInt16, flag: UInt16 = discoveryFlag, sequence: UInt32 = 0) -> [UInt8] {
        magic + bigEndian(sequence) + hostIP + hostMAC + bigEndian(UInt32(0)) + bigEndian(replyPort) + bigEndian(flag) + [UInt8](repeating: 0, count: 6)
    }

    static let startupNoticePort: UInt16 = 53220
    static let buttonPressedEvent: UInt32 = 0x01
    static let powerOffEvent: UInt32 = 0x10
    static let powerOnEvent: UInt32 = 0x21

    /// A UDP notice from the scanner: 48 bytes, sent three times about 0.5 s apart.
    static func parseNotification(_ data: [UInt8]) -> VENSNotification? {
        guard data.count >= 48, Array(data[0..<4]) == bigEndian(UInt32(48)), Array(data[4..<8]) == magic else { return nil }
        return VENSNotification(event: UInt32(data[8]) << 24 | UInt32(data[9]) << 16 | UInt32(data[10]) << 8 | UInt32(data[11]), counter: data[16])
    }

    static func parseDiscoveryReply(_ data: [UInt8]) -> VENSScannerInfo? {
        guard data.count >= 132, Array(data[0..<4]) == magic else { return nil }
        let name = asciiField(data[40..<104])
        let model = asciiField(data[104..<120])
        return VENSScannerInfo(
            ipAddress: Array(data[16..<20]),
            interfaceVersion: UInt16(data[8]) << 8 | UInt16(data[9]),
            name: name,
            model: model,
            serialNumber: name.components(separatedBy: "-").last ?? "",
            registeredHostIP: Array(data[120..<124]),
            registeredHostID: Array(data[124..<132])
        )
    }

    private static func asciiField(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func clientFrame(command: UInt32, mac: [UInt8], body: [UInt8] = []) -> [UInt8] {
        bigEndian(UInt32(32 + body.count)) + magic + bigEndian(command) + bigEndian(UInt32(0)) + mac
            + [UInt8](repeating: 0, count: 10) + body
    }

    /// Three decimal digits per character, as the scanner expects.
    static func encodedPassword(_ password: String) -> [UInt8] {
        let digits = zip(passwordKey, password.utf8).map { key, character in
            String(format: "%03d", Int(key) + Int(character) + 11)
        }
        return Array(digits.joined().utf8)
    }

    static func registrationBody(interfaceVersion: UInt16, hostIP: [UInt8], password: String, hostID: [UInt8], date: Date, timeZone: TimeZone) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: registrationBodyLength)
        func put(_ bytes: [UInt8], at offset: Int) { body.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put(bigEndian(interfaceVersion), at: 0)
        body[2] = scannerTimeout
        put(bigEndian(UInt32(1)), at: 8)
        put(hostIP, at: 12)
        put(bigEndian(notificationPort), at: 16)
        put(encodedPassword(password), at: 20)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        put(bigEndian(UInt16(parts.year ?? 0)), at: 68)
        put([UInt8(parts.month ?? 0), UInt8(parts.day ?? 0), UInt8(parts.hour ?? 0), UInt8(parts.minute ?? 0), UInt8(parts.second ?? 0)], at: 70)
        put(hostID, at: 76)
        if interfaceVersion > 3 { put(bigEndian(Int32(-timeZone.secondsFromGMT(for: date))), at: 84) }
        return body
    }

    static func registrationStatus(reply: [UInt8]) -> Int32? {
        guard reply.count >= 20 else { return nil }
        return Int32(bitPattern: UInt32(reply[8]) << 24 | UInt32(reply[9]) << 16 | UInt32(reply[10]) << 8 | UInt32(reply[11]))
    }

    static func scsiFrame(mac: [UInt8], cdb: [UInt8], output: [UInt8], inputLength: Int) -> [UInt8] {
        let header = bigEndian(UInt32(cdb.count)) + bigEndian(UInt32(inputLength)) + bigEndian(UInt32(output.count)) + bigEndian(UInt32(0))
        return clientFrame(command: 1, mac: mac, body: header + cdb + [UInt8](repeating: 0, count: 16 - cdb.count) + output)
    }

    static let openSessionCDB: [UInt8] = [0xd5, 0, 0, 0, 8, 8]
    static let startJobCDB: [UInt8] = [0xd8, 0, 0, 0, 0, 0]
    static let setWindowCDB: [UInt8] = [0xe9, 0, 0, 0, 0, 0, 0, 0x20, 0, 0]
    static let setParametersCDB: [UInt8] = [0xd4, 0, 0, 0, 0x50, 0]
    static let feedCDB: [UInt8] = [0xe0, 0, 0, 0, 0, 0]
    static let releaseCDB: [UInt8] = [0xd6, 0, 0, 0, 0, 0]
    static let requestSenseCDB: [UInt8] = [0x03, 0, 0, 0, 0x12, 0]
    static let inquiryCDB: [UInt8] = [0x12, 0, 0, 0, 0x60, 0]
    /// Whether the feeder holds paper, from a hardware status reply.
    static func hopperHasPaper(_ status: [UInt8]) -> Bool? { status.count > 3 ? status[3] & 0x80 == 0 : nil }

    static let hardwareStatusCDB: [UInt8] = [0xc2, 0, 0, 0, 0, 0, 0, 0, 0x20, 0]

    static func readImageCDB(back: Bool, imageIndex: Int) -> [UInt8] {
        [0x28, 0, 0, 2, 0, back ? 0x80 : 0, UInt8(readLength >> 16 & 0xff), UInt8(readLength >> 8 & 0xff), UInt8(readLength & 0xff), 0, UInt8(imageIndex & 0xff), 0]
    }

    static func imageInfoCDB(imageIndex: Int) -> [UInt8] {
        [0x28, 0, 0x80, 0, 0, 0x80, 0, 0, 0x20, 0, UInt8(imageIndex & 0xff), 0]
    }

    /// `E9` data: resolution and automatic page size.
    static func windowBlock(dpi: Int) -> [UInt8] {
        var block = bigEndian(UInt16(dpi)) + bigEndian(UInt16(dpi)) + bigEndian(autoPageWidth) + bigEndian(autoPageHeight) + [0x05]
        block += [UInt8](repeating: 0, count: 32 - block.count)
        return block
    }

    /// `D4` data: 32 bytes of scan parameters, then a 48-byte window descriptor.
    static func parameterBlock(dpi: Int, ultrasonicDoubleFeedDetection: Bool) -> [UInt8] {
        var parameters = [UInt8](repeating: 0, count: 32)
        parameters[1] = 3
        parameters[2] = 1 // automatic page size
        parameters[3] = 1
        parameters[4] = ultrasonicDoubleFeedDetection ? 0xd0 : 0x00
        parameters[6] = 0xc1
        parameters.replaceSubrange(7...9, with: [0x80, 0x80, 0x80])
        parameters[10] = dpi == 300 ? 0x90 : 0x80
        parameters.replaceSubrange(11...12, with: [0x80, 0x80])
        parameters[13] = dpi == 600 ? 0x80 : 0x00
        parameters[31] = 0x30
        let quality: UInt8 = dpi == 300 ? 0 : (dpi == 600 ? 0x0a : 5)
        var descriptor: [UInt8] = [0x00, 0x10] + bigEndian(UInt16(dpi)) + bigEndian(UInt16(dpi)) + [5, 0x81, quality, 0]
        descriptor += bigEndian(autoPageWidth) + bigEndian(autoPageHeight) + [0x04]
        descriptor += [UInt8](repeating: 0, count: 48 - descriptor.count)
        return parameters + descriptor
    }
}

nonisolated struct VENSNotification: Equatable, Sendable {
    let event: UInt32
    let counter: UInt8
}

nonisolated struct VENSScannerInfo: Equatable, Sendable {
    let ipAddress: [UInt8]
    let interfaceVersion: UInt16
    let name: String
    let model: String
    let serialNumber: String
    let registeredHostIP: [UInt8]
    let registeredHostID: [UInt8]

    var isIX500: Bool { model.hasPrefix("ScanSnap iX500") }
}

nonisolated struct VENSSense: Equatable, Sendable {
    let key: UInt8
    let additionalCode: UInt8
    let additionalQualifier: UInt8
    let endOfMedium: Bool

    init?(_ data: [UInt8]) {
        guard data.count >= 14 else { return nil }
        key = data[2] & 0x0f
        endOfMedium = data[2] & 0x40 != 0
        additionalCode = data[12]
        additionalQualifier = data[13]
    }

    var isFeederEmpty: Bool { key == 3 && additionalCode == 0x80 && additionalQualifier == 3 }

    var description: String { String(format: "sense %02x/%02x/%02x", key, additionalCode, additionalQualifier) }

    /// A paper problem the user can act on, or nil for any other sense.
    var paperError: VENSError? {
        guard key == 3, additionalCode == 0x80 else { return nil }
        switch additionalQualifier {
        case 1: return .paper(String(localized: "Paper jam. Remove the stuck sheet, then scan again."))
        case 2: return .paper(String(localized: "The scanner's cover is open."))
        case 7: return .paper(String(localized: "Double feed detected: several sheets went through together. Pages already scanned are kept. Remove the sheets, then scan again."))
        default: return .paper(String(localized: "Scanner feed error (\(description))."))
        }
    }
}

nonisolated enum VENSError: LocalizedError, Equatable {
    case scannerNotReachable
    case registrationRejected(Int32)
    case notPaired
    case noRouteToScanner
    case protocolViolation(String)
    case connectionLost(String)
    case commandFailed(String)
    case paper(String)

    var errorDescription: String? {
        switch self {
        case .scannerNotReachable:
            String(localized: "The scanner is not responding over Wi-Fi. Make sure it is on (cover open) and on the same network.")
        case .noRouteToScanner:
            String(localized: "This Mac has no network route to the scanner.")
        case .notPaired:
            String(localized: "The scanner has no registered computer, and Scan cannot register this Mac yet.")
        case let .registrationRejected(status):
            switch status {
            case -2, -3: String(localized: "The scanner refused its Wi-Fi password (code \(status)). Scan uses the factory password, the last 4 characters of the serial number.")
            case -4: String(localized: "The scanner is in use by other software (code -4). Quit ScanSnap Manager and ScanSnap Home, then turn the scanner off and on.")
            case -7: String(localized: "The scanner refused this Mac (code -7): it is not in its list of registered computers.")
            default: String(localized: "The scanner refused the connection (code \(status)).")
            }
        case let .connectionLost(detail):
            String(localized: "The connection to the scanner was lost (\(detail)).")
        case let .protocolViolation(message), let .commandFailed(message), let .paper(message):
            message
        }
    }
}
