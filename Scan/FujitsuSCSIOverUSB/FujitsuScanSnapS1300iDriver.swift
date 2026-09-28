import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap S1300i
/// (USB 0x04c5/0x128d).
///
/// SANE's `fujitsu` backend drives the S1300i with the same iX500-era quirks:
/// diagnostic pre-read mode, JPEG quantisation table, hopper check, and
/// software-emulated grayscale/lineart. See
/// `FujitsuScanSnapModelProfile.s1300i` for the full profile. Not yet
/// validated on hardware.
struct FujitsuScanSnapS1300iDriver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.s1300i

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
