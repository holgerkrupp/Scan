import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap iX1500
/// (USB 0x04c5/0x159f).
///
/// The iX1500 shares its generation, paper path and Fujitsu SCSI dialect
/// with the iX1600, so it uses the same profile
/// (`FujitsuScanSnapModelProfile.ix1500` mirrors `.ix1600`). The iX1600
/// command flow was exercised on hardware; the iX1500 has not been tested
/// yet, so treat it as preliminary support.
struct FujitsuScanSnapIX1500Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.ix1500

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
