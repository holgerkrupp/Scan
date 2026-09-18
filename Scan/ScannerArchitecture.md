# Scanner workspace architecture

The app separates scanner acquisition from image processing and export:

`ScannerDiscovery` -> `ScannerDriver`/`ScannerDevice` -> `PageFrame` stream -> file-backed `ScanPageStore` (raw pages) -> `ScanImageProcessor` (in the workspace, as pages arrive and whenever the processing options change) -> processed pages in the grid -> `ScanOutputWriter` (output resolution and compression only).

The review session is dynamic: `ScannerWorkspaceViewModel` keeps `rawPages` (the scans as delivered, written as `Raw N side.jpg`), renders each into `processedPages` (`Page N side.jpg`) with the profile's `ImageProcessingSettings` plus the page's `PageEdits` (quarter turns from Rotate, an alignment flag from Auto-Align), and hides pages that `ScanImageProcessor.process` reports blank in `blankPageIDs`. `pages`, what the grid shows and the export writes, is derived from those. Processing runs one page at a time on a utility-priority detached task chained behind the previous one (`processingChain`); a `processingGeneration` counter discards results that were computed for outdated settings or removed pages. `updateProfile`/`selectProfile` compare the processing settings and schedule a debounced (250 ms) re-render of every raw page; `ingest` stores a frame and queues it; `waitForProcessing` is awaited before the automatic and manual export. `ScanOutputWriter.write(pages:)` therefore applies empty processing settings and only scales to the output DPI and compresses, so the export matches the grid.

## Settings and profiles

`ScanOptions` contains `AcquisitionSettings`, `ImageProcessingSettings`, and `ExportSettings`. `ScanProfileStore` persists JSON profiles and the selected profile in `UserDefaults`. Destination folders are persisted as security-scoped bookmarks.

The size presets are deliberately explicit:

| Preset | Output DPI | Color | Compression |
| --- | ---: | --- | --- |
| Small | 150 | Gray | JPEG-style quality 0.70 |
| Balanced | 200 | Gray | JPEG-style quality 0.82 |
| High Quality | 300 | Color | JPEG-style quality 0.92 |
| Lossless | 600 | Color | Lossless TIFF/PNG path |
| Custom | User-selected | User-selected | User-selected |

Acquisition DPI is sent to the scanner. Output DPI/downsampling and compression happen in the reusable output pipeline. Capabilities are validated before acquisition and unsupported controls are disabled with an explanation in the inspector.

## Native Fujitsu SCSI-over-USB backend (ScanSnap fi-5110EOX, S500, S510, S1500, iX500, iX1300, iX1400, iX1500, iX1600; fi-5000, fi-6000)

`FujitsuScanSnapDevice` and its private SCSI-over-USB command engine are shared by the Fujitsu SCSI-over-USB family. Each model contributes a `FujitsuScanSnapModelProfile` (USB IDs, capabilities, and explicit quirk flags); `FujitsuScanSnapS1500Driver` serves the fi-5110EOX family, S500/S500M, S510/S510M and S1500/S1500M profiles by USB product ID, dedicated thin drivers select the iX500, iX1300, iX1400, iX1500 and iX1600 profiles, and `FujitsuFiSeriesDriver` serves the fi-5000 and fi-6000 document scanners. The shared command flow remains the hardware path: inquiry, ADF setup, automatic document length, window setup, interleaved duplex reads, sense/status handling, and paper recovery.

