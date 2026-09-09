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

## Native ScanSnap backend (S1500/S1500M and iX500)

`FujitsuScanSnapDevice` and its private SCSI-over-USB command engine are shared by the ScanSnap models. Each model contributes a `FujitsuScanSnapModelProfile` (USB IDs, capabilities, and explicit quirk flags) and a thin `ScannerDriver`:

| Driver | USB ID | Profile |
| --- | --- | --- |
| `FujitsuScanSnapS1500Driver` | `0x04c5/0x11a2` | `.s1500` (validated reference path) |
| `FujitsuScanSnapIX500Driver` | `0x04c5/0x132b` | `.ix500` |

No other Fujitsu product ID is claimed. The command flow remains the hardware path: inquiry, ADF setup, automatic document length, window setup, interleaved duplex reads, sense/status handling, and paper recovery.

The iX500 profile follows the quirks documented in SANE's `fujitsu.c` `init_model()`:

- `SEND DIAGNOSTIC "SET PRE READMODE"` is sent before the mode selects (needed for resolutions above 300 dpi).
- A JPEG quantisation table is sent after `SET WINDOW` even though transfers are uncompressed.
- `GET HW STATUS` is read before the first `OBJECT POSITION`; an empty hopper ends the batch with `feederEmpty` instead of letting the scanner error.
- `OBJECT POSITION` is not followed by `TEST UNIT READY` polling.
- Pixels per line are rounded down to a multiple of 2 and the window width is derived from that.
- The scanner is always asked for colour; grayscale is the channel average and line-art a fixed 127 threshold, computed in `FujitsuScanSnapImageDecoder`.
- Colour interlacing (RGB dot, BGR dot, RRGGBB line) is probed with `SET WINDOW` on the first scan of a session and de-interlaced accordingly.
- Dropout and buffer mode selects are best effort.

All S1500 flags are set so that its command bytes are unchanged by the refactor; `FujitsuScanSnapDriverTests` pins the S1500 window geometry and the decoder paths.

iX500 hardware validation (firmware 0U00, macOS 27, libusb transport) covered: enumeration and open/close, inquiry, ADF front colour 300 dpi, ADF duplex gray 600 dpi (interleaved reads, 128 MB per side), ADF front line-art 150 dpi (scanner reports the even-rounded 1274-pixel width), a 14-sheet A4 duplex colour 300 dpi batch with auto-crop (automatic length detection returned 3527–3536 rows per side instead of the 4200-row window, every sheet ended with the benign EOM/ILI sense), the same batch with 256 KiB reads and pipelined encoding (3.1–3.6 s transfer per sheet, ~25 ms feed latency), a 4-sheet batch with scanner buffering on (2.1 s transfer per sheet from the second sheet on), two 14-sheet batches with hardware JPEG (sequential and interleaved side reads, 3.2 s per sheet, 28 valid JPEGs each), and the empty-feeder path through `GET HW STATUS`. The scanner accepted RGB dot interlacing on the first probe and rejected none of the preparatory commands. Not yet exercised on the iX500: jam/double-feed recovery, mid-transfer cancellation, disconnect, the back-only source, and 200/400 dpi.

`FujitsuScanSnapHardwareTests` is the opt-in harness for these runs. It is skipped unless `SCAN_HARDWARE_TESTS=1` is set in the environment or in `~/.scan-hardware-tests`, writes the received pages and the command trace to `SCAN_HW_OUTPUT_DIR`, and treats an empty feeder as a successful pre-scan run. ScanSnap Home's `SshResident` process must be quit first because it holds the USB interface exclusively.

Page frames are yielded per sheet rather than collected for the whole feeder batch, one sheet behind the transfer: after sheet N has been read, its decode and JPEG encode run on a utility-QoS GCD thread while the engine already feeds and transfers sheet N+1, and the frames of sheet N are delivered before sheet N+2 starts. On an error the already encoded sheet is still delivered before the error propagates. The encode deliberately runs on GCD rather than `Task.detached`: on hardware, a detached task made the next `OBJECT POSITION` status arrive only after the encode finished (feed latency tracked encode time to within 30 ms across 14 sheets), whereas the GCD variant keeps the feed at ~25 ms.

