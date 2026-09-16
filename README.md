Native macOS scanning app with direct USB support for Fujitsu ScanSnap and
fi-series document scanners, including legacy models and the ScanSnap iX1500.

## Building

Signing uses the team set in `Config/Shared.xcconfig`. To build with your own
Apple Developer team, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` (ignored by git) and set `DEVELOPMENT_TEAM` there.
Leave the team in Xcode's Signing & Capabilities pane untouched: choosing one
there writes it into the project file, which overrides the configuration files.

## Shortcuts and automation

Scan publishes three App Intents to Shortcuts and Siri: **Scan Document**,
**Refresh Scanners**, and **Open Scan**. The scan action lets a shortcut choose
from the profiles saved in Scan, always exports the captured pages, and returns
the resulting files to the next shortcut action. Its destination is the folder
selected in Scan, so select that folder once in the app before automating scans.

The same actions are also available from the app's **Scan** menu: Scan Document
(Command-Return), Export Pages (Command-Shift-E), and Refresh Scanners
(Command-Shift-R).

## Automatic alignment

ScanSnap Home straightens sheets and crops away their edges in software; the
scanners themselves only trim the page length (the iX-series reports no
hardware deskew or crop in its capability page). Scan does the same with the
**Deskew and crop to page** option in the Processing section of a profile,
applied to every page on export, and with **Edit > Auto-Align Page**
(Command-Shift-L, also in a page's context menu) for a selected page. The
separate **Crop to content** option trims the paper margins down to the
printed content afterwards, for receipts and clippings. The page outline is found
with Vision's document segmentation, the sheet is rotated by the tilt of its
edges onto a white canvas, and the result is cropped to the largest rectangle
inside the straightened sheet, minus a small margin that removes the edge
shadow. When no outline can be found, the tilt is estimated from the content
(the angle at which the rows of dark pixels line up best) and the background
wedges left by the rotation are cropped away.

## Reviewing and processing pages

Scanning produces an intermediate result that you refine before exporting.
The app keeps every raw scan for the review session and shows processed
renditions in the page grid: the profile's processing options (deskew and
crop, crop to content, whiten paper, paper cleanup, automatic orientation,
blank-page removal) are applied to each page as it arrives, in the
background, and re-applied to all pages whenever an option changes. Blank
pages are hidden rather than deleted and reappear when blank-page removal is
switched off; the header shows how many are hidden. Rotate and Auto-Align
from the Edit menu are per-page adjustments layered on top of the profile.
Export writes exactly the pages you see, applying only the output
resolution and compression. The session ends with Clear or the next scan.

## Paper tone and blank pages

The iX-series delivers plain paper as light gray (about 230–245 of 255 on
the iX1600 depending on the paper, with the scanner's built-in gamma curve
about ten levels lighter than a downloaded linear table). **Whiten paper**
in the Processing section measures each page's paper level and stretches it
to white while black stays black; pages whose overall tone is not paper, such
as photos, are left alone. Blank-page removal judges ink relative to the same
paper level (with the sheet's edge excluded), so a blank page is recognised
whatever gray the scanner makes of it, and a dark page is never treated as
blank.

## Native USB support

The native Fujitsu USB backends recognize the following models:

| Scanner | USB product ID | Status |
| --- | --- | --- |
| ScanSnap S300 / S300M (experimental) | `0x1156` / `0x117f` | Firmware bootstrap only, no image acquisition yet |
| ScanSnap S500 / S500M | `0x10fe` / `0x1135` | Protocol profile (S1500 command flow), not yet validated on hardware |
| ScanSnap S510 / S510M | `0x1155` / `0x116f` | Validated on S510M hardware: duplex color at 300 dpi; optional buffer-page rejection and BGR interlace handled |
| ScanSnap S1500 / S1500M | `0x11a2` | Validated on hardware |
| ScanSnap iX500 | `0x132b` | Validated on hardware: simplex/duplex, color/gray/line-art, 150–600 dpi, multi-sheet batches with automatic length detection, scanner buffering, hardware JPEG, empty feeder |
| ScanSnap iX1500 | `0x159f` | Protocol profile (generic Fujitsu command flow), not yet validated on hardware; gray/line-art are derived from color |
| ScanSnap fi-5110EOX / EOX2 / EOX3 / EOXM | `0x1096` / `0x10e6` / `0x10f2` | Protocol profile (S1500 command flow), not yet validated on hardware |
| fi-5110C, fi-5120C / fi-5220C | `0x1097`, `0x10e0` / `0x10e1` | Protocol profile (S1500 command flow), not yet validated on hardware; fi-5220C via ADF only |
| fi-5530C / fi-5530C2 | `0x10e2` / `0x114a` | Protocol profile (S1500 command flow), not yet validated on hardware |
| fi-6110, fi-6130 / fi-6130Z, fi-6140 / fi-6140Z | `0x11fc`, `0x114f` / `0x11f3`, `0x114d` / `0x11f1` | Protocol profile (S1500 command flow), not yet validated on hardware |
| fi-6230 / fi-6230Z, fi-6240 / fi-6240Z | `0x1150` / `0x11f4`, `0x114e` / `0x11f2` | Protocol profile (S1500 command flow), not yet validated on hardware; ADF only, the flatbed is not supported |

Most profiles target legacy models that Ricoh no longer supports on current
macOS: ScanSnap Home dropped the iX500 with macOS 15, and its fi Series macOS
driver covers only fi-7000 and fi-8000 models. The iX1500 is the exception: it
is also claimed here to provide the app's direct native USB path. The
fi-5000/fi-6000 and fi-5110EOX profiles reuse the S1500 command flow with the
model notes from SANE's `fujitsu` backend:
colour interlacing is probed, the optional mode selects and the gamma table are
best effort, and native line-art widths are rounded to whole bytes. The iX100
and the fi-7000/fi-8000 models are still supported by Ricoh and are not claimed.

The iX500 uses model-specific pre-read and JPEG-table setup,
always scans in color (gray and line-art are derived in the app), and offers
two optional acquisition settings: scanner buffering (the iX500 reads the next
sheet into its own memory while the previous one is transferred) and hardware
JPEG compression (about 2 MB instead of 27 MB per A4 color page over USB).
Other Image Capture-compatible scanners continue to work through macOS’s
Image Capture backend.

### ScanSnap iX1500

The iX1500 is recognized over USB as `0x04c5/0x159f` and uses the generic
Fujitsu SCSI-over-USB command flow documented by SANE. The native profile
supports ADF front, back, and duplex acquisition at 150, 200, 300, and 600 dpi.
The scanner is asked for color data; gray and line-art output are converted in
the app.

This profile has command-level test coverage but has not yet been validated on
physical iX1500 hardware. Scanner buffering, hardware JPEG compression, Wi-Fi
scanning, and touchscreen-triggered scans are therefore not enabled. If you
test it on hardware, the opt-in harness in
`ScanTests/FujitsuScanSnapHardwareTests.swift` can capture pages and a command
trace for validation.

Note: ScanSnap Home keeps the scanner's USB interface open exclusively while
its background process (`SshResident`) runs. Quit ScanSnap Home before using
this app with the same scanner.

Hardware validation runs are opt-in: see `ScanTests/FujitsuScanSnapHardwareTests.swift`.

The S300/S300M use a separate direct bulk-USB protocol. This app recognizes
both devices and implements their firmware-status, upload, reinitialization,
and identity exchanges. Fujitsu's `300_0C00.nal` / `300M_0C00.nal` firmware is
copyrighted and cannot be included; select a firmware file under Diagnostics.
Calibrated image acquisition is not enabled yet, so this backend is explicitly
experimental rather than production scan support. The protocol work is based
on the public [SANE epjitsu backend](https://gitlab.com/sane-project/backends/-/tree/master/backend)
and its [device documentation](https://www.sane-project.org/man/sane-epjitsu.5.html),
without incorporating the GPL implementation into this MIT-licensed project.

The S1300/S1300i and S1100/S1100i families are intentionally not claimed by
the native backend yet: they use a different Fujitsu protocol and need a
separate driver rather than another USB-ID alias.