| Driver | USB IDs | Profile |
| --- | --- | --- |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x1096`, `0x04c5/0x10e6`, `0x04c5/0x10f2` | `.fi5110EOX` (protocol-backed, fi-5110EOX/EOX2/EOX3/EOXM; not validated on hardware) |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x10fe`, `0x04c5/0x1135` | `.s500` (protocol-backed, S1500 flow without 400 dpi; not validated on hardware) |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x1155`, `0x04c5/0x116f` | `.s510` (validated on S510M hardware; S1500 flow without 400 dpi, tolerant optional mode pages, probed color interlace) |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x11a2` | `.s1500` (validated reference path) |
| `FujitsuScanSnapIX500Driver` | `0x04c5/0x132b`, `0x04c5/0x13f3` | `.ix500` (validated on iX500 hardware; the iX500EE product ID is unvalidated) |
| `FujitsuScanSnapIX1500Driver` | `0x04c5/0x159f` | `.ix1500` (inherits the iX1600 profile; not validated on iX1500 hardware) |
| `FujitsuScanSnapIX1600Driver` | `0x04c5/0x1632` | `.ix1600` (generic Fujitsu flow plus hopper check, internal gamma, SANE cancel flow; validated on hardware) |
| `FujitsuScanSnapIX1300Driver` | `0x04c5/0x162c` | `.ix1300` (inherits the iX1600 profile; U-turn ADF only; not validated on hardware) |
| `FujitsuScanSnapIX1400Driver` | `0x04c5/0x1630` | `.ix1400` (inherits the iX1600 profile; not validated on hardware) |
| `FujitsuFiSeriesDriver` | `0x04c5/0x1097`, `0x04c5/0x10e0`, `0x04c5/0x10e1` | `.fi5000` (protocol-backed, fi-5110C and fi-5x20C; not validated on hardware) |
| `FujitsuFiSeriesDriver` | `0x04c5/0x10e2`, `0x04c5/0x114a` | `.fi5530C` (protocol-backed, fi-5530C/C2, 256-entry gamma table; not validated on hardware) |
| `FujitsuFiSeriesDriver` | `0x04c5/0x11fc`, `0x04c5/0x114f`, `0x04c5/0x11f3`, `0x04c5/0x114d`, `0x04c5/0x11f1`, `0x04c5/0x1150`, `0x04c5/0x11f4`, `0x04c5/0x114e`, `0x04c5/0x11f2` | `.fi6000` (protocol-backed, fi-6110/6130/6130Z/6140/6140Z/6230/6230Z/6240/6240Z; not validated on hardware) |

No other Fujitsu product ID is claimed by these drivers. In particular the iX100, the SV600, the Ricoh-branded iX2400 (`0x05ca/0x03e3`, which the Fujitsu-only USB discovery would not even enumerate) and the fi-7000/fi-8000 generations are left alone, as are the ZLA variants that SANE lists as untested.

The fi-5110EOX, fi-5000 and fi-6000 profiles are built by `FujitsuScanSnapModelProfile.protocolBacked` from the S1500 flow and the model notes in SANE's `fujitsu.c`, where none of them needs the iX500-style pre-read, quantisation table or hopper check:

