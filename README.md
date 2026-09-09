Basic App to use the Fujitsu ScanSnap S1500M and iX500 under modern Mac OS.

Supported natively over USB:

| Model | USB ID | Status |
| --- | --- | --- |
| ScanSnap S1500 / S1500M | `0x04c5/0x11a2` | Validated on hardware |
| ScanSnap iX500 | `0x04c5/0x132b` | Validated on hardware (simplex/duplex, color/gray/lineart, 150–600 dpi, 14-sheet batch with auto length detection, scanner buffering, empty feeder) |

Other scanners remain available through the macOS Image Capture backend.

Note: ScanSnap Home keeps the scanner's USB interface open exclusively while its background process (`SshResident`) runs. Quit ScanSnap Home before using this app with the same scanner.

Hardware validation runs are opt-in: see `ScanTests/FujitsuScanSnapHardwareTests.swift`.
