import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap iX1600
/// (USB 0x04c5/0x1632).
///
/// The iX1600 is the iX1500's successor with the same paper path and the
/// same Fujitsu SCSI dialect. See `FujitsuScanSnapModelProfile.ix1600` for
/// the behaviour that was validated on hardware.
struct FujitsuScanSnapIX1600Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.ix1600

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