- Colour interlacing is probed like on the iX500. RGB dot order is tried first, so a scanner that accepts it sees exactly the S1500's `SET WINDOW`.
- Dropout and buffer mode selects are best effort, and so is the gamma table (`toleratesGammaTableFailure`): SANE sizes it from the A/D width in the VPD page, which the engine does not read, so a rejected table falls back to the scanner's built-in curve instead of aborting. The fi-5530C/C2 profile sends the 256-entry table because SANE forces `adbits = 8` for it; the others send the S1500's 1024-entry table.
- Native line-art widths are rounded down to whole bytes (SANE's default `ppl_mod_by_mode[LINEART] = 8`, `lineartPixelsPerLineModulus`); colour and gray widths are not rounded. The S1500, S500 and S510 keep their unrounded line-art window.
- Only the ADF is advertised. The flatbed of the fi-5220C, fi-6230 and fi-6240 is never selected.
- The fi-5110EOX quirk `cropping_mode = CROP_ABSOLUTE` concerns the placement of a cropped window; the engine always requests the full sheet from the origin, so it is not modelled.

The iX1600, iX1500, iX1400 and iX1300 share one profile (`FujitsuScanSnapModelProfile.ix1x00`; SANE's `fujitsu.desc` lists the iX1300 as working and the iX1400 as untested, both without `init_model()` overrides; the iX1300's straight return path, SANE's `SC_function_rpath`, is not modelled), built on the same generic flow because SANE's `fujitsu` backend has no `init_model()` overrides for either model, with three additions: `GET HW STATUS` is read before the first feed like on the iX500, the buffering and hardware-JPEG capabilities are advertised, and batches end the way SANE's `check_for_cancel()` ends them (`usesSANECancelFlow`): once a started batch runs out of paper the engine sends `SCANNER CONTROL` cancel, an error after the first feed sends only that cancel, and an empty feeder at the start sends nothing. The S1500 and iX500 keep their validated sequence (no command after the empty feeder, `OBJECT POSITION` halt then cancel on errors and on user cancellation); the flag exists because the iX1600's display showed "unexpected error" and its firmware stopped answering USB commands after a six-sheet batch that ended without the closing cancel, and a USB port reset did not recover it (a power cycle does). The profile asks for native gray and line-art (composition 2 and 0) instead of deriving them from colour, advertises 150/200/300/400/600 dpi, selects the scanner's internal gamma curve (`usesInternalGammaTable`: window byte 0x29 = 0 and no `SEND` of the table, SANE's `set_window()` behaviour since v139 for scanners with an internal table and no brightness/contrast steps), reads 256 KiB per `READ`, and routes product `0x1632` to `FujitsuScanSnapIX1600Driver` and `0x159f` to `FujitsuScanSnapIX1500Driver`. `FujitsuCommandTranscriptTests` pins the iX1600 sequences (`ix1600-*.transcript`, recorded after the hardware runs) and proves that the iX1300, iX1400 and iX1500 drivers emit identical command sequences, that the hopper check and the closing cancel are present, and that the iX500 pre-read, quantisation table, and gamma download are not.

iX1600 hardware findings (firmware 0V00, inquiry `FUJITSU ScanSnap iX1600`, macOS 27, libusb transport): the VPD page (`FujitsuScanSnapDevice.readVitalProductData()`, `INQUIRY` EVPD page 0xf0 parsed like SANE's `init_vpd()`) reports 600 dpi basic and 50–600 dpi range with 400 dpi listed as standard, an 8.71 in wide window and 118 in maximum length, native line-art/gray/colour, ADF with duplex and no flatbed, 10-bit A/D, 576 MB of buffer memory, `SEND/READ DIAGNOSTIC`, `GET HW STATUS` and `SCANNER CONTROL` support, one internal and one downloadable gamma table with brightness/contrast steps of 0, baseline JPEG, automatic colour detection and blank-page skipping. Validated with paper: a 6-sheet A4 duplex colour batch at 300 dpi with automatic length detection (3521–3526 rows per side, benign EOM/ILI sense at the end, 5.9 s per sheet with 32 KiB reads), single-sheet duplex colour with 256 KiB reads (260,100-byte reads, about 1 s for 9.8 MB per side, no short data phases), native gray and line-art (correct polarity, line-art at the whole-byte 2544-pixel width), hardware JPEG duplex (separate per-side streams like the iX500, 4:4:4 sampling, DRI = one MCU row, about 1.2 MB per side at Q5), scanner buffering, the hopper check with paper present and absent, and SANE's closing cancel. Without the hopper check `OBJECT POSITION` on an empty feeder returned the no-documents sense (0x03/0x80/0x03). The iX500-only pre-read and quantisation table were accepted when tried but are not needed. Gamma: the internal curve and the downloaded linear table both put paper white at 254–255, but the internal curve lifts mid-tones by roughly 50 levels (median 89 vs 38 on the same page), so the profile follows SANE and uses it. JPEG quirk: the iX1600 writes the requested window height (4200 rows) into SOF and ends the entropy data after the last real row (161 restart intervals of one MCU row each for a 1281-row sheet), so `FujitsuJPEGStreamSplitter` counts the restart intervals against DRI and the MCU geometry and rewrites the SOF height at EOI; a SOF height that already matches the data, as on the iX500, is left alone. Firmware lock-up: after the first six-sheet batch, which ended without a closing cancel, the display showed "unexpected error" and the scanner stopped answering bulk transfers; `libusb_reset_device` timed out as well and only a power cycle recovered it. Not yet exercised on the iX1600: jam/double-feed recovery, mid-transfer cancellation, disconnect, the back-only source, and 150/200 dpi image transfers.

The hardware harness can apply profile experiments on top of the registry profile through `SCAN_HW_*` variables (pre-read, quantisation table, hopper check, wait after feed, interlace probing, gamma tolerance, colour width modulus, read chunk, gamma table width, buffering/JPEG capabilities, native monochrome, advertised resolutions), so the flags of a new model can be tried without rebuilding.

`FujitsuCommandTranscriptTests` requires one model of each of the older protocol-backed profiles (except the fi-5530C, whose gamma payload differs) to reproduce the S1500 colour and gray fixtures byte for byte, and checks that a rejected gamma table is tolerated by them but still aborts an S1500 scan.

The iX500 profile follows the quirks documented in SANE's `fujitsu.c` `init_model()`:

- `SEND DIAGNOSTIC "SET PRE READMODE"` is sent before the mode selects (needed for resolutions above 300 dpi).
- A JPEG quantisation table is sent after `SET WINDOW` even though transfers are uncompressed.
- `GET HW STATUS` is read before the first `OBJECT POSITION`; an empty hopper ends the batch with `feederEmpty` instead of letting the scanner error.
- `OBJECT POSITION` is not followed by `TEST UNIT READY` polling.
- Pixels per line are rounded down to a multiple of 2 and the window width is derived from that.
- The scanner is always asked for colour; grayscale is the channel average and line-art a fixed 127 threshold, computed in `FujitsuScanSnapImageDecoder`.
- Colour interlacing (RGB dot, BGR dot, RRGGBB line) is probed with `SET WINDOW` on the first scan of a session and de-interlaced accordingly.
- Dropout and buffer mode selects are best effort.

All S1500 flags are set so that its command bytes are unchanged by the refactor. `FujitsuCommandTranscriptTests` proves it: `FujitsuScriptedTransport` emulates a ScanSnap on the wire (command wrapper, data-in/data-out phases, status packets, sense, synthetic pixel size and image data, a feeder with N sheets) and records every bulk write and read. The S1500 fixtures in `ScanTests/Fixtures` were recorded from the original driver at commit 7a27cf8 running against that transport for front/duplex/back, gray/colour/line-art, 150–300 dpi, two sheets, and an empty feeder; the test requires the shared engine to produce byte-identical transcripts. The iX500 fixtures pin the current, hardware-validated sequences. `FujitsuScanSnapDriverTests` additionally pins the S1500 window geometry, gamma table, and the decoder paths; `FujitsuJPEGStreamSplitterTests` covers the JPEG stream splitting and `FujitsuHardwareJPEGConversionTests` the colour pass-through and the gray/line-art conversion of scanner JPEGs.

iX500 hardware validation (firmware 0U00, macOS 27, libusb transport) covered: enumeration and open/close, inquiry, ADF front colour 300 dpi, ADF duplex gray 600 dpi (interleaved reads, 128 MB per side), ADF front line-art 150 dpi (scanner reports the even-rounded 1274-pixel width), a 14-sheet A4 duplex colour 300 dpi batch with auto-crop (automatic length detection returned 3527–3536 rows per side instead of the 4200-row window, every sheet ended with the benign EOM/ILI sense), the same batch with 256 KiB reads and pipelined encoding (3.1–3.6 s transfer per sheet, ~25 ms feed latency), a 4-sheet batch with scanner buffering on (2.1 s transfer per sheet from the second sheet on), two 14-sheet batches with hardware JPEG (sequential and interleaved side reads, 3.2 s per sheet, 28 valid JPEGs each), and the empty-feeder path through `GET HW STATUS`. The scanner accepted RGB dot interlacing on the first probe and rejected none of the preparatory commands. Not yet exercised on the iX500: jam/double-feed recovery, mid-transfer cancellation, disconnect, the back-only source, and 200/400 dpi.

S510M hardware validation (USB product `0x116f`, macOS 27, libusb transport) covered enumeration, inquiry, ADF duplex colour at 300 dpi, image-size reporting, interleaved front/back reads, and JPEG encoding. Its firmware rejects the optional scan-buffer mode page with `ILLEGAL REQUEST / INVALID FIELD IN PARAMETER LIST`, so the S510 profile treats optional mode-page failures as warnings. It also rejects RGB-dot window setup and accepts BGR-dot interlacing, selected by the existing first-scan probe.

`FujitsuScanSnapHardwareTests` is the opt-in harness for these runs. It is skipped unless `SCAN_HARDWARE_TESTS=1` is set in the environment or in `~/.scan-hardware-tests`, writes the received pages and the command trace to `SCAN_HW_OUTPUT_DIR`, and treats an empty feeder as a successful pre-scan run. ScanSnap Home's `SshResident` process must be quit first because it holds the USB interface exclusively.

Page frames are yielded per sheet rather than collected for the whole feeder batch, one sheet behind the transfer: after sheet N has been read, its decode and JPEG encode run on a utility-QoS GCD thread while the engine already feeds and transfers sheet N+1, and the frames of sheet N are delivered before sheet N+2 starts. On an error the already encoded sheet is still delivered before the error propagates. The encode deliberately runs on GCD rather than `Task.detached`: on hardware, a detached task made the next `OBJECT POSITION` status arrive only after the encode finished (feed latency tracked encode time to within 30 ms across 14 sheets), whereas the GCD variant keeps the feed at ~25 ms.

The image `READ` size comes from the profile (`transferChunkSize`): 32 KiB for the S1500, whose endpoint ends data phases there, and 256 KiB for the iX500, which cut a duplex A4 300 dpi transfer from 7.3 s to 3.1 s per sheet (about 210 instead of 1,800 commands). Note that Debug builds decode a page in ~3 s because the per-byte normalisation loop is unoptimised; Release builds do it in ~10 ms.

`AcquisitionSettings.scannerBuffering` maps to Fujitsu mode page 0x3a (SANE "buffer mode": 3 on, 2 off, always with clear = 3). It is gated by `ScannerCapabilities.supportsScannerBuffering`, which only the iX500 profile sets; the S1500 keeps sending "off" as before. With buffering on, the iX500 reads the next sheet into its own memory while the host still transfers the current one, so the per-sheet transfer of a duplex A4 colour 300 dpi sheet drops from 3.5 s to 2.1 s (the scanner is then ahead of the mechanics). The engine always resets the buffer to off-and-clear at the end of a batch and after an error, so read-ahead sheets never linger in the scanner.

`AcquisitionSettings.hardwareCompression` (capability `supportsHardwareCompression`, iX500 only) asks the scanner for JPEG output: window byte 0x20 = 0x81 and byte 0x21 = the Fujitsu Q argument 1–7 derived from `ExportSettings.jpegQuality` with deliberately flat top steps (0.82 → 4, 0.92 → 5, only 1.0 → 7), because on the iX500 Q5 gives ~2 MB per A4 colour page and Q6 ~6 MB without visible gain. Width and height are rounded to whole 8×8 blocks (2544 px wide at 300 dpi). `FujitsuJPEGStreamSplitter` ports SANE's `read_from_JPEGduplex()`: it inserts the missing JFIF APP0 (with the scan DPI), and for models that interlace both duplex sides into one double-width stream it splits the restart intervals per side and renumbers the RST markers. The iX500 does not interlace: SOF carries the plain width and each side is its own stream from its own window, so the engine reads both windows alternately. The SOF height already reflects automatic length detection. Colour pages are passed through untouched (`PageFrame.pixelFormat == .jpeg`); grayscale and line-art output are decoded once and re-encoded as gray JPEG. Measured on the iX500 for duplex A4 colour 300 dpi with buffering: ~2 MB per side instead of 27 MB raw, 3.2 s per sheet regardless of whether the sides are read sequentially or interleaved, so the scanner's own JPEG pipeline is the limit there. The engine treats an end-of-medium sense, the EOI marker, an empty read, or the raw-size byte cap as the end of a JPEG stream.

The downloadable gamma table (`FujitsuGammaTable`, SEND type 0x83) is built like SANE's `send_lut()` with default brightness/contrast: a straight line from `1 << lookupTableInputBits` inputs onto 8-bit output. The S1500 profile keeps its 1024-entry table (pinned byte for byte by a test); the iX500 profile uses the 256-entry table SANE sends for it (`adbits = 8`). Neither table brightens the page: the iX500 delivers paper at roughly 245 of 255 in both the raw and the JPEG path, so any background whitening belongs in the image pipeline, not the driver.

`ImageProcessingSettings.paperCleanup` provides that background whitening as a per-profile, backend-independent adjustment. It lowers the effective white point by up to 12 percent so faint crease shadows and paper texture clip toward white while black remains anchored. Zero is neutral and is also the migration value for profiles saved before the setting existed.

"Image data ready" polling (read-image-count and the duplex idle loops) runs at 100 ms with a 60 s budget; with scanner buffering the next sheet is usually ready after a single poll.

The command engine never makes output-format compression decisions beyond that pass-through. Cancellation sets a terminal cancellation flag before aborting transfers, so a late transport error cannot replace cancellation with a generic failure. Partial pages remain in the review workspace.

## Experimental ScanSnap S300 direct-USB backend

`FujitsuScanSnapS300Driver` separately matches the S300 (`0x1156`) and S300M
(`0x117f`). These scanners do not use the SCSI-over-USB command wrapper. The
backend implements direct bulk status, firmware upload/checksum,
reinitialization, and identity exchanges. The required Fujitsu firmware is
not redistributable, so the user chooses it and the app retains a
security-scoped bookmark. Model-specific calibration and image acquisition
remain disabled until they have an independently implemented command model
and can be exercised against physical hardware.

## Image Capture backend and discovery

`CompositeScannerDiscovery` combines the native USB enumerator with a long-lived
`ICDeviceBrowser`. The browser watches local, shared, Bonjour, and Bluetooth
scanner locations, retains the Image Capture device objects needed to open a
session, and retains its non-owning delegate for the app lifetime. If both
layers report the same USB vendor/product, serial, or location, the native
identity wins.

Image Capture opens and closes through its async session APIs. It waits for
each `requestSelect` delegate callback before reading or configuring the
selected unit. Flatbed and feeder resolutions are retained per source so a
flatbed-only DPI is never presented as an ADF option. The backend uses a unique
file-transfer directory and document name for every job, imports each delivered
file before removing the transfer copy, maps its actual content type, and
normalizes Image Capture's 0–100 progress value to the workspace's 0–1 range.
The framework does not expose an ADF-back-only functional unit, so only front
and duplex are advertised; duplex page side is marked unknown rather than
invented.

Devices discovered without a matching driver remain visible as “Discovered, unsupported”; they are never silently treated as ScanSnap devices.

## Adding another native driver

1. For another Fujitsu SCSI-over-USB model, add a `FujitsuScanSnapModelProfile` with its quirk flags and a thin `ScannerDriver` that hands the profile to `FujitsuScanSnapDevice`. Start from SANE's `init_model()` notes and the scanner's VPD page (`testDumpVitalProductData` in the hardware harness), then try the flags on hardware with the `SCAN_HW_*` profile experiments before committing them to the profile. For a different protocol, add a scanner-specific `ScannerDriver` and `ScannerDevice` implementation.
2. Add only verified USB IDs to that driver’s `supportedUSBDeviceIDs`.
3. Add the driver to `ScannerDriverRegistry.live` after its transport/protocol tests pass.
4. Add a hardware validation matrix covering enumeration, open/close, every advertised source/color/DPI combination, simplex/duplex ordering, page dimensions, cancellation, empty feeder, jam/double-feed, disconnect, and partial-batch recovery.
5. Keep simulated fixtures and automated tests independent of physical hardware: add transcript scenarios for the new profile to `FujitsuCommandTranscriptTests` (record them with the scripted transport once the sequence has been validated on the device). The fi-5110EOX, S500, unvalidated S510 product variants, fi-5000 and fi-6000 profiles are protocol-backed only; physical validation of each model is still required before release claims are made. The S1300/S1300i and S1100/S1100i models are not included because their epjitsu protocol is different.
