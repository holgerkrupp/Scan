Basic app to use legacy Fujitsu ScanSnap scanners on modern macOS.

## Shortcuts and automation

Scan publishes three App Intents to Shortcuts and Siri: **Scan Document**,
**Refresh Scanners**, and **Open Scan**. The scan action lets a shortcut choose
from the profiles saved in Scan, always exports the captured pages, and returns
the resulting files to the next shortcut action. Its destination is the folder
selected in Scan, so select that folder once in the app before automating scans.

The same actions are also available from the app's **Scan** menu: Scan Document
(Command-Return), Export Pages (Command-Shift-E), and Refresh Scanners
(Command-Shift-R).

## Native USB support

The native Fujitsu USB backends recognize the following models:

| Scanner | USB product ID | Status |
| --- | --- | --- |
| ScanSnap S300 / S300M (experimental) | `0x1156` / `0x117f` | Firmware bootstrap only, no image acquisition yet |
| ScanSnap S500 / S500M | `0x10fe` / `0x1135` | Protocol profile (S1500 command flow), not yet validated on hardware |
| ScanSnap S510 / S510M | `0x1155` / `0x116f` | Protocol profile (S1500 command flow), not yet validated on hardware |
| ScanSnap S1500 / S1500M | `0x11a2` | Validated on hardware |
| ScanSnap iX500 | `0x132b` | Validated on hardware: simplex/duplex, color/gray/line-art, 150–600 dpi, multi-sheet batches with automatic length detection, scanner buffering, hardware JPEG, empty feeder |

These are legacy models that are not listed in Ricoh’s current macOS 26
software matrix. The iX500 uses model-specific pre-read and JPEG-table setup,
always scans in color (gray and line-art are derived in the app), and offers
two optional acquisition settings: scanner buffering (the iX500 reads the next
sheet into its own memory while the previous one is transferred) and hardware
JPEG compression (about 2 MB instead of 27 MB per A4 color page over USB).
Other Image Capture-compatible scanners continue to work through macOS’s
Image Capture backend.

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
