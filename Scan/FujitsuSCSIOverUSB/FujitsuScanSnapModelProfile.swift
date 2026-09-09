import Foundation

/// Per-model behaviour of the shared Fujitsu SCSI-over-USB command engine.
///
/// The command flow (inquiry, mode selects, set window, object position,
/// interleaved duplex reads, sense handling) is identical across ScanSnap
/// generations. The models differ in a handful of quirks that SANE's
/// `fujitsu` backend documents in `init_model()`. Each quirk is an explicit
/// flag here so that the validated S1500 path is not changed by accident when
/// another model is added.
struct FujitsuScanSnapModelProfile: Sendable {
    let name: String
    let usbDeviceIDs: Set<USBDeviceID>
    let capabilities: ScannerCapabilities

    /// Send `SEND DIAGNOSTIC "SET PRE READMODE"` with the resolution, paper size
    /// and composition before the mode selects. Required for the iX500 to accept
    /// resolutions above 300 dpi.
    let sendsDiagnosticPreread: Bool

    /// Send a JPEG quantisation table after `SET WINDOW`, even though image data
    /// is transferred uncompressed. The iX500 refuses to scan without it.
    let sendsJPEGQuantizationTable: Bool

    /// Read `GET HW STATUS` and refuse to start a batch when the hopper is empty.
    /// The iX500 errors if `OBJECT POSITION` is issued without paper.
    let checksHopperBeforeFirstFeed: Bool

    /// Poll `TEST UNIT READY` after `OBJECT POSITION` before issuing `SCAN`.
    let waitsForReadyAfterFeed: Bool

    /// The scanner only produces colour data. Grayscale and line-art output are
    /// derived in software from the colour samples.
    let emulatesMonochromeInSoftware: Bool

    /// The number of pixels per line is rounded down to a multiple of this value
    /// before the window is sent.
    let pixelsPerLineModulus: Int

    /// Probe RGB dot, BGR dot and RRGGBB line interlacing with `SET WINDOW`
    /// until the scanner accepts one, and de-interlace accordingly. Models that
    /// do not probe always use RGB dot order.
    let probesColorInterlace: Bool

    /// Treat failures of the dropout and buffering mode selects as warnings
    /// instead of aborting the scan.
    let toleratesModeSelectFailures: Bool

    /// Upper bound for one `READ` of image data. The engine rounds it down to a
    /// whole number of scan lines. Larger values mean fewer SCSI round trips.
    let transferChunkSize: Int

    /// Input width of the downloadable gamma table (SANE `adbits`): the table
    /// has `1 << lookupTableInputBits` entries mapping onto 8-bit output.
    let lookupTableInputBits: Int

    /// Fujitsu ScanSnap S1500 / S1500M. The validated reference model.
    static let s1500 = FujitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S1500/S1500M",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x11a2)],
        capabilities: ScannerCapabilities(
            sources: [.adfFront, .adfBack, .adfDuplex],
            colorModes: [.color, .gray, .lineart],
            resolutionsDPI: [150, 200, 300, 400, 600],
            supportsBlankPageRemoval: true,
            supportsDeskew: true,
            supportsAutoCrop: true,
            supportsDuplex: true
        ),
        sendsDiagnosticPreread: false,
        sendsJPEGQuantizationTable: false,
        checksHopperBeforeFirstFeed: false,
        waitsForReadyAfterFeed: true,
        emulatesMonochromeInSoftware: false,
        pixelsPerLineModulus: 1,
        probesColorInterlace: false,
        toleratesModeSelectFailures: false,
        // The S1500's USB image endpoint terminates data phases after 32 KiB.
        transferChunkSize: 32 * 1024,
        // 1024-entry table (10-bit A/D), the validated S1500 payload.
        lookupTableInputBits: 10
    )

    /// ScanSnap S500 / S500M: same SCSI-over-USB command flow as the S1500,
    /// no 400 dpi step. Protocol-backed profile, not yet validated on hardware.
    static let s500 = FujitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S500/S500M",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x10fe), USBDeviceID(vendorID: 0x04c5, productID: 0x1135)],
        capabilities: Self.legacyCapabilities(resolutionsDPI: [150, 200, 300, 600]),
        sendsDiagnosticPreread: false,
        sendsJPEGQuantizationTable: false,
        checksHopperBeforeFirstFeed: false,
        waitsForReadyAfterFeed: true,
        emulatesMonochromeInSoftware: false,
        pixelsPerLineModulus: 1,
        probesColorInterlace: false,
        toleratesModeSelectFailures: false,
        transferChunkSize: 32 * 1024,
        lookupTableInputBits: 10
    )

    /// ScanSnap S510 / S510M: same SCSI-over-USB command flow as the S1500,
    /// no 400 dpi step. Protocol-backed profile, not yet validated on hardware.
    static let s510 = FujitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap S510/S510M",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x1155), USBDeviceID(vendorID: 0x04c5, productID: 0x116f)],
        capabilities: Self.legacyCapabilities(resolutionsDPI: [150, 200, 300, 600]),
        sendsDiagnosticPreread: false,
        sendsJPEGQuantizationTable: false,
        checksHopperBeforeFirstFeed: false,
        waitsForReadyAfterFeed: true,
        emulatesMonochromeInSoftware: false,
        pixelsPerLineModulus: 1,
        probesColorInterlace: false,
        toleratesModeSelectFailures: false,
        transferChunkSize: 32 * 1024,
        lookupTableInputBits: 10
    )

    private static func legacyCapabilities(resolutionsDPI: [Int]) -> ScannerCapabilities {
        ScannerCapabilities(
            sources: [.adfFront, .adfBack, .adfDuplex],
            colorModes: [.color, .gray, .lineart],
            resolutionsDPI: resolutionsDPI,
            supportsBlankPageRemoval: true,
            supportsDeskew: true,
            supportsAutoCrop: true,
            supportsDuplex: true
        )
    }

    /// Fujitsu ScanSnap iX500. Quirks follow SANE `fujitsu.c` `init_model()`:
    /// `need_q_table`, `need_diag_preread`, `ppl_mod_by_mode[COLOR] = 2`,
    /// `hopper_before_op`, `no_wait_after_op`, and software-emulated
    /// grayscale/line-art (`can_mode[...] = 2`).
    static let ix500 = FujitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap iX500",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x132b)],
        capabilities: ScannerCapabilities(
            sources: [.adfFront, .adfBack, .adfDuplex],
            colorModes: [.color, .gray, .lineart],
            // 150/300/600 validated on hardware; 400 dpi is not advertised.
            resolutionsDPI: [150, 200, 300, 600],
            supportsBlankPageRemoval: true,
            supportsDeskew: true,
            supportsAutoCrop: true,
            supportsDuplex: true,
            supportsScannerBuffering: true,
            supportsHardwareCompression: true
        ),
        sendsDiagnosticPreread: true,
        sendsJPEGQuantizationTable: true,
        checksHopperBeforeFirstFeed: true,
        waitsForReadyAfterFeed: false,
        emulatesMonochromeInSoftware: true,
        pixelsPerLineModulus: 2,
        probesColorInterlace: true,
        toleratesModeSelectFailures: true,
        // Validated on hardware: 256 KiB reads cut the per-sheet command count
        // from ~1,800 to ~210 for a duplex A4 sheet at 300 dpi.
        transferChunkSize: 256 * 1024,
        // SANE forces adbits = 8 for the iX500 ("lies"), i.e. a 256-entry table.
        lookupTableInputBits: 8
    )
}
