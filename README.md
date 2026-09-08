Basic app to use legacy Fujitsu ScanSnap scanners on modern macOS.

## Native USB support

The native Fujitsu SCSI-over-USB backend supports the following USB models:

| Scanner | USB product ID |
| --- | --- |
| ScanSnap S500 / S500M | `0x10fe` / `0x1135` |
| ScanSnap S510 / S510M | `0x1155` / `0x116f` |
| ScanSnap S1500 / S1500M | `0x11a2` |
| ScanSnap iX500 | `0x132b` |

These are legacy models that are not listed in Ricoh’s current macOS 26
software matrix. The iX500 uses model-specific pre-read and JPEG-table setup;
gray and line-art output are converted in the app after its color acquisition.
Other Image Capture-compatible scanners continue to work through macOS’s
Image Capture backend.

The S1300/S1300i and S1100/S1100i families are intentionally not claimed by
the native backend yet: they use a different Fujitsu protocol and need a
separate driver rather than another USB-ID alias.
