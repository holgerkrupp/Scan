import Foundation

/// Fujitsu vital product data: `INQUIRY` with EVPD page 0xf0, parsed with the
/// byte offsets from SANE's `fujitsu-scsi.h` (`get_IN_*`) and `init_vpd()`.
///
/// The command engine does not drive its behaviour from this page (the
/// per-model profiles are explicit), but the hardware harness dumps it so a
/// new model's capabilities (A/D width, resolutions, JPEG, buffer memory,
/// supported commands) can be checked against its profile.
struct FujitsuVitalProductData: Sendable, Equatable {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Byte 4: length of the payload after it. SANE notes it is often bogus;
    /// every known scanner delivers at least 0x5f.
    var payloadLength: Int { byte(0x04) }

    var basicXResolutionDPI: Int { number(0x05, 2) }
    var basicYResolutionDPI: Int { number(0x07, 2) }
    var maxXResolutionDPI: Int { number(0x0a, 2) }
    var maxYResolutionDPI: Int { number(0x0c, 2) }
    var minXResolutionDPI: Int { number(0x0e, 2) }
    var minYResolutionDPI: Int { number(0x10, 2) }

    /// Resolutions the scanner lists as standard (bytes 0x12-0x13).
    var standardResolutionsDPI: [Int] {
        var list: [Int] = []
        if bit(0x12, 7) { list.append(60) }
        if bit(0x12, 6) { list.append(75) }
        if bit(0x12, 5) { list.append(100) }
        if bit(0x12, 4) { list.append(120) }
        if bit(0x12, 3) { list.append(150) }
        if bit(0x12, 2) { list.append(160) }
        if bit(0x12, 1) { list.append(180) }
        if bit(0x12, 0) { list.append(200) }
        if bit(0x13, 7) { list.append(240) }
        if bit(0x13, 6) { list.append(300) }
        if bit(0x13, 5) { list.append(320) }
        if bit(0x13, 4) { list.append(400) }
        if bit(0x13, 3) { list.append(480) }
        if bit(0x13, 2) { list.append(600) }
        if bit(0x13, 1) { list.append(800) }
        if bit(0x13, 0) { list.append(1200) }
        return list
    }

    /// Maximum window in basic-resolution units.
    var maxWindowWidth: Int { number(0x14, 4) }
    var maxWindowLength: Int { number(0x18, 4) }
    var maxWidthInches: Double { basicXResolutionDPI > 0 ? Double(maxWindowWidth) / Double(basicXResolutionDPI) : 0 }
    var maxLengthInches: Double { basicYResolutionDPI > 0 ? Double(maxWindowLength) / Double(basicYResolutionDPI) : 0 }

    var supportsLineart: Bool { bit(0x1c, 1) }
    var supportsGray: Bool { bit(0x1c, 3) }
    var supportsColor: Bool { bit(0x1c, 7) }

    var hasADF: Bool { bit(0x20, 7) }
    var hasFlatbed: Bool { bit(0x20, 6) }
    var hasDuplex: Bool { bit(0x20, 4) }

    /// SANE `adbits`: the width of the downloadable gamma table's input.
    var adBits: Int { byte(0x21) & 0x0f }
    var bufferBytes: Int { number(0x22, 4) }

    var hasSendDiagnosticCommand: Bool { bit(0x28, 2) }
    var hasReadDiagnosticCommand: Bool { bit(0x28, 1) }
    var hasHardwareStatusCommand: Bool { bit(0x2b, 2) }
    var hasScannerControlCommand: Bool { bit(0x31, 1) }

    var brightnessSteps: Int { byte(0x52) }
    var thresholdSteps: Int { byte(0x53) }
    var contrastSteps: Int { byte(0x54) }
    var internalGammaTables: Int { byte(0x57) >> 4 }
    var downloadableGammaTables: Int { byte(0x57) & 0x0f }

    var supportsBaselineJPEG: Bool { bit(0x5a, 3) }
    /// SANE `IN_comp_JPG_gray_*`: 1 unsupported, 2 gray as colour, 3 native gray.
    var jpegGrayMode: Int { (byte(0x5b) >> 6) & 0x03 }
    var supportsHybridCropDeskew: Bool { bit(0x59, 3) }
    var supportsAutoColor: Bool { bit(0x69, 7) }
    var supportsBlankSkip: Bool { bit(0x69, 6) }
    var supportsSkewCheck: Bool { bit(0x6d, 7) }

    var summary: String {
        """
        VPD \(bytes.count) bytes, payload length 0x\(String(payloadLength, radix: 16)); \
        basic \(basicXResolutionDPI)x\(basicYResolutionDPI) dpi, range \(minXResolutionDPI)-\(maxXResolutionDPI) x \(minYResolutionDPI)-\(maxYResolutionDPI) dpi, \
        standard \(standardResolutionsDPI); \
        window \(String(format: "%.2f", maxWidthInches)) x \(String(format: "%.2f", maxLengthInches)) in; \
        modes lineart \(supportsLineart) gray \(supportsGray) color \(supportsColor); \
        adf \(hasADF) flatbed \(hasFlatbed) duplex \(hasDuplex); \
        A/D bits \(adBits), buffer \(bufferBytes) bytes; \
        commands send-diag \(hasSendDiagnosticCommand) read-diag \(hasReadDiagnosticCommand) hw-status \(hasHardwareStatusCommand) scanner-control \(hasScannerControlCommand); \
        brightness \(brightnessSteps) contrast \(contrastSteps) threshold \(thresholdSteps) steps; \
        gamma internal \(internalGammaTables) download \(downloadableGammaTables); \
        JPEG baseline \(supportsBaselineJPEG) gray mode \(jpegGrayMode); \
        crop/deskew \(supportsHybridCropDeskew) auto-color \(supportsAutoColor) blank-skip \(supportsBlankSkip) skew-check \(supportsSkewCheck)
        """
    }

    var hexDump: String {
        stride(from: 0, to: bytes.count, by: 16).map { row in
            let slice = bytes[row..<min(row + 16, bytes.count)]
            return String(format: "%04x  ", row) + slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func byte(_ offset: Int) -> Int {
        offset < bytes.count ? Int(bytes[offset]) : 0
    }

    private func bit(_ offset: Int, _ bit: Int) -> Bool {
        (byte(offset) >> bit) & 1 == 1
    }

    private func number(_ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { ($0 << 8) | byte(offset + $1) }
    }
}
