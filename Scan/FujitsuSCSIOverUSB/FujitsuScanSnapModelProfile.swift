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

    /// The number of pixels per line in colour and grayscale windows is rounded
    /// down to a multiple of this value before the window is sent.
    let pixelsPerLineModulus: Int

    /// The same rounding for native line-art windows. SANE's default
    /// `ppl_mod_by_mode[LINEART]` is 8 (whole bytes per line); the S1500 was
    /// validated with unrounded line-art widths.
    let lineartPixelsPerLineModulus: Int

    /// Probe RGB dot, BGR dot and RRGGBB line interlacing with `SET WINDOW`
    /// until the scanner accepts one, and de-interlace accordingly. Models that
    /// do not probe always use RGB dot order.
    let probesColorInterlace: Bool

    /// Treat failures of the dropout and buffering mode selects as warnings
    /// instead of aborting the scan.
    let toleratesModeSelectFailures: Bool

    /// Log and continue when the scanner rejects the downloadable gamma table;
    /// it then applies its built-in curve. SANE sizes the table from the A/D
    /// width in the VPD page, which the engine does not read, so profiles whose
    /// `lookupTableInputBits` is inferred rather than validated set this.
    let toleratesGammaTableFailure: Bool

    /// End batches and errors the way SANE's `check_for_cancel()` does: a
    /// batch that has fed at least one sheet is closed with `SCANNER CONTROL`
    /// cancel once the feeder runs empty, an error after the first feed sends
    /// only that cancel (no `OBJECT POSITION` halt), and nothing is sent when
    /// the batch never started. The S1500 and iX500 keep their validated
    /// sequence instead: no command after the empty feeder, halt then cancel
    /// on errors.
    let usesSANECancelFlow: Bool

    /// Select the scanner's built-in gamma curve (window byte 0x29 = 0) and
    /// skip the downloadable table, as SANE's `set_window()` does since v139
    /// when the scanner has an internal table and brightness/contrast are at
    /// their defaults ("fixes bright/contrast for iX1500"). With the
    /// downloaded linear table paper comes back around 245 of 255.
    let usesInternalGammaTable: Bool

    /// Upper bound for one `READ` of image data. The engine rounds it down to a
    /// whole number of scan lines. Larger values mean fewer SCSI round trips.
    let transferChunkSize: Int

    /// Input width of the downloadable gamma table (SANE `adbits`): the table
    /// has `1 << lookupTableInputBits` entries mapping onto 8-bit output.
    let lookupTableInputBits: Int

    func pixelsPerLineModulus(for mode: ScanColorMode) -> Int {
        mode == .lineart ? lineartPixelsPerLineModulus : pixelsPerLineModulus
    }

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
        lineartPixelsPerLineModulus: 1,
        probesColorInterlace: false,
        toleratesModeSelectFailures: false,
        toleratesGammaTableFailure: false,
        usesSANECancelFlow: false,
        usesInternalGammaTable: false,
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
        lineartPixelsPerLineModulus: 1,
        probesColorInterlace: false,
        toleratesModeSelectFailures: false,
        toleratesGammaTableFailure: false,
        usesSANECancelFlow: false,
        usesInternalGammaTable: false,
        transferChunkSize: 32 * 1024,
        lookupTableInputBits: 10
    )

    /// ScanSnap S510 / S510M: same SCSI-over-USB command flow as the S1500,
    /// no 400 dpi step. Validated on S510M hardware (USB product 0x116f).
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
        lineartPixelsPerLineModulus: 1,
        // S510-family firmware does not consistently accept the S1500's RGB
        // dot order. Probe the Fujitsu layouts and retain the accepted one.
        probesColorInterlace: true,
        // The S510M rejects the optional scan-buffer mode page (0x3a) with
        // ILLEGAL REQUEST / INVALID FIELD IN PARAMETER LIST. SANE likewise
        // treats unsupported optional mode pages as warnings and continues.
        toleratesModeSelectFailures: true,
        toleratesGammaTableFailure: false,
        usesSANECancelFlow: false,
        usesInternalGammaTable: false,
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

    /// Fujitsu ScanSnap iX500 (USB 0x132b) and iX500EE (0x13f3). Quirks
    /// follow SANE `fujitsu.c` `init_model()`: `need_q_table`,
    /// `need_diag_preread`, `ppl_mod_by_mode[COLOR] = 2`, `hopper_before_op`,
    /// `no_wait_after_op`, and software-emulated grayscale/line-art
    /// (`can_mode[...] = 2`). SANE applies the same rules to the iX500EE
    /// because it matches the model name "iX500"; only the iX500 has been
    /// validated on hardware.
    static let ix500 = FujitsuScanSnapModelProfile(
        name: "Fujitsu ScanSnap iX500/iX500EE",
        usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: 0x132b), USBDeviceID(vendorID: 0x04c5, productID: 0x13f3)],
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
        // Never used: the iX500 is always asked for colour.
        lineartPixelsPerLineModulus: 2,
        probesColorInterlace: true,
        toleratesModeSelectFailures: true,
        toleratesGammaTableFailure: false,
        usesSANECancelFlow: false,
        usesInternalGammaTable: false,
        // Validated on hardware: 256 KiB reads cut the per-sheet command count
        // from ~1,800 to ~210 for a duplex A4 sheet at 300 dpi.
        transferChunkSize: 256 * 1024,
        // SANE forces adbits = 8 for the iX500 ("lies"), i.e. a 256-entry table.
        lookupTableInputBits: 8
    )

    /// Fujitsu ScanSnap iX1600 (USB 0x04c5/0x1632). SANE's `fujitsu` backend
    /// drives it with the generic Fujitsu command flow and no `init_model()`
    /// overrides, and its VPD page (firmware 0V00) confirms the profile:
    /// 10-bit A/D, native line-art/gray/colour, 50-600 dpi with 400 dpi
    /// listed as standard, GET HW STATUS, baseline JPEG, an internal gamma
    /// table, 576 MB of buffer memory.
    ///
    /// Validated on hardware (see the architecture notes): duplex colour
    /// batches with automatic length detection, native gray and line-art,
    /// hardware JPEG, scanner buffering, 256 KiB reads, the hopper check, the
    /// empty-feeder path and SANE's batch-closing cancel.
    static let ix1600 = ix1x00(name: "Fujitsu ScanSnap iX1600", productID: 0x1632)

    /// Fujitsu ScanSnap iX1500 (USB 0x04c5/0x159f). Same generation, paper
    /// path and Fujitsu dialect as the iX1600 (SANE treats both with the
    /// generic flow), so it inherits the iX1600 profile. Not yet exercised on
    /// iX1500 hardware with this profile.
    static let ix1500 = ix1x00(name: "Fujitsu ScanSnap iX1500", productID: 0x159f)

    /// Fujitsu ScanSnap iX1300 (USB 0x04c5/0x162c). SANE lists it as working
    /// with the generic flow and no `init_model()` overrides, like the iX1600.
    /// Only its U-turn ADF is driven; the straight return path (SANE
    /// `SC_function_rpath`) is not modelled. Not yet exercised on hardware.
    static let ix1300 = ix1x00(name: "Fujitsu ScanSnap iX1300", productID: 0x162c)

    /// Fujitsu ScanSnap iX1400 (USB 0x04c5/0x1630): the iX1600 without
    /// touchscreen and Wi-Fi. SANE lists it as untested with the generic
    /// flow. Not yet exercised on hardware.
    static let ix1400 = ix1x00(name: "Fujitsu ScanSnap iX1400", productID: 0x1630)

    /// The iX1300/iX1400/iX1500/iX1600 profile: SANE's generic flow (no iX500-style pre-read
    /// or quantisation table, TEST UNIT READY after the feed, unrounded colour
    /// widths, whole-byte line-art widths, best-effort optional mode pages and
    /// gamma table, probed colour interlacing), the scanner's internal gamma
    /// curve, SANE's cancel flow, the hopper check, 256 KiB reads, and the
    /// opt-in buffering and hardware-JPEG capabilities.
    private static func ix1x00(name: String, productID: UInt16) -> FujitsuScanSnapModelProfile {
        FujitsuScanSnapModelProfile(
            name: name,
            usbDeviceIDs: [USBDeviceID(vendorID: 0x04c5, productID: productID)],
            capabilities: ScannerCapabilities(
                sources: [.adfFront, .adfBack, .adfDuplex],
                colorModes: [.color, .gray, .lineart],
                resolutionsDPI: [150, 200, 300, 400, 600],
                supportsBlankPageRemoval: true,
                supportsDeskew: true,
                supportsAutoCrop: true,
                supportsDuplex: true,
                supportsScannerBuffering: true,
                supportsHardwareCompression: true
            ),
            sendsDiagnosticPreread: false,
            sendsJPEGQuantizationTable: false,
            checksHopperBeforeFirstFeed: true,
            waitsForReadyAfterFeed: true,
            // The VPD advertises native gray and line-art; both were validated
            // on the iX1600 (correct polarity, whole-byte line-art rows).
            emulatesMonochromeInSoftware: false,
            pixelsPerLineModulus: 1,
            lineartPixelsPerLineModulus: 8,
            probesColorInterlace: true,
            toleratesModeSelectFailures: true,
            toleratesGammaTableFailure: true,
            // The iX1600's display showed "unexpected error" and its firmware
            // stopped answering after a batch that ended without SANE's
            // closing cancel, so this generation follows check_for_cancel().
            usesSANECancelFlow: true,
            // SANE v139 behaviour for scanners with an internal table and no
            // brightness/contrast steps. On the iX1600 the internal curve lifts
            // the mid-tones by ~50 levels compared with the linear download.
            usesInternalGammaTable: true,
            // Validated on the iX1600: 260,100-byte reads (34 colour lines at
            // 300 dpi), no short data phases.
            transferChunkSize: 256 * 1024,
            lookupTableInputBits: 10
        )
    }

    // MARK: - Protocol-backed models without current macOS support

    /// ScanSnap fi-5110EOX, fi-5110EOX2, fi-5110EOX3 and fi-5110EOXM, the
    /// ScanSnap generation before the S500. SANE drives them with the generic
    /// flow plus `cropping_mode = CROP_ABSOLUTE`, which concerns the placement
    /// of a cropped window. The engine always requests the full sheet from the
    /// origin, so that quirk is not modelled; revisit it if hardware shows an
    /// offset image. Not yet validated on hardware.
    static let fi5110EOX = protocolBacked(
        name: "Fujitsu ScanSnap fi-5110EOX/EOX2/EOX3/EOXM",
        productIDs: [0x1096, 0x10e6, 0x10f2],
        resolutionsDPI: [150, 200, 300, 600],
        lookupTableInputBits: 10
    )

    /// fi-5110C, fi-5120C and fi-5220C. SANE has no model quirks for them that
    /// affect this flow. ADF only: the engine never selects the fi-5220C
    /// flatbed. Not yet validated on hardware.
    static let fi5000 = protocolBacked(
        name: "Fujitsu fi-5110C/fi-5120C/fi-5220C",
        productIDs: [0x1097, 0x10e0, 0x10e1],
        resolutionsDPI: [150, 200, 300, 400, 600],
        lookupTableInputBits: 10
    )

    /// fi-5530C and fi-5530C2. SANE forces `adbits = 8` for the USB fi-5530,
    /// i.e. a 256-entry gamma table. Not yet validated on hardware.
    static let fi5530C = protocolBacked(
        name: "Fujitsu fi-5530C/fi-5530C2",
        productIDs: [0x10e2, 0x114a],
        resolutionsDPI: [150, 200, 300, 400, 600],
        lookupTableInputBits: 8
    )

    /// fi-6110, fi-6130/fi-6130Z, fi-6140/fi-6140Z and the ADF of the
    /// fi-6230/fi-6230Z and fi-6240/fi-6240Z (the flatbed is never selected).
    /// SANE treats them like the S1500: its fi-6000 quirks only cap the page
    /// length at high resolutions and, for the fi-6110 as for the S1500, drop
    /// the background and pre-pick mode pages, which the engine never sends.
    /// Not yet validated on hardware.
    static let fi6000 = protocolBacked(
        name: "Fujitsu fi-6000 series",
        productIDs: [0x11fc, 0x114f, 0x11f3, 0x114d, 0x11f1, 0x1150, 0x11f4, 0x114e, 0x11f2],
        resolutionsDPI: [150, 200, 300, 400, 600],
        lookupTableInputBits: 10
    )

    /// Defaults for models ported from SANE's generic `fujitsu` flow that have
    /// not been validated on hardware: the S1500 command sequence, with the
    /// optional mode selects and the gamma table made best effort, colour
    /// interlacing probed, and SANE's default line-art rounding.
    private static func protocolBacked(
        name: String,
        productIDs: [UInt16],
        resolutionsDPI: [Int],
        lookupTableInputBits: Int,
        emulatesMonochromeInSoftware: Bool = false
    ) -> FujitsuScanSnapModelProfile {
        FujitsuScanSnapModelProfile(
            name: name,
            usbDeviceIDs: Set(productIDs.map { USBDeviceID(vendorID: 0x04c5, productID: $0) }),
            capabilities: legacyCapabilities(resolutionsDPI: resolutionsDPI),
            sendsDiagnosticPreread: false,
            sendsJPEGQuantizationTable: false,
            checksHopperBeforeFirstFeed: false,
            waitsForReadyAfterFeed: true,
            emulatesMonochromeInSoftware: emulatesMonochromeInSoftware,
            pixelsPerLineModulus: 1,
            lineartPixelsPerLineModulus: 8,
            probesColorInterlace: true,
            toleratesModeSelectFailures: true,
            toleratesGammaTableFailure: true,
            usesSANECancelFlow: false,
            usesInternalGammaTable: false,
            transferChunkSize: 32 * 1024,
            lookupTableInputBits: lookupTableInputBits
        )
    }
}
