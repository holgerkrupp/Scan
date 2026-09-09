import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap iX500 (USB 0x04c5/0x132b).
///
/// The iX500 speaks the same Fujitsu SCSI dialect as the S1500 but needs a few
/// extra steps before a batch (diagnostic pre-read mode, JPEG quantisation
/// table, hopper check) and only delivers colour samples; grayscale and
/// line-art output are produced in software. See
/// `FujitsuScanSnapModelProfile.ix500` for the full list of quirks.
struct FujitsuScanSnapIX500Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.ix500

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