The image `READ` size comes from the profile (`transferChunkSize`): 32 KiB for the S1500, whose endpoint ends data phases there, and 256 KiB for the iX500, which cut a duplex A4 300 dpi transfer from 7.3 s to 3.1 s per sheet (about 210 instead of 1,800 commands). Note that Debug builds decode a page in ~3 s because the per-byte normalisation loop is unoptimised; Release builds do it in ~10 ms.

`AcquisitionSettings.scannerBuffering` maps to Fujitsu mode page 0x3a (SANE "buffer mode": 3 on, 2 off, always with clear = 3). It is gated by `ScannerCapabilities.supportsScannerBuffering`, which only the iX500 profile sets; the S1500 keeps sending "off" as before. With buffering on, the iX500 reads the next sheet into its own memory while the host still transfers the current one, so the per-sheet transfer of a duplex A4 colour 300 dpi sheet drops from 3.5 s to 2.1 s (the scanner is then ahead of the mechanics). The engine always resets the buffer to off-and-clear at the end of a batch and after an error, so read-ahead sheets never linger in the scanner.

`AcquisitionSettings.hardwareCompression` (capability `supportsHardwareCompression`, iX500 only) asks the scanner for JPEG output: window byte 0x20 = 0x81 and byte 0x21 = the Fujitsu Q argument 1–7 derived from `ExportSettings.jpegQuality` (0.82 → 5). Width and height are rounded to whole 8×8 blocks (2544 px wide at 300 dpi). `FujitsuJPEGStreamSplitter` ports SANE's `read_from_JPEGduplex()`: it inserts the missing JFIF APP0 (with the scan DPI), and for models that interlace both duplex sides into one double-width stream it splits the restart intervals per side and renumbers the RST markers. The iX500 does not interlace: SOF carries the plain width and each side is its own stream from its own window, so the engine reads both windows alternately. The SOF height already reflects automatic length detection. Colour pages are passed through untouched (`PageFrame.pixelFormat == .jpeg`); grayscale and line-art output are decoded once and re-encoded as gray JPEG. Measured on the iX500 for duplex A4 colour 300 dpi with buffering: ~2 MB per side instead of 27 MB raw, 3.2 s per sheet regardless of whether the sides are read sequentially or interleaved, so the scanner's own JPEG pipeline is the limit there. The engine treats an end-of-medium sense, the EOI marker, an empty read, or the raw-size byte cap as the end of a JPEG stream.

The command engine never makes output-format compression decisions beyond that pass-through. Cancellation sets a terminal cancellation flag before aborting transfers, so a late transport error cannot replace cancellation with a generic failure. Partial pages remain in the review workspace.

## Image Capture backend and discovery

`CompositeScannerDiscovery` combines the native USB enumerator with `ICDeviceBrowser`. If both layers report the same USB vendor/product, serial, or location, the native identity wins. Image Capture maps flatbed/document-feeder units, duplex availability, supported resolutions, scan area, progress, cancellation, and file-based received pages into `ScannerDevice`.

Devices discovered without a matching driver remain visible as “Discovered, unsupported”; they are never silently treated as ScanSnap devices.

## Adding another native driver

1. For another Fujitsu SCSI-over-USB model, add a `FujitsuScanSnapModelProfile` with its quirk flags and a thin `ScannerDriver` that hands the profile to `FujitsuScanSnapDevice`. For a different protocol, add a scanner-specific `ScannerDriver` and `ScannerDevice` implementation.
2. Add only verified USB IDs to that driver’s `supportedUSBDeviceIDs`.
3. Add the driver to `ScannerDriverRegistry.live` after its transport/protocol tests pass.
4. Add a hardware validation matrix covering enumeration, open/close, every advertised source/color/DPI combination, simplex/duplex ordering, page dimensions, cancellation, empty feeder, jam/double-feed, disconnect, and partial-batch recovery.
5. Keep simulated fixtures and automated tests independent of physical hardware. Do not claim support for an additional Fujitsu model until that matrix has been run on the device.
