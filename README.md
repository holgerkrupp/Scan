Basic app to use legacy Fujitsu ScanSnap scanners on modern macOS.

## Native USB support

The native Fujitsu USB backends recognize the following models:

| Scanner | USB product ID |
| --- | --- |
| ScanSnap S300 / S300M (experimental) | `0x1156` / `0x117f` |
| ScanSnap S500 / S500M | `0x10fe` / `0x1135` |
| ScanSnap S510 / S510M | `0x1155` / `0x116f` |
| ScanSnap S1500 / S1500M | `0x11a2` |
| ScanSnap iX500 | `0x132b` |

These are legacy models that are not listed in Ricoh’s current macOS 26
software matrix. The iX500 uses model-specific pre-read and JPEG-table setup;
gray and line-art output are converted in the app after its color acquisition.
Other Image Capture-compatible scanners continue to work through macOS’s
Image Capture backend.

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
