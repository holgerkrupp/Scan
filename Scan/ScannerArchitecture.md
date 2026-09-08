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

## Native legacy ScanSnap SCSI-over-USB backend

`FujitsuScanSnapS1500Driver` handles the Fujitsu SCSI-over-USB family used by
the S500/S500M (`0x10fe`/`0x1135`), S510/S510M (`0x1155`/`0x116f`),
S1500/S1500M (`0x11a2`), and iX500 (`0x132b`). The shared command flow remains
the hardware path: inquiry, ADF setup, automatic document length, window
setup, interleaved duplex reads, sense/status handling, and paper recovery.
The iX500 profile adds its diagnostic pre-read and JPEG quantization-table
setup, and converts gray/line-art requests in software because its hardware
path is color-based.

Page frames are yielded as each sheet is completed rather than collected for the whole feeder batch. The command engine never makes output-format compression decisions. Cancellation sets a terminal cancellation flag before aborting transfers, so a late transport error cannot replace cancellation with a generic failure. Partial pages remain in the review workspace.

## Image Capture backend and discovery

`CompositeScannerDiscovery` combines the native USB enumerator with `ICDeviceBrowser`. If both layers report the same USB vendor/product, serial, or location, the native identity wins. Image Capture maps flatbed/document-feeder units, duplex availability, supported resolutions, scan area, progress, cancellation, and file-based received pages into `ScannerDevice`.

Devices discovered without a matching driver remain visible as “Discovered, unsupported”; they are never silently treated as S1500 devices.

## Adding another native driver

1. Add a scanner-specific `ScannerDriver` and `ScannerDevice` implementation behind `ScannerDevice`.
2. Add only verified USB IDs to that driver’s `supportedUSBDeviceIDs`.
3. Add the driver to `ScannerDriverRegistry.live` after its transport/protocol tests pass.
4. Add a hardware validation matrix covering enumeration, open/close, every advertised source/color/DPI combination, simplex/duplex ordering, page dimensions, cancellation, empty feeder, jam/double-feed, disconnect, and partial-batch recovery.
5. Keep simulated fixtures and automated tests independent of physical hardware. The legacy IDs above are protocol-backed profiles; physical validation of each model is still required before release claims are made. The S1300/S1300i and S1100/S1100i models are not included because their epjitsu protocol is different.
