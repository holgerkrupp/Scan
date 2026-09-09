# Scanner workspace architecture

The app separates scanner acquisition from image processing and export:

`ScannerDiscovery` -> `ScannerDriver`/`ScannerDevice` -> `PageFrame` stream -> file-backed `ScanPageStore` -> `ScanImageProcessor` -> `ScanOutputWriter`.

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

## Native legacy ScanSnap SCSI-over-USB backend (S500, S510, S1500, iX500)

`FujitsuScanSnapDevice` and its private SCSI-over-USB command engine are shared by the Fujitsu SCSI-over-USB family. Each model contributes a `FujitsuScanSnapModelProfile` (USB IDs, capabilities, and explicit quirk flags); `FujitsuScanSnapS1500Driver` serves the S500/S500M, S510/S510M and S1500/S1500M profiles by USB product ID, and `FujitsuScanSnapIX500Driver` the iX500. The shared command flow remains the hardware path: inquiry, ADF setup, automatic document length, window setup, interleaved duplex reads, sense/status handling, and paper recovery.

| Driver | USB IDs | Profile |
| --- | --- | --- |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x10fe`, `0x04c5/0x1135` | `.s500` (protocol-backed, S1500 flow without 400 dpi; not validated on hardware) |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x1155`, `0x04c5/0x116f` | `.s510` (protocol-backed, S1500 flow without 400 dpi; not validated on hardware) |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x11a2` | `.s1500` (validated reference path) |
| `FujitsuScanSnapIX500Driver` | `0x04c5/0x132b` | `.ix500` (validated on hardware) |

No other Fujitsu product ID is claimed by these drivers.

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

`FujitsuScanSnapHardwareTests` is the opt-in harness for these runs. It is skipped unless `SCAN_HARDWARE_TESTS=1` is set in the environment or in `~/.scan-hardware-tests`, writes the received pages and the command trace to `SCAN_HW_OUTPUT_DIR`, and treats an empty feeder as a successful pre-scan run. ScanSnap Home's `SshResident` process must be quit first because it holds the USB interface exclusively.

Page frames are yielded per sheet rather than collected for the whole feeder batch, one sheet behind the transfer: after sheet N has been read, its decode and JPEG encode run on a utility-QoS GCD thread while the engine already feeds and transfers sheet N+1, and the frames of sheet N are delivered before sheet N+2 starts. On an error the already encoded sheet is still delivered before the error propagates. The encode deliberately runs on GCD rather than `Task.detached`: on hardware, a detached task made the next `OBJECT POSITION` status arrive only after the encode finished (feed latency tracked encode time to within 30 ms across 14 sheets), whereas the GCD variant keeps the feed at ~25 ms.

The image `READ` size comes from the profile (`transferChunkSize`): 32 KiB for the S1500, whose endpoint ends data phases there, and 256 KiB for the iX500, which cut a duplex A4 300 dpi transfer from 7.3 s to 3.1 s per sheet (about 210 instead of 1,800 commands). Note that Debug builds decode a page in ~3 s because the per-byte normalisation loop is unoptimised; Release builds do it in ~10 ms.

`AcquisitionSettings.scannerBuffering` maps to Fujitsu mode page 0x3a (SANE "buffer mode": 3 on, 2 off, always with clear = 3). It is gated by `ScannerCapabilities.supportsScannerBuffering`, which only the iX500 profile sets; the S1500 keeps sending "off" as before. With buffering on, the iX500 reads the next sheet into its own memory while the host still transfers the current one, so the per-sheet transfer of a duplex A4 colour 300 dpi sheet drops from 3.5 s to 2.1 s (the scanner is then ahead of the mechanics). The engine always resets the buffer to off-and-clear at the end of a batch and after an error, so read-ahead sheets never linger in the scanner.

`AcquisitionSettings.hardwareCompression` (capability `supportsHardwareCompression`, iX500 only) asks the scanner for JPEG output: window byte 0x20 = 0x81 and byte 0x21 = the Fujitsu Q argument 1–7 derived from `ExportSettings.jpegQuality` with deliberately flat top steps (0.82 → 4, 0.92 → 5, only 1.0 → 7), because on the iX500 Q5 gives ~2 MB per A4 colour page and Q6 ~6 MB without visible gain. Width and height are rounded to whole 8×8 blocks (2544 px wide at 300 dpi). `FujitsuJPEGStreamSplitter` ports SANE's `read_from_JPEGduplex()`: it inserts the missing JFIF APP0 (with the scan DPI), and for models that interlace both duplex sides into one double-width stream it splits the restart intervals per side and renumbers the RST markers. The iX500 does not interlace: SOF carries the plain width and each side is its own stream from its own window, so the engine reads both windows alternately. The SOF height already reflects automatic length detection. Colour pages are passed through untouched (`PageFrame.pixelFormat == .jpeg`); grayscale and line-art output are decoded once and re-encoded as gray JPEG. Measured on the iX500 for duplex A4 colour 300 dpi with buffering: ~2 MB per side instead of 27 MB raw, 3.2 s per sheet regardless of whether the sides are read sequentially or interleaved, so the scanner's own JPEG pipeline is the limit there. The engine treats an end-of-medium sense, the EOI marker, an empty read, or the raw-size byte cap as the end of a JPEG stream.

The downloadable gamma table (`FujitsuGammaTable`, SEND type 0x83) is built like SANE's `send_lut()` with default brightness/contrast: a straight line from `1 << lookupTableInputBits` inputs onto 8-bit output. The S1500 profile keeps its 1024-entry table (pinned byte for byte by a test); the iX500 profile uses the 256-entry table SANE sends for it (`adbits = 8`). Neither table brightens the page: the iX500 delivers paper at roughly 245 of 255 in both the raw and the JPEG path, so any background whitening belongs in the image pipeline, not the driver.

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

1. For another Fujitsu SCSI-over-USB model, add a `FujitsuScanSnapModelProfile` with its quirk flags and a thin `ScannerDriver` that hands the profile to `FujitsuScanSnapDevice`. For a different protocol, add a scanner-specific `ScannerDriver` and `ScannerDevice` implementation.
2. Add only verified USB IDs to that driver’s `supportedUSBDeviceIDs`.
3. Add the driver to `ScannerDriverRegistry.live` after its transport/protocol tests pass.
4. Add a hardware validation matrix covering enumeration, open/close, every advertised source/color/DPI combination, simplex/duplex ordering, page dimensions, cancellation, empty feeder, jam/double-feed, disconnect, and partial-batch recovery.
5. Keep simulated fixtures and automated tests independent of physical hardware: add transcript scenarios for the new profile to `FujitsuCommandTranscriptTests` (record them with the scripted transport once the sequence has been validated on the device). The S500/S510 profiles are protocol-backed only; physical validation of each model is still required before release claims are made. The S1300/S1300i and S1100/S1100i models are not included because their epjitsu protocol is different.
